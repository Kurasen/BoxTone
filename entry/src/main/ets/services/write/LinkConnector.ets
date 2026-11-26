import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { Logger } from '../../common/utils/Logger';
import { CancelledError, TONE_CODE_UNREACHABLE, ToneError, ToneErrorReason } from '../bluetooth/ToneTypes';
import { AudioGateState, AudioLink, RestoreOutcome } from './AudioLink';
import { DeviceTimeline } from './DeviceTimeline';
import { SppChannel } from './SppChannel';
import { SppErrors } from './SppErrors';
import { WriteSpec } from './WriteSpec';
import { TraceSink } from './WriteTypes';

const MODULE: string = 'LinkConnector';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 建链时可观测的等待：界面据此显示「等耳机擦完上一条」而不是「连接中」 */
export type WaitNotice = (kind: string, leftMs: number) => void;

/**
 * 建立一条「耳机真的开口了」的串口。
 *
 * 顺序和每个数值都沿用旧实现（多轮真机日志调出来的）：
 * 1. 冷却：耳机收掉串口后十几秒内拒绝连接；音频自己连回来说明它已收尾，可提前放行。
 * 2. 沉降：刚写完一条时耳机还在收尾，一律等满 WriteSpec.POST_FLASH_GAP_MS（音频连回不代表收尾结束）。
 * 3. 音频还连着就先松开：连着时第一枪 sppConnect 几乎必然 -1。
 * 4. 非加密优先、两种通道交替各试一次；连上后 600ms 内耳机不开口就当半死通道重来。
 * 5. 「音频断不开 + 串口一再被拒」时提前收手并给出准确指引，不让用户白等。
 */
export class LinkConnector {
  /**
   * 本进程里是否已经判定过串口卡死。
   * 真机上卡死后一直持续到应用进程退出（合盖、关开耳机都无效），之后每一轮的失败形态还不一样
   * （有时全是 -1，有时是秒拒的 2900099），单轮里未必够得上判定条件。
   * 所以判定过一次就记住：后续建链仍照常尝试，成功就清掉；失败则直接按卡死归因，引导重启应用。
   */
  private static wedgedSince: number = 0;

  static readonly WAIT_COOLDOWN: string = 'cooldown';
  static readonly WAIT_SETTLE: string = 'settle';

  private readonly address: string;
  private readonly neutral: boolean;
  private readonly timeline: DeviceTimeline;
  private readonly audio: AudioLink;
  private readonly trace: TraceSink;
  private readonly cancelled: () => boolean;

  constructor(address: string, neutral: boolean, timeline: DeviceTimeline, audio: AudioLink,
    trace: TraceSink, cancelled: () => boolean) {
    this.address = address;
    this.neutral = neutral;
    this.timeline = timeline;
    this.audio = audio;
    this.trace = trace;
    this.cancelled = cancelled;
  }

  /** 等冷却与沉降结束；返回实际等待的毫秒数 */
  async waitDeviceReady(notice: WaitNotice): Promise<number> {
    const startedAt: number = Date.now();
    const cooling: number = this.timeline.cooldownLeft();
    if (cooling > 0) {
      notice(LinkConnector.WAIT_COOLDOWN, cooling);
      this.trace(`LINK_COOLDOWN wait=${cooling}ms`);
      const until: number = Date.now() + cooling;
      while (Date.now() < until) {
        this.throwIfCancelled();
        // 音频被耳机连回来，说明它已把上一段写完，不必白等满冷却
        if (this.audio.isLinked()) {
          this.trace('LINK_COOLDOWN_SKIP 音频通道已恢复');
          break;
        }
        await sleep(Math.min(200, Math.max(1, until - Date.now())));
      }
    }
    const settling: number = this.timeline.settleLeft();
    if (settling > 0) {
      notice(LinkConnector.WAIT_SETTLE, settling);
      this.trace(`FLASH_SETTLE wait=${settling}ms`);
      const until: number = Date.now() + settling;
      let lastSecond: number = Math.ceil(settling / 1000);
      while (Date.now() < until) {
        this.throwIfCancelled();
        // 每过一秒刷新一次倒计时：要等二十多秒，界面停在一个数上会像卡住了
        const second: number = Math.ceil((until - Date.now()) / 1000);
        if (second !== lastSecond && second > 0) {
          lastSecond = second;
          notice(LinkConnector.WAIT_SETTLE, until - Date.now());
        }
        await sleep(Math.min(200, Math.max(1, until - Date.now())));
      }
    }
    return Date.now() - startedAt;
  }

