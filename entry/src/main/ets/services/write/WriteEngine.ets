import { BusinessError } from '@kit.BasicServicesKit';
import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { BluetoothService } from '../BluetoothService';
import { SettingsService } from '../SettingsService';
import { ToneStatus } from '../bluetooth/MbbProtocol';
import { CancelledError, isToneError, ToneError, ToneErrorReason } from '../bluetooth/ToneTypes';
import { AudioGateState, AudioLink } from './AudioLink';
import { DeviceTimeline } from './DeviceTimeline';
import { LinkConnector } from './LinkConnector';
import { MbbSession } from './MbbSession';
import { SppChannel } from './SppChannel';
import { SppErrors } from './SppErrors';
import { ToneUploader } from './ToneUploader';
import { WriteGuard } from './WriteGuard';
import { WriteSpec } from './WriteSpec';
import {
  CommandOutcome,
  StageProgress,
  TraceSink,
  UploadReport,
  UploadState,
  UploadTiming,
  WriteOutcome
} from './WriteTypes';

const MODULE: string = 'WriteEngine';
const TRACE_MODULE: string = 'WriteTrace';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 报文级诊断：Logger.debug 只在 debug 包落盘，正式包不留设备地址与通信内容 */
const trace: TraceSink = (line: string): void => {
  Logger.debug(TRACE_MODULE, line);
};

/**
 * 串行队列：同一时刻只有一个设备操作在跑。
 *
 * 旧实现里写入、恢复默认音、失败后的后台回滚、写完后的音频恢复各自用定时器触发，
 * 靠 writing / recovering 两个布尔量互相避让，仍会出现「回滚任务和新写入抢同一条串口」的交错。
 * 所有会碰串口的操作都排进这条队列后，交错从结构上就不存在了。
 */
class SerialQueue {
  private tail: Promise<void> = Promise.resolve();
  private depth: number = 0;

  run<T>(task: () => Promise<T>): Promise<T> {
    this.depth++;
    const result: Promise<T> = this.tail.then((): Promise<T> => task());
    this.tail = result.then((): void => {
      this.depth--;
    }, (): void => {
      this.depth--;
    });
    return result;
  }

  busy(): boolean {
    return this.depth > 0;
  }
}

/**
 * 进度闸门：单调、限频。
 * 擦写进度约 80ms 一包，全推给界面会让主线程忙于重绘，而串口回调也排在主线程上。
 * 阶段文案变化与 97% 之后的收尾进度不限频，保证界面不会停在旧阶段上。
 */
class ProgressGate {
  private readonly sink: StageProgress | undefined;
  private shown: number = 0;
  private lastAt: number = 0;
  private lastStage: string = '';

  constructor(sink: StageProgress | undefined) {
    this.sink = sink;
  }

  emit(ratio: number, stage: string): void {
    const sink: StageProgress | undefined = this.sink;
    if (sink === undefined) {
      return;
    }
    let bounded: number = ratio > 1 ? 1 : (ratio < 0 ? 0 : ratio);
    const stageChanged: boolean = stage !== this.lastStage;
    if (bounded <= this.shown) {
      if (!stageChanged) {
        return;
      }
      bounded = this.shown;
    }
    const now: number = Date.now();
    if (!stageChanged && bounded < 0.97 && now - this.lastAt < WriteSpec.PROGRESS_MIN_INTERVAL_MS) {
      return;
    }
    this.shown = bounded;
    this.lastAt = now;
    this.lastStage = stage;
    sink(bounded, stage);
  }

  /** 整包重来：进度如实回到起点 */
  reset(): void {
    this.shown = 0;
    this.lastStage = '';
    this.lastAt = 0;
  }
}

/** 一次回滚尝试的结果 */
class RollbackResult {
  static readonly DONE: number = 0;
  static readonly RETRY: number = 1;
  static readonly GIVE_UP: number = 2;
}

/** 回滚目标：失败前耳机在用的音效 */
class RollbackPlan {
  deviceId: string;
  neutral: boolean;
  /** 0 = 出厂默认；其他为内置音效 id */
  targetId: number;
  /** 真正发起过建链的次数（盒盖合着时只检查、不计数） */
  connectTries: number = 0;

