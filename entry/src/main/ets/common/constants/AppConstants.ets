/**
 * 全局常量定义
 * 音频规格严格对齐华为充电盒的解码标准
 */

export class ToneSpec {
  /** 目标采样率：盒端标定 16700Hz（区分耳机提示音与手机通知音） */
  static readonly SAMPLE_RATE: number = 16700;
  /** 单声道 */
  static readonly CHANNELS: number = 1;
  /** 有符号 16bit PCM */
  static readonly BITS_PER_SAMPLE: number = 16;
  /** 每帧字节数 = 声道 * 位深 / 8 */
  static readonly BYTES_PER_FRAME: number = 2;
  /** 每秒字节数 = 16700 * 2 = 33400 */
  static readonly BYTES_PER_SECOND: number = 33400;
  /** 充电盒可接受的时长上限（秒）：实测 5 秒包能传完但盒端写闪存会停在半途，2 秒在安全范围内 */
  static readonly MAX_SECONDS: number = 2;
  /** 对应字节上限 66800 */
  static readonly MAX_BYTES: number = 66800;
  /** 时长下限（秒），过短会被盒端忽略 */
  static readonly MIN_SECONDS: number = 0.2;
  /** 可选采样率列表（导入 RAW 时使用） */
  static readonly COMMON_RATES: number[] = [8000, 16000, 22050, 32000, 44100, 48000];
}

/** 已实测通过写入的机型 */
export interface VerifiedDevice {
  /** 系统里显示的设备名 */
  name: string;
  /** 验证结论 / 备注 */
  detail: string;
}

export class DeviceSupport {
  /** 新增机型只需在这里加一行 */
  static readonly VERIFIED: VerifiedDevice[] = [
    { name: 'HUAWEI FreeClip 2', detail: '协议 2 · 开盒音效写入实测通过' }
  ];
}

export class SupportInfo {
  /** 反馈邮箱，分享正文与关于页都会用到 */
  static readonly EMAIL: string = 'kurasen@foxmail.com';
  /** 在线反馈开关：完成联网备案并部署后端后改为 true */
  static readonly FEEDBACK_ONLINE_ENABLED: boolean = false;
}

/**
 * 华为耳机 MBB 私有协议常量
 *
 * 帧结构：0x5A | length(2,大端) | control(1) [| sequence(1)] | payload | CRC16(2,大端)
 * CRC 为 CCITT-FALSE 变体（初值 0，多项式 0x1021），对整帧计算结果为 0。
 */
export class MbbSpec {
  /** 帧头 */
  static readonly FRAME_HEAD: number = 0x5A;
  /** 单帧承载上限，超过即按分片发送 */
  static readonly MAX_SINGLE_PAYLOAD: number = 1018;
  /** 分片载荷长度 */
  static readonly FRAME_CHUNK_SIZE: number = 1017;
  /** 最短合法帧：帧头(1)+长度(2)+控制字(1)+CRC(2) */
  static readonly MIN_FRAME_BYTES: number = 6;
  static readonly MAX_FRAME_BYTES: number = 65540;

  /** 自定义开盒音槽位号（不同固件可能变化） */
  static readonly TONE_CUSTOM_ID: number = 43;
  /** 音效包头魔数 15470 = 0x3C6E */
  static readonly TONE_PACKAGE_MAGIC: number = 15470;
  /** 音效名称字段长度 */
  static readonly TONE_NAME_MAX: number = 32;

  /** 串口写入分片（协议栈缓冲建议值） */
  static readonly SPP_WRITE_CHUNK: number = 480;
  /** 分包写入之间的空档：耳机接收缓冲有限，连发会丢包 */
  static readonly SPP_WRITE_GAP_MS: number = 10;
  /** 串口服务 UUID（标准 SPP） */
  static readonly SPP_UUID: string = '00001101-0000-1000-8000-00805F9B34FB';

  /** 单次建链超时 */
  static readonly CONNECT_TIMEOUT_MS: number = 8000;
  /** 建链总预算 */
  static readonly CONNECT_TOTAL_BUDGET_MS: number = 40000;
  /** 建链重试间隔 */
  static readonly CONNECT_RETRY_GAP_MS: number = 1100;
  /** 关掉串口后留给耳机收尾的时间 */
  static readonly SOCKET_SETTLE_MS: number = 1200;
  /** 连上后等耳机主动开口的时间 */
  static readonly LINK_READY_TIMEOUT_MS: number = 1500;
  /** 耳机收掉通道后的冷却时间 */
  static readonly LINK_COOLDOWN_MS: number = 15000;

  /** 普通命令回执超时 */
  static readonly ACK_TIMEOUT_MS: number = 3000;
  static readonly QUERY_TIMEOUT_MS: number = 1200;
  static readonly QUERY_ATTEMPTS: number = 4;

  /** 整包上传预算与空闲超时（耳机擦闪存时会静默数秒，别太急） */
  static readonly UPLOAD_TOTAL_TIMEOUT_MS: number = 180000;
  static readonly UPLOAD_IDLE_TIMEOUT_MS: number = 18000;
  /**
   * 数据全部送达后的擦写等待。
   * 28KB 的包约 1.5 秒写完；167KB 要先擦多个 flash 块，期间耳机一个进度包都不发，
   * 按 18 秒的空闲超时会被误判成失败。
   */
  static readonly UPLOAD_FLUSH_TIMEOUT_MS: number = 60000;
}

export class AppStorageKey {
  static readonly PREFS_NAME: string = 'boxtone_settings';
  static readonly KEY_DEFAULT_DURATION: string = 'default_duration_ms';
  static readonly KEY_DEFAULT_GAIN: string = 'default_gain_db';
  static readonly KEY_LOG_LEVEL: string = 'log_level';
  static readonly KEY_AUTO_NORMALIZE: string = 'auto_normalize';
  static readonly KEY_FEEDBACK_RECORDS: string = 'feedback_records';
  static readonly KEY_DEMO_MODE: string = 'demo_mode';
  static readonly KEY_DEMO_GUIDE_SEEN: string = 'demo_guide_seen';
}

export class AppPath {
  static readonly TONE_DIR: string = 'tones';
  static readonly EXPORT_DIR: string = 'exports';
  static readonly TONE_INDEX: string = 'index.json';
}

export class LogTag {
  static readonly DOMAIN: number = 0x0A01;
  static readonly TAG: string = 'BoxTone';
}

export class RouteName {
  static readonly LOG_PAGE: string = 'LogPage';
}

/** 底部导航页签顺序 */
export enum TabIndex {
  DEVICE = 0,
  TONE = 1,
  LIBRARY = 2,
  PROFILE = 3
}

/** 日志级别 */
export enum LogLevel {
  DEBUG = 'D',
  INFO = 'I',
  WARN = 'W',
  ERROR = 'E'
}