  /** 建链；成功返回已确认耳机开口的通道 */
  async open(budgetMs: number): Promise<SppChannel> {
    const startedAt: number = Date.now();
    /**
     * 通道顺序：加密优先，非加密兜底。
     *
     * 2026-11-26 对照：非加密优先、加密优先、断开后等 1 秒、等 2 秒，四种组合下都是
     * 「第一枪被耳机拒（-1，约 0.7 秒）、第二枪成功」，与通道和等待时长都无关。
     * 两种通道都能用，顺序无所谓，保留加密优先（成功样本更多）。详见 docs/write-engine.md 9.2。
     */
    const modes: boolean[] = [true, false];
    let lastError: ToneError | null = null;
    let silentFailures: number = 0;
    let audioRelinks: number = 0;
    let releaseTried: boolean = false;
    let probeNext: boolean = false;
    let rejected: number = 0;
    /** 连续「秒拒」次数：本机协议栈直接拒绝，说明串口状态已经卡住 */
    let fastRejects: number = 0;
    /** 本轮累计「秒拒」次数：沿用进程级卡死判定的前提——请求根本没出手机 */
    let fastRejectsSeen: number = 0;
    /** 是否出现过「音频已松开、耳机却完全不回应」：耳机还在忙，此后的拒绝多半是卡死 */
    let sawBusyTimeout: boolean = false;
    /** 本轮是否已经尝试过把音频连回来 */
    let restoreTried: boolean = false;

    // 音频不在：先连回来，回到「音频连着 → 断开 → 连串口」这个唯一稳定成功的顺序
    if (!this.audio.isLinked()) {
      restoreTried = true;
      Logger.info(MODULE, 'AUDIO_IDLE_BEFORE_CONNECT 音频未连接，先连回音频再建串口');
      await this.audio.restore(WriteSpec.AUDIO_RESTORE_WAIT_MS);
      this.throwIfCancelled();
      if (this.audio.lastRestore === RestoreOutcome.TIMEOUT) {
        throw this.unreachable('before_connect');
      }
    }

    if (this.timeline.releaseHint && this.audio.isLinked()) {
      releaseTried = true;
      probeNext = await this.audio.release();
      this.throwIfCancelled();
    }

    const sinceClose: number = Date.now() - this.timeline.lastCloseAt;
    if (this.timeline.lastCloseAt > 0 && sinceClose < MbbSpec.SOCKET_SETTLE_MS) {
      await sleep(MbbSpec.SOCKET_SETTLE_MS - sinceClose);
    }
    const deadline: number = Date.now() + budgetMs;

    for (let round = 0; round < 40; round++) {
      for (let mode = 0; mode < modes.length; mode++) {
        this.throwIfCancelled();
        if (Date.now() > deadline) {
          throw sawBusyTimeout ? this.stalled('budget busy_timeout=true') : this.finalError(lastError, fastRejectsSeen);
        }
        if (round > 0 || mode > 0) {
          await sleep(Math.min(MbbSpec.CONNECT_RETRY_GAP_MS + round * 200, 1500));
        }
        const secure: boolean = modes[mode];
        // 音频还没松开时先用短超时探一次：耳机可能直接不回应
        const audioUp: boolean = !releaseTried && this.audio.isLinked();
        // 刚断开音频后的第一枪同样短超时：ACL 拆链未收敛时这条请求可能卡死
        const postRelease: boolean = probeNext;
        probeNext = false;
        const timeout: number = audioUp ? MbbSpec.CONNECT_PROBE_TIMEOUT_MS :
          (postRelease ? MbbSpec.CONNECT_POST_RELEASE_MS : MbbSpec.CONNECT_TIMEOUT_MS);
        const sinceRelease: number = this.audio.releasedAt > 0 ? Date.now() - this.audio.releasedAt : -1;
        this.trace(`CONNECT try secure=${secure} round=${round + 1} timeout=${timeout} sinceRelease=${sinceRelease}ms`);
        const tryAt: number = Date.now();
        try {
          const channel: SppChannel = await this.connectAndListen(secure, timeout);
          if (LinkConnector.wedgedSince > 0) {
            Logger.info(MODULE, `LINK_UNWEDGED 卡死 ${Date.now() - LinkConnector.wedgedSince}ms 后自行恢复`);
            LinkConnector.wedgedSince = 0;
          }
          Logger.info(MODULE, `CONNECTED secure=${secure} ms=${Date.now() - startedAt} audio=${this.audio.state} ` +
            `tries=${round * modes.length + mode + 1}`);
          return channel;
        } catch (error) {
          if (error instanceof CancelledError) {
            throw error as Error;
          }
          const failure: ToneError = SppErrors.describe(error, this.neutral);
          lastError = failure;
          const tookMs: number = Date.now() - tryAt;
          this.trace(`CONNECT_FAILED secure=${secure} code=${failure.code} ms=${tookMs} ${failure.message}`);
          // 这一条请求超时且系统一直没回调：先等它回来，绝不在它挂着的时候再塞新请求
          if (failure.code === 0 && tookMs >= timeout - 100 && SppChannel.isHung()) {
            const adopted: SppChannel | null = await this.waitHungConnect(secure);
            if (adopted !== null) {
              LinkConnector.wedgedSince = 0;
              Logger.info(MODULE, `CONNECTED secure=${secure} ms=${Date.now() - startedAt} audio=${this.audio.state} via=late`);
              return adopted;
            }
            if (SppChannel.isHung()) {
              throw this.stalled(`hung_connect secure=${secure} waited=${WriteSpec.HUNG_CONNECT_WAIT_MS}ms`);
            }
          }
          if (failure.code === SppErrors.NOT_ACCEPTED && tookMs < WriteSpec.FAST_REJECT_MS) {
            fastRejects++;
            fastRejectsSeen++;
            if (fastRejects >= WriteSpec.FAST_REJECT_LIMIT) {
              throw this.wedged(`fast_reject=${fastRejects} busy_timeout=${sawBusyTimeout}`);
            }
          } else {
            fastRejects = 0;
          }
          if (failure.code === 0 && !audioUp) {
            sawBusyTimeout = true;
          }
          if (failure.code === -97) {
            silentFailures++;
            if (silentFailures >= 3) {
              throw new ToneError(this.neutral ? I18n.t('toneErr.noResponseNeutral') : I18n.t('toneErr.noResponse'));
            }
          }
          // 刚断开的音频又被连回来。系统本身也会自动回连，所以先看串口是不是已经卡住
          if (this.audio.state === AudioGateState.RELEASED && this.audio.isLinked()) {
            audioRelinks++;
            this.trace(`AUDIO_RELINK ${audioRelinks}`);
            if (audioRelinks >= 2 && sawBusyTimeout) {
              throw this.stalled(`audio_relink=${audioRelinks} busy_timeout=true`);
            }
            if (audioRelinks >= 2 && LinkConnector.wedgedSince > 0 && fastRejectsSeen > 0) {
              throw this.wedged(`sticky audio_relink=${audioRelinks}`);
            }
            if (audioRelinks >= 2) {
              const reclaimed: ToneError = new ToneError(I18n.t('toneErr.audioReclaimed'), SppErrors.NOT_ACCEPTED);
              reclaimed.reason = ToneErrorReason.LINK;
              throw reclaimed;
            }
          }
          // -1「还没准备好」、2900099「通道忙」、2900004、以及音频连着时的无响应：值得先松开音频再试
          const transient: boolean = failure.code === -1 || failure.code === SppErrors.NOT_ACCEPTED ||
            failure.code === SppErrors.NO_SPP || (audioUp && (failure.code === 0 || failure.code === -97));
          if (!releaseTried && transient) {
            releaseTried = true;
            probeNext = await this.audio.release();
            continue;
          }
          // 耳机慢速拒绝（请求到了耳机）且此刻音频不在：把音频连回来再断开，只做一次
          // 只在音频从没连上过（IDLE）时补：音频是我们刚断开的（RELEASED）就不算——20:01 那次就是误触发
          if (!restoreTried && failure.code === -1 && tookMs >= WriteSpec.FAST_REJECT_MS &&
            this.audio.state === AudioGateState.IDLE && !this.audio.isLinked()) {
            restoreTried = true;
            Logger.info(MODULE, 'AUDIO_IDLE_REJECT 耳机拒绝且音频未连接，连回音频后重试');
            if (await this.audio.restore(WriteSpec.AUDIO_RESTORE_WAIT_MS)) {
              probeNext = await this.audio.release();
            } else if (this.audio.lastRestore === RestoreOutcome.TIMEOUT) {
              throw this.unreachable('after_reject');
            }
            continue;
          }
          if (releaseTried) {
            rejected++;
            // 门槛远高于真机观察到的「第 6 次请求才开门」，否则会把成功拦在门外
            if (this.audio.state === AudioGateState.KEPT && rejected >= 14) {
              throw this.finalError(lastError, fastRejectsSeen);
            }
          }
          if (failure.code === SppErrors.NOT_ACCEPTED) {
            await sleep(300);
          }
        }
      }
    }
    throw this.finalError(lastError, fastRejectsSeen);
  }