  constructor(deviceId: string, neutral: boolean, targetId: number) {
    this.deviceId = deviceId;
    this.neutral = neutral;
    this.targetId = targetId;
  }
}

/**
 * 盒音写入引擎。
 *
 * 一次写入的状态机：
 *
 *   等设备就绪（冷却/沉降）→ 建链 → 握手（读状态、型号、协议）→ 松开音频
 *   → 上传（声明 → 选中目标槽位 → 分窗传输 → 擦写）→ 收尾确认
 *
 * 失败处置按「数据走到了哪一步」决定，而不是按错误码猜：
 * - 数据还没收完就断链：整包重来一轮（最多 MAX_UPLOAD_ROUNDS 轮），耳机侧没有任何东西落盘；
 * - 数据收完、只差选中：换一条新链路只补一条选中命令；
 * - 已预选目标槽位但数据没写完：槽位是空的，后台回滚到写入前在用的音效，避免开盖没声音。
 *
 * 系统层面：整个过程持有 WriteGuard（短时任务 + 屏幕常亮），退到后台不会被挂起。
 */
export class WriteEngine {
  private static readonly queue: SerialQueue = new SerialQueue();
  private static pooled: MbbSession | null = null;
  private static poolTimer: number = -1;
  private static active: MbbSession | null = null;
  private static cancelRequested: boolean = false;
  private static writing: boolean = false;
  private static writingToneId: string = '';
  private static rollbackPending: boolean = false;
  /** 回滚正在建链/发命令：用户发起新操作时据此打断它 */
  private static rollbackRunning: boolean = false;
  /** 用户发起的写入/恢复默认/切内置音正在进行或排队 */
  private static userOps: number = 0;
  private static rollbackTimer: number = -1;
  private static audioRestoreTimer: number = -1;

  // ---------------------------------------------------------------- 状态查询

  /** 是否有写入正在进行 */
  static isWriting(): boolean {
    return WriteEngine.writing;
  }

  /** 用户发起的操作是否在进行：只有它会挡住新的写入，后台回滚不会 */
  static isUserBusy(): boolean {
    return WriteEngine.userOps > 0;
  }

  /**
   * 用户发起了新的写入/恢复默认/切内置音：后台回滚就没有意义了（新操作会重新设定槽位），直接放弃。
   * 2026-11-26 20:22 真机：回滚连不上耳机，前后五轮占了一分多钟，期间用户点写入一直被拦在「正在恢复默认开盒音」。
   */
  private static abandonRollback(): void {
    if (!WriteEngine.rollbackPending && !WriteEngine.rollbackRunning) {
      return;
    }
    WriteEngine.cancelRollbackTimer();
    WriteEngine.rollbackPending = false;
    if (WriteEngine.rollbackRunning) {
      WriteEngine.cancelActive();
    }
    Logger.info(MODULE, '用户发起新操作，放弃后台回滚');
  }

  /** 任何设备操作在跑或排队 */
  static isBusy(): boolean {
    return WriteEngine.writing || WriteEngine.rollbackPending || WriteEngine.queue.busy();
  }

  static activeToneId(): string {
    return WriteEngine.writingToneId;
  }

  /** 用户取消当前操作：等待中的回执立刻以取消结束 */
  static cancelActive(): void {
    WriteEngine.cancelRequested = true;
    const session: MbbSession | null = WriteEngine.active;
    if (session !== null) {
      session.cancel();
    }
  }

  /** 失败归类：链路级失败（而非耳机拒绝）值得自动重来 */
  static isLinkFailure(error: Object): boolean {
    if (!isToneError(error)) {
      return false;
    }
    const toneError: ToneError = error as ToneError;
    const reason: string = toneError.reason;
    if (reason === ToneErrorReason.FLUSH_TIMEOUT || reason === ToneErrorReason.DATA_WRITTEN ||
      reason === ToneErrorReason.CANCELLED || reason === ToneErrorReason.AUDIO_HELD ||
      reason === ToneErrorReason.WEDGED) {
      return false;
    }
    if (reason === ToneErrorReason.LINK || reason === ToneErrorReason.ACK_TIMEOUT) {
      return true;
    }
    const code: number = toneError.code;
    return code === SppErrors.IO_ERROR || code === SppErrors.NOT_ACCEPTED ||
      code === SppErrors.SERVICE_NOT_READY || code === SppErrors.BT_OFF;
  }

