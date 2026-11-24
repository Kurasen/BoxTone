import { cancelDecode, getDecodeProgress, DecodeProgress } from 'libaudiodec.so';
import { Logger } from '../../common/utils/Logger';

const MODULE: string = 'ImportControl';

/** 用户主动取消导入时抛出；UI 捕获后静默处理，不弹失败提示 */
export class ImportCancelledError extends Error {
  constructor(message: string = 'import cancelled') {
    super(message);
    this.name = 'ImportCancelledError';
  }
}

export interface ImportProgressState {
  /** 原生解码是否真的在跑；探测和 WAV 工作线程阶段为 false */
  active: boolean;
  /** 0~1 */
  progress: number;
  elapsedMs: number;
}

/**
 * 导入任务控制器
 *
 * 管理取消标志与原生解码进度。取消标志由 UI 置位，
 * 解码循环在每个迭代检查，通常几十毫秒内退出；
 * WAV 的 TaskPool 任务无法中断，但返回后会被丢弃。
 */
export class ImportControl {
  private static cancelled: boolean = false;
  /** 进度接口失效只报一次，避免 250ms 定时器把日志刷满 */
  private static progressBroken: boolean = false;

  public static begin(): void {
    ImportControl.cancelled = false;
  }

  /** 取消当前导入：立刻置位旗帜，原生解码会尽快退出 */
  public static cancel(): void {
    ImportControl.cancelled = true;
    try {
      cancelDecode();
    } catch (error) {
      // 原生模块不可用时仅靠标志位，任务结束后同样会被丢弃
    }
  }

  public static isCancelled(): boolean {
    return ImportControl.cancelled;
  }

  public static throwIfCancelled(): void {
    if (ImportControl.cancelled) {
      throw new ImportCancelledError();
    }
  }

  /** 读取原生解码进度；取不到时按“不确定进度”处理 */
  public static progress(): ImportProgressState {
    let state: ImportProgressState = { active: false, progress: 0, elapsedMs: 0 };
    try {
      const raw: DecodeProgress = getDecodeProgress();
      state = {
        active: raw.active,
        progress: raw.progress,
        elapsedMs: raw.elapsedMs
      };
    } catch (error) {
      // 保持默认值；只报一次，方便定位「release 包没有进度条」这类问题
      if (!ImportControl.progressBroken) {
        ImportControl.progressBroken = true;
        const reason: string = error instanceof Error ? error.message : `${error}`;
        Logger.warn(MODULE, `读取解码进度失败，导入遮罩退回不确定进度：${reason}`);
      }
    }
    return state;
  }

  /** 一次导入结束时清理取消标记 */
  public static finish(): void {
    ImportControl.cancelled = false;
  }
}