  /** 单次建链 + 等耳机开口。连上但不开口的通道视为半死，关掉并以 -97 失败 */
  private async connectAndListen(secure: boolean, timeoutMs: number): Promise<SppChannel> {
    const id: number = await SppChannel.connect(this.address, secure, timeoutMs, this.neutral);
    return await this.listen(id, secure);
  }

  /**
   * 挂起的连接请求：不再发新请求，等它迟到回调。
   * 返回迟到成功的通道；迟到失败返回 null（照常重试）；等满仍没回来也返回 null，由调用方判定卡死。
   */
  private async waitHungConnect(secure: boolean): Promise<SppChannel | null> {
    Logger.warn(MODULE, `CONNECT_HUNG_WAIT 连接请求挂起，最多再等 ${WriteSpec.HUNG_CONNECT_WAIT_MS}ms，期间不发新请求`);
    const startedAt: number = Date.now();
    const until: number = startedAt + WriteSpec.HUNG_CONNECT_WAIT_MS;
    while (Date.now() < until) {
      this.throwIfCancelled();
      const id: number = await SppChannel.awaitLate(Math.min(500, until - Date.now()));
      if (id === -2) {
        continue;
      }
      if (id < 0) {
        Logger.info(MODULE, `CONNECT_HUNG_FAILED 挂起的请求 ${Date.now() - startedAt}ms 后以失败返回，继续重试`);
        return null;
      }
      Logger.info(MODULE, `CONNECT_HUNG_ADOPTED 挂起的请求 ${Date.now() - startedAt}ms 后迟到成功，直接使用`);
      try {
        return await this.listen(id, secure);
      } catch (error) {
        if (error instanceof CancelledError) {
          throw error as Error;
        }
        return null;
      }
    }
    return null;
  }

