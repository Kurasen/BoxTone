import { I18n } from '../../common/i18n/I18n';

export type ToneProgress = (ratio: number, stage: string) => void;
export type ToneLog = (line: string) => void;

/** 协议层异常：code 为耳机或系统错误码，message 直接面向用户 */
export class ToneError extends Error {
  code: number;
  /** 用于在 catch 里识别协议层异常，避免依赖 instanceof */
  kind: string;
  /** 失败归类（见 ToneErrorReason），空串表示未归类；上层据此给出不同结局 */
  reason: string = '';
  /** 结构化诊断片段（能力原始数据、耳机回包的协议结果等），用于一键复制反馈 */
  diagnostic: string = '';

  constructor(message: string, code: number = 0) {
    super(message);
    this.name = 'ToneError';
    this.kind = 'tone';
    this.code = code;
  }
}

/** 耳机/固件不支持盒音自定义：是终端结局，区别于值得重试的链路问题 */
export const TONE_CODE_UNSUPPORTED: number = -96;

export class ToneErrorReason {
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly FORMAT: string = 'format';
  static readonly LINK: string = 'link';
  /** 音频通道断不开且串口被拒：重传也不会好，先让用户断开音频再试 */
  static readonly AUDIO_HELD: string = 'audioHeld';
  static readonly ACK_TIMEOUT: string = 'ackTimeout';
  static readonly FLUSH_TIMEOUT: string = 'flushTimeout';
  static readonly DATA_WRITTEN: string = 'dataWritten';
  static readonly CANCELLED: string = 'cancelled';
  /** 本进程的蓝牙串口卡死：重试、合盖都没用，只有重启应用进程能恢复 */
  static readonly WEDGED: string = 'wedged';
}

export class CancelledError extends ToneError {
  constructor() {
    super(I18n.t('toneErr.cancelled'), -99);
    this.name = 'CancelledError';
    this.reason = ToneErrorReason.CANCELLED;
  }
}

/** 回执超时：命令可能刚发出去就被耳机忽略，值得原样重发一次 */export class AckTimeoutError extends ToneError {
  constructor() {
    super(I18n.t('toneErr.ackTimeout'), -98);
    this.name = 'AckTimeoutError';
    this.reason = ToneErrorReason.ACK_TIMEOUT;
  }
}

export function isToneError(error: Object | null | undefined): boolean {
  if (error === null || error === undefined) {
    return false;
  }
  return (error as ToneError).kind === 'tone';
}
