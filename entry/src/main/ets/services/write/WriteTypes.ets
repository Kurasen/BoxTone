import { ToneStatus } from '../bluetooth/MbbProtocol';

/**
 * 写入引擎的公共类型。
 *
 * 这一层只放数据结构与接口，不依赖任何系统 Kit，
 * 方便 ToneUploader 这类纯逻辑模块在本地单测里直接跑。
 */

/** 进度回调：ratio 0~1，stage 为面向用户的阶段文案 */
export type StageProgress = (ratio: number, stage: string) => void;

/**
 * 写入步骤：写入弹窗据此显示标题和步骤条。
 * 由引擎按进度区间推出（与 ToneUploader 的进度划分一致），只有「等耳机收尾」由引擎显式标出。
 */
export class WriteStep {
  static readonly WAIT: string = 'wait';
  static readonly CONNECT: string = 'connect';
  static readonly HANDSHAKE: string = 'handshake';
  static readonly TRANSFER: string = 'transfer';
  static readonly FLASH: string = 'flash';
  static readonly APPLY: string = 'apply';

  static of(ratio: number): string {
    if (ratio < 0.04) {
      return WriteStep.CONNECT;
    }
    if (ratio < 0.08) {
      return WriteStep.HANDSHAKE;
    }
    if (ratio < 0.5) {
      return WriteStep.TRANSFER;
    }
    if (ratio < 0.97) {
      return WriteStep.FLASH;
    }
    return WriteStep.APPLY;
  }
}

/** 带步骤的进度回调：给写入弹窗用 */
export type StepProgress = (ratio: number, stage: string, step: string) => void;

/** 诊断日志出口：由调用方决定落到哪里（debug 包才记报文级细节） */
export type TraceSink = (line: string) => void;

/**
 * 上传端口。
 *
 * ToneUploader 只通过它和耳机打交道：真机由 MbbSession 实现，单测里用一台「假耳机」实现。
 * 所有方法都不应吞掉取消：用户取消时 next() 必须立刻以 CancelledError 结束。
 */
export interface UploadPort {
  /** 发一条控制命令（自动按 MBB 分帧），不等回执 */
  send(payload: Uint8Array): Promise<void>;
  /** 发一个分片组的数据帧：实现方尽量合并成一次底层写入 */
  sendWindow(payloads: Uint8Array[]): Promise<void>;
  /** 耳机声明了分包大小：实现方可据此放大单次底层写入 */
  chunkHint(chunkSize: number): void;
  /** 等下一条传输相关回包；超时抛 AckTimeoutError，链路断开抛 reason=LINK 的 ToneError */
  next(timeoutMs: number): Promise<Uint8Array>;
  /** 传数据前选中目标槽位；耳机不回执也不算失败，返回是否确认选中 */
  preselect(): Promise<boolean>;
  /**
   * 等待间隙的维护动作；不得抛错。
   * suppressAudio=true 时把被系统连回的音频通道压下去（传输与擦写进行中）；
   * 擦写已走满 100% 后传 false：那时耳机自己把音频连回来是它收尾完成的信号，压下去只会把它留在断开状态。
   */
  idle(suppressAudio: boolean): Promise<void>;
  /** 当前毫秒时间：单测里可以换成虚拟时钟 */
  now(): number;
}

/** 上传各段超时：真机取 WriteSpec 里的值，单测传短值 */
export class UploadTiming {
  /** 整包上传的总预算 */
  totalMs: number = 180000;
  /** 数据阶段两包之间的最长静默 */
  idleMs: number = 8000;
  /** 数据阶段单次等包的切片：切片之间做维护动作 */
  transferSliceMs: number = 400;
  /** 擦写阶段的最长静默 */
  flushMs: number = 30000;
  /** 擦写阶段单次等包的切片 */
  flushSliceMs: number = 600;
  /** 擦写走到 100% 后等最终确认（09 06）的时间 */
  confirmMs: number = 3000;
}

/** 一次上传的结果：成功时返回，失败一律抛 ToneError */
export class UploadReport {
  protocol: number = 0;
  packageBytes: number = 0;
  /** 是否在传数据前就选中了目标槽位 */
  preselected: boolean = false;
  /** 耳机是否已收完整包（之后只剩擦写） */
  receivedAll: boolean = false;
  /** 是否拿到了擦写完成的最终回执；false 表示靠静默收尾 */
  flushConfirmed: boolean = false;
  /** 数据阶段耗时（从声明到收完） */
  transferMs: number = 0;
  /** 整体耗时 */
  elapsedMs: number = 0;
  /** 数据帧发送次数（含补发） */
  framesSent: number = 0;
}

/**
 * 上传过程中的可观测状态。
 * 上传失败时引擎要据此决定能不能整包重来：数据还没收完可以，收完了就不行。
 */
export class UploadState {
  declared: boolean = false;
  preselected: boolean = false;
  receivedAll: boolean = false;
  framesSent: number = 0;
}

/** 写入成功的结果 */
export class WriteOutcome {
  status: ToneStatus;
  /** upload = 正常上传；apply-only = 数据已在耳机里，只补了选中命令 */
  via: string = 'upload';
  flushConfirmed: boolean = true;
  hwModel: string = '';
  protocol: number = 0;
  audioGate: string = 'idle';
  attempts: number = 1;
  /** 等耳机擦完上一条所花的时间：日志里和我们自己的耗时分开算 */
  settleWaitMs: number = 0;
  elapsedMs: number = 0;
  /** 写入期间应用是否进过后台（排查挂起导致的中断） */
  backgrounded: boolean = false;

  constructor(status: ToneStatus) {
    this.status = status;
  }
}

/** 只发命令、不写闪存的操作（恢复默认、切换内置音）的结果 */
export class CommandOutcome {
  status: ToneStatus;
  hwModel: string = '';
  protocol: number = 0;
  audioGate: string = 'idle';

  constructor(status: ToneStatus) {
    this.status = status;
  }
}