  /** 挂上读监听、等耳机开口。连上但不开口的通道视为半死，关掉并以 -97 失败 */
  private async listen(id: number, secure: boolean): Promise<SppChannel> {
    const channel: SppChannel = new SppChannel(id, this.address, secure, this.timeline, this.trace);
    if (this.cancelled()) {
      channel.close();
      throw new CancelledError();
    }
    channel.attach(this.neutral);
    const readyAt: number = Date.now();
    while (channel.rxCount === 0 && Date.now() - readyAt < MbbSpec.LINK_READY_TIMEOUT_MS) {
      if (this.cancelled()) {
        channel.close();
        throw new CancelledError();
      }
      await sleep(30);
    }
    this.trace(`LINK_READY rx=${channel.rxCount} wait=${Date.now() - readyAt}ms`);
    if (channel.rxCount === 0) {
      // 连上但一声不吭：ACL 还没收敛时的半死通道，关掉换一种通道重来
      channel.cancel();
      throw new ToneError(I18n.t('toneErr.silentReconnect'), -97);
    }
    return channel;
  }

  /**
   * 本机串口卡死（连接请求在本机就被秒拒）：重试只会继续被拒，重启应用进程才能恢复。
   * 提前收手、给出这条唯一有效的指引，而不是让用户等满预算再看到「被其他应用占用」。
   */
  private wedged(detail: string): ToneError {
    if (LinkConnector.wedgedSince === 0) {
      LinkConnector.wedgedSince = Date.now();
    }
    Logger.warn(MODULE, `LINK_WEDGED ${detail} ${SppChannel.ledger()}`);
    const error: ToneError = new ToneError(I18n.t('toneErr.linkWedged'), SppErrors.NOT_ACCEPTED);
    error.reason = ToneErrorReason.WEDGED;
    error.diagnostic = `LINK_WEDGED ${detail}`;
    return error;
  }