  // ---------------------------------------------------------------- 写入

  /** 写入一条自定义音效；失败抛 ToneError */
  static async write(deviceId: string, toneId: string, pcm: Uint8Array, neutral: boolean,
    onProgress?: StageProgress): Promise<WriteOutcome> {
    WriteEngine.abandonRollback();
    WriteEngine.writing = true;
    WriteEngine.writingToneId = toneId;
    WriteEngine.userOps++;
    try {
      return await WriteEngine.queue.run<WriteOutcome>((): Promise<WriteOutcome> => {
        return WriteEngine.runWrite(deviceId, pcm, neutral, new ProgressGate(onProgress));
      });
    } finally {
      WriteEngine.userOps--;
      WriteEngine.writing = false;
      WriteEngine.writingToneId = '';
    }
  }

  private static async runWrite(deviceId: string, pcm: Uint8Array, neutral: boolean,
    gate: ProgressGate): Promise<WriteOutcome> {
    WriteEngine.cancelAudioRestore();
    WriteEngine.cancelRequested = false;
    await WriteGuard.acquire();
    const startedAt: number = Date.now();
    let settleWait: number = 0;
    try {
      for (let round = 1; round <= WriteSpec.MAX_UPLOAD_ROUNDS; round++) {
        if (round > 1) {
          gate.reset();
        }
        const session: MbbSession = await WriteEngine.openSession(deviceId, neutral, gate, round,
          MbbSpec.CONNECT_TOTAL_BUDGET_MS, (waitedMs: number): void => {
            settleWait += waitedMs;
          });
        WriteEngine.active = session;
        let before: ToneStatus | null = null;
        let uploadState: UploadState | null = null;
        try {
          gate.emit(0.04, I18n.t('stage.readStatus'));
          before = await session.query();
          gate.emit(0.06, I18n.t('stage.readTone'));
          await session.readDeviceModel();
          const protocol: number = await session.protocolVersion();
          // 传输前音频又被系统连回：数据还没开始发，可以完整走「认领 + 断开 + 等它真正掉下去」
          if (session.audio.isLinked()) {
            trace('AUDIO_PRE_SUPPRESS 传输前音频已连回，先断开');
            await session.audio.release();
          }
          session.beginUpload(protocol, before.volume);
          const uploader: ToneUploader = new ToneUploader(session, WriteEngine.uploadTiming(), trace,
            (ratio: number, stage: string): void => {
              gate.emit(ratio, stage);
            });
          uploadState = uploader.state;
          const report: UploadReport = await uploader.run(pcm, protocol);
          gate.emit(0.97, I18n.t('stage.apply'));
          let status: ToneStatus = new ToneStatus(true, true, before.volume, MbbSpec.TONE_CUSTOM_ID, true);
          if (!report.preselected) {
            // 传输前没能确认选中：在同一条链路上补发；链路已断会抛 DATA_WRITTEN，由下面换链路补
            status = await session.confirmCustom(before.volume);
          } else {
            // 已预选：耳机写完后很快会收掉串口，再发命令只会撞 2901054 并白记一次冷却
            trace('TONE_ALREADY_SELECTED 传输前已选中，跳过收尾补发');
          }
          gate.emit(1, I18n.t('stage.applied'));
          const outcome: WriteOutcome = new WriteOutcome(status);
          outcome.flushConfirmed = report.flushConfirmed;
          outcome.attempts = round;
          WriteEngine.fillOutcome(outcome, session, deviceId, startedAt, settleWait);
          WriteEngine.logMatrix(deviceId, session, 'ok', `bytes=${pcm.length} rounds=${round} ` +
            `transfer=${report.transferMs}ms confirm=${report.flushConfirmed ? '09 06' : 'silent'}`);
          WriteEngine.scheduleAudioRestore(deviceId);
          return outcome;
        } catch (error) {
          // 失败过的会话不再进热会话池：链路可能已被耳机收回（合盖），复用只会对着死 socket 写
          session.close();
          const failure: ToneError = SppErrors.describe(error, neutral);
          const receivedAll: boolean = uploadState !== null && uploadState.receivedAll;
          const preselected: boolean = uploadState !== null && uploadState.preselected;
          WriteEngine.logMatrix(deviceId, session, 'fail', `code=${failure.code} reason=${failure.reason} ` +
            `round=${round} received=${receivedAll} preselected=${preselected}`);
          if (failure instanceof CancelledError || WriteEngine.cancelRequested) {
            if (preselected && !receivedAll) {
              WriteEngine.scheduleRollback(deviceId, neutral, before);
            }
            throw failure;
          }
          // 数据已经完整写进耳机、只差选中：换一条链路补一条命令，不重传整包
          if (failure.reason === ToneErrorReason.DATA_WRITTEN) {
            Logger.warn(MODULE, '音效数据已写入，改为换链路只补发选中命令');
            gate.emit(0.97, I18n.t('write.stageApplyOnly'));
            return await WriteEngine.applyOnly(deviceId, neutral, startedAt, settleWait, failure);
          }
          // 数据还没收完就断链：耳机侧没有落盘，整包重来一轮
          if (round < WriteSpec.MAX_UPLOAD_ROUNDS && !receivedAll && WriteEngine.isLinkFailure(failure)) {
            Logger.warn(MODULE, `串口在传输中断开，整包重来 code=${failure.code} round=${round}`);
            gate.emit(0.02, I18n.t('write.stageLinkRetry'));
            await sleep(WriteSpec.ROUND_GAP_MS);
            continue;
          }
          if (preselected) {
            WriteEngine.scheduleRollback(deviceId, neutral, before);
          }
          throw failure;
        } finally {
          WriteEngine.active = null;
          // 耳机收完整包才会去擦闪存：这时记沉降期，下一次连接要等它。
          // 传到一半断开不记——那种情况由串口掉线时记下的冷却负责，和旧实现一致
          session.endUpload(uploadState !== null && uploadState.receivedAll);
          WriteEngine.releaseSession(session);
        }
      }
      throw new ToneError(I18n.f('write.failedWith', [`${3003}`]));
    } finally {
      await WriteGuard.release();
    }
  }

