import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { AppEvent, EventBus } from '../../common/utils/EventBus';
import { Logger } from '../../common/utils/Logger';
import { ToneEntry } from '../../models/ToneModel';
import { BluetoothService } from '../BluetoothService';
import { CaseWriteService, WriteCode, WriteReason, WriteResult } from '../CaseWriteService';
import { SettingsService } from '../SettingsService';
import { WriteEngine } from './WriteEngine';
import { WriteStep } from './WriteTypes';

const MODULE: string = 'WriteTask';
/** AppStorage 键：每次任务状态变化自增，写入弹窗用 @StorageProp 订阅 */
export const WRITE_EPOCH: string = 'writeEpoch';
/** 取消后弹窗停留多久自动收起 */
const CANCELLED_DISMISS_MS: number = 2500;

/** 任务种类：写音效、恢复默认、切换内置音效共用一个弹窗 */
export class TaskKind {
  static readonly TONE: string = 'tone';
  static readonly RESTORE: string = 'restore';
  static readonly BUILTIN: string = 'builtin';
}

/** 弹窗显示的阶段：运行中沿用引擎的 WriteStep，另加空闲与三种结局 */
export class TaskPhase {
  static readonly IDLE: string = 'idle';
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
  static readonly CANCELLED: string = 'cancelled';

  static isTerminal(phase: string): boolean {
    return phase === TaskPhase.DONE || phase === TaskPhase.FAILED || phase === TaskPhase.CANCELLED;
  }
}

/** 弹窗要的全部状态：每次取一份新对象，@State 赋值才会触发刷新 */
export class TaskSnapshot {
  kind: string = TaskKind.TONE;
  phase: string = TaskPhase.IDLE;
  /** 音效名或内置音效名 */
  title: string = '';
  /** 0~100 */
  progress: number = 0;
  /** 引擎给的阶段细节，例如「等待耳机完成上一次写入（约 12 秒）」 */
  stage: string = '';
  /** 结局文案 */
  message: string = '';
  /** 失败时的下一步建议 */
  hint: string = '';
  code: number = 0;
  reason: string = '';
  diagnostic: string = '';
  cancelling: boolean = false;
}

/**
 * 写入任务的全局状态。
 *
 * 页面只负责前置检查和确认框，确认后交给这里；进度、结局、重试都显示在 Index 上层的写入弹窗里，
 * 写入期间弹窗是模态的，用户切不了页签、也点不到下面的按钮（参考 feat/write-flow-v2 的交互）。
 * 这里不编排设备操作——那是 WriteEngine 的事，这里只把一次操作的过程翻译成弹窗状态。
 */
export class WriteTask {
  private static snap: TaskSnapshot = new TaskSnapshot();
  /** 失败后「重试」要重放的动作 */
  private static lastRun: (() => Promise<WriteResult>) | null = null;
  private static dismissTimer: number = -1;

  /** 弹窗是否在显示（含结局等用户点掉） */
  static isActive(): boolean {
    return WriteTask.snap.phase !== TaskPhase.IDLE;
  }

  /** 是否正在和耳机通信 */
  static isRunning(): boolean {
    return WriteTask.isActive() && !TaskPhase.isTerminal(WriteTask.snap.phase);
  }

  static snapshot(): TaskSnapshot {
    const copy: TaskSnapshot = new TaskSnapshot();
    const s: TaskSnapshot = WriteTask.snap;
    copy.kind = s.kind;
    copy.phase = s.phase;
    copy.title = s.title;
    copy.progress = s.progress;
    copy.stage = s.stage;
    copy.message = s.message;
    copy.hint = s.hint;
    copy.code = s.code;
    copy.reason = s.reason;
    copy.diagnostic = s.diagnostic;
    copy.cancelling = s.cancelling;
    return copy;
  }

  /** 传输开始前可以取消：之后目标槽位已预选，中途停下会让开盖没有声音 */
  static isCancellable(): boolean {
    const phase: string = WriteTask.snap.phase;
    return !WriteTask.snap.cancelling &&
      (phase === WriteStep.WAIT || phase === WriteStep.CONNECT || phase === WriteStep.HANDSHAKE);
  }

  // ---------------------------------------------------------------- 发起

  static writeTone(entry: ToneEntry): Promise<WriteResult> {
    return WriteTask.start(TaskKind.TONE, entry.name, (): Promise<WriteResult> => {
      return CaseWriteService.write(entry, (ratio: number, stage: string, step: string): void => {
        WriteTask.onProgress(ratio, stage, step);
      });
    });
  }

  static restoreDefault(): Promise<WriteResult> {
    return WriteTask.start(TaskKind.RESTORE, '', (): Promise<WriteResult> => CaseWriteService.restoreDefault());
  }

  static selectBuiltIn(id: number, label: string): Promise<WriteResult> {
    return WriteTask.start(TaskKind.BUILTIN, label, (): Promise<WriteResult> => {
      return CaseWriteService.selectBuiltIn(id, label);
    });
  }

  /** 失败后重试：重放上一次的动作，前置检查仍在 CaseWriteService 里做 */
  static retry(): void {
    const run: (() => Promise<WriteResult>) | null = WriteTask.lastRun;
    if (run === null || WriteTask.isRunning()) {
      return;
    }
    WriteTask.execute(run).then((): void => {
    });
  }