  /**
   * 音频连不回来：耳机够不着，多半盒盖合着。不再试串口，直接请用户开盖后重试。
   *
   * 2026-11-26 两次「连回音频 5 秒超时后照样去连串口」：20:58:45 sppConnect 挂起，只能关开蓝牙恢复（10 节）；
   * 23:18:26 盒盖合着，两条请求各挂起 3~4 秒后迟到失败，耗满预算被误判成卡死（3005，15 节）。
   * 音频本来就断开时串口从没连上过（8.2 节），而挂起的 sppConnect 正是卡死的起点，所以宁可早停。
   * 只认超时：系统拒绝连回（DENIED）判断不了耳机状态，照旧去试串口。
   */
  private unreachable(stage: string): ToneError {
    Logger.warn(MODULE, `EARBUD_UNREACHABLE stage=${stage} 音频连不回来，不再尝试串口`);
    const error: ToneError = new ToneError(I18n.t('toneErr.unreachable'), TONE_CODE_UNREACHABLE);
    error.reason = ToneErrorReason.UNREACHABLE;
    error.diagnostic = `EARBUD_UNREACHABLE stage=${stage}`;
    return error;
  }

  /**
   * 连接请求挂起、耳机一直不回应：不一定卡死。
   *
   * 2026-11-26 真机：23:43:44 hung_connect 判定后 16 秒，不重启直接写入成功（LINK_UNWEDGED，18 节）；
   * 但 22:38:40 那次之后紧接着变成秒拒（真卡死），20:02 / 21:08 也要重启或关开蓝牙。
   * 所以只说「没回应」、给重试；再试时若已变成秒拒，会在约 3 秒内判成 WEDGED，届时再引导重启应用。
   * 同样记 wedgedSince：之后一轮里出现秒拒就沿用进程级卡死判定（finalError 的 sticky 分支）。
   */
  private stalled(detail: string): ToneError {
    if (LinkConnector.wedgedSince === 0) {
      LinkConnector.wedgedSince = Date.now();
    }
    Logger.warn(MODULE, `LINK_STALLED ${detail} ${SppChannel.ledger()}`);
    const error: ToneError = new ToneError(I18n.t('toneErr.linkStalled'), 0);
    error.reason = ToneErrorReason.STALLED;
    error.diagnostic = `LINK_STALLED ${detail}`;
    return error;
  }

  /** 建链彻底失败时的归因：音频被占着和耳机没准备好是两种完全不同的处置 */
  private finalError(lastError: ToneError | null, fastRejectsSeen: number = 0): ToneError {
    // 进程里判定过卡死，且这一轮仍有「秒拒」：多半还没恢复。
    // 只有慢速的 -1（请求到了耳机、被耳机拒）不算，那是耳机没准备好，例如刚开盖
    if (LinkConnector.wedgedSince > 0 && fastRejectsSeen > 0) {
      return this.wedged(`sticky last_code=${lastError !== null ? lastError.code : 0}`);
    }
    if (lastError === null) {
      return new ToneError(this.neutral ? I18n.t('toneErr.cannotConnectNeutral') : I18n.t('toneErr.cannotConnect'));
    }
    if (this.audio.state === AudioGateState.KEPT && this.audio.isLinked()) {
      const held: ToneError = new ToneError(I18n.t('toneErr.audioHeld'),
        lastError.code !== 0 ? lastError.code : SppErrors.NOT_ACCEPTED);
      held.reason = ToneErrorReason.AUDIO_HELD;
      held.diagnostic = `AUDIO_GATE=kept last_code=${lastError.code}`;
      return held;
    }
    if (lastError.code === SppErrors.NOT_ACCEPTED) {
      const notAccepted: ToneError = new ToneError(this.neutral ? I18n.t('toneErr.notAcceptedNeutral') :
        I18n.t('toneErr.notAccepted'), SppErrors.NOT_ACCEPTED);
      notAccepted.reason = ToneErrorReason.LINK;
      return notAccepted;
    }
    // 两种通道都回 -1 而音频并没被别人占着：多半是刚开盖还没准备好，合盖再开盖即可
    if (lastError.code === -1 && !this.neutral && this.audio.state !== AudioGateState.KEPT) {
      const notReady: ToneError = new ToneError(I18n.t('toneErr.notReady'), -1);
      notReady.diagnostic = `AUDIO_GATE=${this.audio.state} last_code=-1 both_modes_rejected`;
      return notReady;
    }
    if (lastError.code === -97) {
      // 半死通道不是用户能理解的错误：退回「耳机没响应」
      return new ToneError(this.neutral ? I18n.t('toneErr.noResponseNeutral') : I18n.t('toneErr.noResponse'));
    }
    return lastError;
  }

  private throwIfCancelled(): void {
    if (this.cancelled()) {
      throw new CancelledError();
    }
  }
}