  /** 数据已在耳机里：换一条新链路只补「选中自定义槽位」 */
  private static async applyOnly(deviceId: string, neutral: boolean, startedAt: number, settleWait: number,
    original: ToneError): Promise<WriteOutcome> {
    let session: MbbSession | null = null;
    try {
      session = await WriteEngine.openSession(deviceId, neutral, null, 2, MbbSpec.CONNECT_TOTAL_BUDGET_MS,
        (): void => {
        });
      const current: ToneStatus = await session.query();
      const status: ToneStatus = await session.confirmCustom(current.volume);
      Logger.info(MODULE, `补发选中成功 槽位=${status.toneId} 音量=${status.volume}`);
      const outcome: WriteOutcome = new WriteOutcome(status);
      outcome.via = 'apply-only';
      outcome.attempts = 2;
      WriteEngine.fillOutcome(outcome, session, deviceId, startedAt, settleWait);
      WriteEngine.logMatrix(deviceId, session, 'ok', 'via=apply-only');
      WriteEngine.scheduleAudioRestore(deviceId);
      return outcome;
    } catch (error) {
      Logger.warn(MODULE, `补发选中失败：${SppErrors.messageOf(error)}`);
      throw original;
    } finally {
      if (session !== null) {
        WriteEngine.releaseSession(session);
      }
    }
  }

  // ---------------------------------------------------------------- 命令类操作

  /** 恢复出厂开盒音 */
  static restoreDefault(deviceId: string, neutral: boolean): Promise<CommandOutcome> {
    return WriteEngine.userCommand((): Promise<CommandOutcome> => {
      return WriteEngine.runCommand(deviceId, neutral, 'restore', (session: MbbSession): Promise<ToneStatus> => {
        return session.restoreDefault();
      });
    });
  }

  private static async userCommand(task: () => Promise<CommandOutcome>): Promise<CommandOutcome> {
    WriteEngine.abandonRollback();
    WriteEngine.userOps++;
    try {
      return await WriteEngine.queue.run<CommandOutcome>(task);
    } finally {
      WriteEngine.userOps--;
    }
  }