  static cancel(): void {
    if (!WriteTask.isCancellable()) {
      return;
    }
    Logger.info(MODULE, `用户取消 phase=${WriteTask.snap.phase}`);
    WriteTask.snap.cancelling = true;
    WriteTask.snap.stage = I18n.t('wp.cancelling');
    WriteTask.publish();
    WriteEngine.cancelActive();
  }

  /** 收起弹窗；只有结局状态才能收起 */
  static dismiss(): void {
    if (WriteTask.isRunning()) {
      return;
    }
    WriteTask.cancelDismissTimer();
    WriteTask.snap = new TaskSnapshot();
    WriteTask.publish();
  }

  // ---------------------------------------------------------------- 内部

  private static start(kind: string, title: string, run: () => Promise<WriteResult>): Promise<WriteResult> {
    // 2026-11-26 23:15:27 真机：同一次确认在 126ms 内触发了两次 writeTone。第二次换掉了弹窗状态并以
    // 「正在写入」失败收尾，第一次却在后台照常写完——用户看到失败、实际成功。已有任务在跑时直接拒绝，不碰弹窗
    if (WriteTask.isRunning()) {
      Logger.warn(MODULE, `已有任务在进行，忽略新的 ${kind} 请求`);
      const busy: WriteResult = {
        ok: false, code: WriteCode.WRITE_FAILED, message: I18n.t('write.inProgress'),
        reason: WriteReason.BLOCKED, diagnostic: ''
      };
      return Promise.resolve(busy);
    }
    WriteTask.cancelDismissTimer();
    const fresh: TaskSnapshot = new TaskSnapshot();
    fresh.kind = kind;
    fresh.title = title;
    WriteTask.snap = fresh;
    WriteTask.lastRun = run;
    return WriteTask.execute(run);
  }

  private static async execute(run: () => Promise<WriteResult>): Promise<WriteResult> {
    const s: TaskSnapshot = WriteTask.snap;
    s.phase = WriteStep.CONNECT;
    s.progress = 0;
    s.stage = I18n.t('write.stageKeepCase');
    s.message = '';
    s.hint = '';
    s.code = 0;
    s.reason = '';
    s.diagnostic = '';
    s.cancelling = false;
    WriteTask.publish();
    let result: WriteResult;
    try {
      result = await run();
    } catch (error) {
      Logger.exception(MODULE, '写入任务异常', error as BusinessError);
      result = {
        ok: false, code: WriteCode.WRITE_FAILED, message: I18n.t('wp.unexpected'),
        reason: WriteReason.OTHER, diagnostic: ''
      };
    }
    WriteTask.finish(result);
    return result;
  }

  private static onProgress(ratio: number, stage: string, step: string): void {
    const s: TaskSnapshot = WriteTask.snap;
    if (TaskPhase.isTerminal(s.phase) || s.phase === TaskPhase.IDLE) {
      return;
    }
    s.progress = Math.round(ratio * 100);
    // 取消中保持「正在取消…」，不被后续进度覆盖
    if (!s.cancelling) {
      s.phase = step;
      s.stage = stage;
    }
    WriteTask.publish();
  }

  private static finish(result: WriteResult): void {
    const s: TaskSnapshot = WriteTask.snap;
    s.cancelling = false;
    s.code = result.code;
    s.reason = result.reason;
    s.diagnostic = result.diagnostic;
    s.message = result.message;
    if (result.ok) {
      s.phase = TaskPhase.DONE;
      s.progress = 100;
      if (s.kind === TaskKind.TONE) {
        SettingsService.recordWriteSuccess();
      }
    } else if (result.reason === WriteReason.CANCELLED) {
      s.phase = TaskPhase.CANCELLED;
      WriteTask.dismissTimer = setTimeout(() => {
        WriteTask.dismissTimer = -1;
        WriteTask.dismiss();
      }, CANCELLED_DISMISS_MS);
    } else {
      s.phase = TaskPhase.FAILED;
      const hintKey: string = WriteCode.hintKey(result.code);
      s.hint = hintKey.length > 0 ? I18n.t(hintKey) : '';
      // 前置检查拦下的不算一次失败写入（例如耳机没连上）
      if (s.kind === TaskKind.TONE && result.reason !== WriteReason.BLOCKED) {
        SettingsService.recordWriteFailure();
      }
    }
    Logger.info(MODULE, `任务结束 kind=${s.kind} phase=${s.phase} code=${s.code} reason=${s.reason}`);
    WriteTask.publish();
    // 盒内标记、设备页状态都要跟上：写入过程会断开再恢复音频
    EventBus.emit(AppEvent.TONE_CHANGED, 1);
    BluetoothService.refresh().then(() => {
    }).catch((error: BusinessError) => {
      Logger.warn(MODULE, `刷新蓝牙状态失败 code=${error.code}`);
    });
  }

  private static publish(): void {
    const stored: number | undefined = AppStorage.get<number>(WRITE_EPOCH);
    AppStorage.setOrCreate<number>(WRITE_EPOCH, (stored === undefined ? 0 : stored) + 1);
  }

  private static cancelDismissTimer(): void {
    if (WriteTask.dismissTimer >= 0) {
      clearTimeout(WriteTask.dismissTimer);
      WriteTask.dismissTimer = -1;
    }
  }
}