  /** 切换到盒端内置音效：只发选中命令，不写闪存 */
  static selectBuiltIn(deviceId: string, neutral: boolean, id: number): Promise<CommandOutcome> {
    return WriteEngine.userCommand((): Promise<CommandOutcome> => {
      return WriteEngine.runCommand(deviceId, neutral, `tone id=${id}`, (session: MbbSession): Promise<ToneStatus> => {
        return session.selectBuiltIn(id);
      });
    });
  }

  private static async runCommand(deviceId: string, neutral: boolean, action: string,
    body: (session: MbbSession) => Promise<ToneStatus>): Promise<CommandOutcome> {
    WriteEngine.cancelAudioRestore();
    WriteEngine.cancelRequested = false;
    await WriteGuard.acquire();
    try {
      for (let round = 1; round <= 2; round++) {
        const session: MbbSession = await WriteEngine.openSession(deviceId, neutral, null, round,
          MbbSpec.CONNECT_TOTAL_BUDGET_MS, (): void => {
          });
        WriteEngine.active = session;
        try {
          const status: ToneStatus = await body(session);
          const outcome: CommandOutcome = new CommandOutcome(status);
          outcome.hwModel = WriteEngine.rememberModel(deviceId, session);
          outcome.protocol = session.protocolUsed;
          outcome.audioGate = session.audio.state;
          WriteEngine.logMatrix(deviceId, session, 'ok', `action=${action} tone=${status.toneId}`);
          WriteEngine.scheduleAudioRestore(deviceId);
          return outcome;
        } catch (error) {
          session.close();
          const failure: ToneError = SppErrors.describe(error, neutral);
          WriteEngine.logMatrix(deviceId, session, 'fail', `action=${action} code=${failure.code} ` +
            `reason=${failure.reason}`);
          if (round < 2 && !(failure instanceof CancelledError) && WriteEngine.isLinkFailure(failure)) {
            Logger.warn(MODULE, `${action} 链路中断，重试一次 code=${failure.code}`);
            await sleep(WriteSpec.ROUND_GAP_MS);
            continue;
          }
          throw failure;
        } finally {
          WriteEngine.active = null;
          WriteEngine.releaseSession(session);
        }
      }
      throw new ToneError(I18n.t('write.restoreFailed'));
    } finally {
      await WriteGuard.release();
    }
  }

  // ---------------------------------------------------------------- 会话

  /**
   * 取一条可用会话：同一台耳机的热会话还活着就复用（省掉约 3 秒建链），否则重新建链。
   * gate 为 null 时不显示阶段文案（后台回滚、命令类操作）。
   */
  private static async openSession(deviceId: string, neutral: boolean, gate: ProgressGate | null, round: number,
    budgetMs: number, onWaited: (ms: number) => void): Promise<MbbSession> {
    const timeline: DeviceTimeline = DeviceTimeline.of(deviceId);
    const cancelled: () => boolean = (): boolean => WriteEngine.cancelRequested;
    const pooled: MbbSession | null = WriteEngine.takePooled(deviceId);
    const audio: AudioLink = pooled !== null ? pooled.audio : new AudioLink(deviceId, timeline, trace, cancelled);
    const connector: LinkConnector = new LinkConnector(deviceId, neutral, timeline, audio, trace, cancelled);

    if (gate !== null) {
      gate.emit(0.02, round > 1 ? I18n.t('write.stageReconnect') : I18n.t('write.stageConnect'));
    }
    let logged: boolean = false;
    const waited: number = await connector.waitDeviceReady((kind: string, leftMs: number): void => {
      if (gate === null) {
        return;
      }
      if (kind === LinkConnector.WAIT_SETTLE) {
        // 刚写完上一条时耳机要擦闪存，这段静默常有 10 秒以上：把剩余秒数告诉用户
        gate.emit(0.02, I18n.f('write.stageWaitFlash', [`${Math.max(1, Math.ceil(leftMs / 1000))}`]));
      } else {
        gate.emit(0.02, I18n.t('write.stageWaitReady'));
      }
      if (!logged) {
        logged = true;
        Logger.info(MODULE, `等待耳机就绪 kind=${kind} left=${leftMs}ms`);
      }
    });
    onWaited(waited);
    if (waited > 0 && gate !== null) {
      gate.emit(0.02, I18n.t('write.stageConnect'));
    }

    if (pooled !== null) {
      if (await pooled.probeAlive()) {
        pooled.audio.state = AudioGateState.REUSED;
        Logger.info(MODULE, `SESSION_REUSE 复用热会话 idle=${Date.now() - pooled.channel.lastIoAt}ms`);
        return pooled;
      }
      Logger.info(MODULE, 'SESSION_DEAD 热会话探测无响应，改为重新建链');
      pooled.close();
    }
    const fresh: AudioLink = pooled !== null ? new AudioLink(deviceId, timeline, trace, cancelled) : audio;
    const freshConnector: LinkConnector = pooled !== null ?
      new LinkConnector(deviceId, neutral, timeline, fresh, trace, cancelled) : connector;
    // 走到这里时热会话要么已复用返回、要么已关掉：本进程里还开着的串口都是遗留的
    Logger.info(MODULE, `SOCKET_LEDGER before_connect ${SppChannel.ledger()}`);
    SppChannel.sweepOrphans();
    const startedAt: number = Date.now();
    const channel: SppChannel = await freshConnector.open(budgetMs);
    const session: MbbSession = new MbbSession(channel, fresh, timeline, trace);
    session.startKeepAlive();
    Logger.info(MODULE, `LINK_OPEN ms=${Date.now() - startedAt} secure=${channel.secure} audio=${fresh.state}`);
    // 加密通道曾被认为传大包会断（旧注释），但 2026-11-26 的 31 次加密写入全部正常，不再告警
    return session;
  }

  private static takePooled(deviceId: string): MbbSession | null {
    const pooled: MbbSession | null = WriteEngine.pooled;
    WriteEngine.pooled = null;
    WriteEngine.cancelPoolTimer();
    if (pooled === null) {
      return null;
    }
    if (pooled.address.toUpperCase() === deviceId.toUpperCase() && pooled.channel.isFresh(45000)) {
      return pooled;
    }
    Logger.info(MODULE, 'SESSION_STALE 热会话已失效');
    pooled.close();
    return null;
  }

  /** 用完交还：刚写完闪存、已断开或已取消就直接关；否则留一段热连接 */
  private static releaseSession(session: MbbSession): void {
    const timeline: DeviceTimeline = DeviceTimeline.of(session.address);
    if (!session.isOpen() || WriteEngine.cancelRequested || timeline.settleLeft() > 0) {
      // 刚写完闪存：耳机随后会自己收掉 SPP，留着只会让下一次撞在死 socket 上
      session.close();
      return;
    }
    session.resetForReuse();
    const held: MbbSession | null = WriteEngine.pooled;
    if (held !== null && held !== session) {
      held.close();
    }
    WriteEngine.pooled = session;
    WriteEngine.cancelPoolTimer();
    WriteEngine.poolTimer = setTimeout(() => {
      WriteEngine.poolTimer = -1;
      const expired: MbbSession | null = WriteEngine.pooled;
      WriteEngine.pooled = null;
      if (expired !== null) {
        Logger.info(MODULE, `SESSION_EXPIRE 闲置超过 ${MbbSpec.SESSION_TTL_MS}ms，关闭串口`);
        expired.close();
      }
    }, MbbSpec.SESSION_TTL_MS);
  }

  private static cancelPoolTimer(): void {
    if (WriteEngine.poolTimer >= 0) {
      clearTimeout(WriteEngine.poolTimer);
      WriteEngine.poolTimer = -1;
    }
  }

  // ---------------------------------------------------------------- 失败回滚

  /**
   * 预选了目标槽位但数据没写完：槽位是空的，开盖会没声音或回落默认音。
   * 回滚到写入前在用的音效——之前是内置音就切回那条内置音，之前是自定义音（同一槽位已被覆盖）或默认音则恢复出厂。
   * 失败时串口通常刚断，立刻重连只会先吃冷却，所以放到后台、延迟执行。
   */
  private static scheduleRollback(deviceId: string, neutral: boolean, before: ToneStatus | null): void {
    let target: number = 0;
    if (before !== null && before.toneId > 0 && before.toneId !== MbbSpec.TONE_CUSTOM_ID) {
      target = before.toneId;
    }
    Logger.info(MODULE, `写入未完成且已预选自定义槽，安排后台回滚 target=${target}`);
    // 槽位状态不可信：先把「盒内音效」标记清掉
    SettingsService.setLastWrittenTone('');
    WriteEngine.cancelRollbackTimer();
    WriteEngine.rollbackPending = true;
    WriteEngine.rollbackLater(new RollbackPlan(deviceId, neutral, target), 0, WriteSpec.ROLLBACK_FIRST_DELAY_MS);
  }

  private static rollbackLater(plan: RollbackPlan, attempt: number, delayMs: number): void {
    WriteEngine.rollbackTimer = setTimeout(() => {
      WriteEngine.rollbackTimer = -1;
      if (!WriteEngine.rollbackPending) {
        return;
      }
      WriteEngine.queue.run<number>((): Promise<number> => WriteEngine.runRollback(plan, attempt))
        .then((result: number) => {
          // 已完成、或已被用户的新操作放弃
          if (result === RollbackResult.DONE || !WriteEngine.rollbackPending) {
            return;
          }
          if (result === RollbackResult.RETRY && attempt + 1 < WriteSpec.ROLLBACK_ATTEMPTS &&
            plan.connectTries < WriteSpec.ROLLBACK_CONNECT_TRIES) {
            WriteEngine.rollbackLater(plan, attempt + 1, WriteSpec.ROLLBACK_RETRY_DELAY_MS);
            return;
          }
          WriteEngine.rollbackPending = false;
          Logger.warn(MODULE, `回滚已放弃：耳机仍不可达 tries=${plan.connectTries} result=${result}`);
          // 恢复不了也要把音频通道放回来，免得用户连歌都听不了
          WriteEngine.scheduleAudioRestore(plan.deviceId);
        }).catch((error: Error) => {
          WriteEngine.rollbackPending = false;
          Logger.warn(MODULE, `回滚异常：${error.message}`);
        });
    }, delayMs);
  }

  private static async runRollback(plan: RollbackPlan, attempt: number): Promise<number> {
    if (!WriteEngine.rollbackPending) {
      return RollbackResult.GIVE_UP;
    }
    // 盒盖合着（音频没连）时连串口只会被秒拒：先等用户开盖，最多等一轮间隔
    if (!AudioLink.linked(plan.deviceId)) {
      Logger.info(MODULE, `回滚等待开盖（第 ${attempt + 1} 次）：音频未连接，暂不建链`);
      return RollbackResult.RETRY;
    }
    WriteEngine.cancelRequested = false;
    WriteEngine.rollbackRunning = true;
    plan.connectTries++;
    await WriteGuard.acquire();
    let session: MbbSession | null = null;
    try {
      session = await WriteEngine.openSession(plan.deviceId, plan.neutral, null, 1,
        WriteSpec.ROLLBACK_CONNECT_BUDGET_MS, (): void => {
        });
      const status: ToneStatus = plan.targetId > 0 ? await session.selectBuiltIn(plan.targetId) :
        await session.restoreDefault();
      Logger.info(MODULE, `回滚完成（第 ${attempt + 1} 次）tone=${status.toneId}`);
      WriteEngine.rollbackPending = false;
      WriteEngine.scheduleAudioRestore(plan.deviceId);
      return RollbackResult.DONE;
    } catch (error) {
      const failure: ToneError = SppErrors.describe(error, plan.neutral);
      Logger.warn(MODULE, `回滚失败（第 ${attempt + 1} 次）code=${failure.code} reason=${failure.reason}`);
      // 卡死或被用户打断：再试也没用，交给用户
      if (failure.reason === ToneErrorReason.WEDGED || failure instanceof CancelledError) {
        return RollbackResult.GIVE_UP;
      }
      return RollbackResult.RETRY;
    } finally {
      WriteEngine.rollbackRunning = false;
      if (session !== null) {
        WriteEngine.releaseSession(session);
      }
      await WriteGuard.release();
    }
  }

  private static cancelRollbackTimer(): void {
    if (WriteEngine.rollbackTimer >= 0) {
      clearTimeout(WriteEngine.rollbackTimer);
      WriteEngine.rollbackTimer = -1;
    }
  }

  // ---------------------------------------------------------------- 音频恢复

  /**
   * 写入过程中断开了音频通道：结束后延迟重连，尽力恢复听歌状态。
   * 耳机擦闪存期间不接受新连接，所以要等；耳机常在写完后自己把 A2DP 连回来，那就不必再连。
   */
  private static scheduleAudioRestore(deviceId: string): void {
    WriteEngine.cancelAudioRestore();
    BluetoothService.markCaseSettling(deviceId, WriteSpec.AUDIO_RESTORE_DELAY_MS);
    WriteEngine.audioRestoreTimer = setTimeout(() => {
      WriteEngine.audioRestoreTimer = -1;
      BluetoothService.endCaseSettling();
      if (WriteEngine.isBusy()) {
        Logger.info(MODULE, '有新的设备操作在进行，跳过音频恢复');
        return;
      }
      if (BluetoothService.isAudioConnected(deviceId)) {
        Logger.info(MODULE, `音频通道已自行恢复，跳过重连 ${FormatUtils.maskAddress(deviceId)}`);
        return;
      }
      BluetoothService.connect(deviceId).then(() => {
        Logger.info(MODULE, `已恢复音频通道 ${FormatUtils.maskAddress(deviceId)}`);
        BluetoothService.refreshDebounced(2500);
      }).catch((error: BusinessError) => {
        Logger.info(MODULE, `恢复音频通道失败（不影响音效）code=${error.code}`);
      });
    }, WriteSpec.AUDIO_RESTORE_DELAY_MS);
  }

  private static cancelAudioRestore(): void {
    if (WriteEngine.audioRestoreTimer >= 0) {
      clearTimeout(WriteEngine.audioRestoreTimer);
      WriteEngine.audioRestoreTimer = -1;
      Logger.info(MODULE, '已取消待执行的音频恢复');
    }
  }

  // ---------------------------------------------------------------- 杂项

  private static uploadTiming(): UploadTiming {
    const timing: UploadTiming = new UploadTiming();
    timing.totalMs = MbbSpec.UPLOAD_TOTAL_TIMEOUT_MS;
    timing.idleMs = MbbSpec.UPLOAD_IDLE_TIMEOUT_MS;
    timing.flushMs = MbbSpec.UPLOAD_FLUSH_TIMEOUT_MS;
    timing.confirmMs = MbbSpec.UPLOAD_FLUSH_CONFIRM_MS;
    return timing;
  }

  private static fillOutcome(outcome: WriteOutcome, session: MbbSession, deviceId: string, startedAt: number,
    settleWait: number): void {
    outcome.hwModel = WriteEngine.rememberModel(deviceId, session);
    outcome.protocol = session.protocolUsed;
    outcome.audioGate = session.audio.state;
    outcome.settleWaitMs = settleWait;
    outcome.elapsedMs = Date.now() - startedAt;
    outcome.backgrounded = WriteGuard.wasBackgrounded();
  }

  /** 把本次会话查到的型号写进缓存，返回可用于日志/诊断的型号 */
  private static rememberModel(deviceId: string, session: MbbSession): string {
    if (session.deviceModel.length > 0) {
      BluetoothService.noteDeviceModel(deviceId, session.deviceModel);
      return session.deviceModel;
    }
    return BluetoothService.deviceModelOf(deviceId);
  }

  /** 机型矩阵：收集未验证机型兼容性的关键一行，成功失败都记 */
  private static logMatrix(deviceId: string, session: MbbSession, result: string, extra: string): void {
    const hwModel: string = WriteEngine.rememberModel(deviceId, session);
    const btName: string = BluetoothService.getSnapshot().activeName;
    const line: string = `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
      `btName=${btName.length > 0 ? btName : '未知'} id=${FormatUtils.maskAddress(deviceId)} ` +
      `protocol=${session.protocolUsed} audio=${session.audio.state} secure=${session.channel.secure} ` +
      `bg=${WriteGuard.wasBackgrounded()} bgMs=${WriteGuard.backgroundMs()} ` +
      `bgTask=${WriteGuard.hasContinuousTask() ? 'bt' : 'transient'} result=${result} ${extra}`;
    if (result === 'ok') {
      Logger.info(MODULE, line);
    } else {
      Logger.warn(MODULE, line);
    }
  }
}
