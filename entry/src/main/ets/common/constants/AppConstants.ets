import { I18n } from '../i18n/I18n';

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

/** 兼容性等级：型号匹配只用于提示，真正的写入门槛仍是协议能力探测 */
export enum DeviceSupportLevel {
  /** 盒音写入实测通过 */
  VERIFIED = 1,
  /** 具备开盒提示音机型，但本应用的盒音自定义尚未实测 */
  OFFICIAL = 2,
  /** 未收录 */
  UNKNOWN = 3
}

/** 支持列表条目 */
export interface SupportedDevice {
  /** 兼容性等级：实测通过 = 1，支持开盒提示音待实测 = 2 */
  level: DeviceSupportLevel;
  /** 系统里可能出现的产品名（含典藏版等变体） */
  names: string[];
  /** 耳机自报型号（0107 tag 15），允许同平台后缀变体 */
  modelCodes: string[];
  /** 验证结论 / 备注（文案 key） */
  detailKey: string;
}

/** 机型匹配结果 */
export interface DeviceVerdict {
  level: DeviceSupportLevel;
  /** 命中的产品名，未命中为空串 */
  name: string;
  detail: string;
}

export class DeviceSupport {
  /**
   * 唯一支持列表：实测后只需把 level 从 OFFICIAL 改成 VERIFIED，
   * 页面分组和写入提示会自动跟着变，不用搬数组。
   */
  static readonly SUPPORTED: SupportedDevice[] = [
    {
      level: DeviceSupportLevel.VERIFIED,
      names: ['HUAWEI FreeClip 2', 'HUAWEI FreeClip 2 耳夹耳机', 'HUAWEI FreeClip 2 典藏版',
        'HUAWEI FreeClip 2 典藏版 耳夹耳机', '华为 FreeClip 2', '华为 FreeClip 2 典藏版'],
      modelCodes: ['BTFT0027'],
      detailKey: 'support.detail.freeclip2'
    },
    // 以下为华为官方支持充电盒开盒提示音的机型：
    // https://consumer.huawei.com/cn/support/content/zh-cn16053049/
    {
      level: DeviceSupportLevel.OFFICIAL,
      names: ['HUAWEI FreeBuds 6', 'HUAWEI FreeBuds 6 悦彰耳机', '华为 FreeBuds 6'],
      modelCodes: ['BTFT0020'],
      detailKey: 'support.detail.official'
    },
    {
      level: DeviceSupportLevel.OFFICIAL,
      names: ['HUAWEI FreeBuds Pro 5', 'HUAWEI FreeBuds Pro 5 悦彰耳机',
        'HUAWEI FreeBuds Pro 5 马年典藏款', '华为 FreeBuds Pro 5'],
      modelCodes: ['BTFT0023'],
      detailKey: 'support.detail.officialHorse'
    },
    {
      level: DeviceSupportLevel.OFFICIAL,
      names: ['HUAWEI FreeBuds 7', 'HUAWEI FreeBuds 7 悦彰耳机', '华为 FreeBuds 7'],
      modelCodes: ['BTFT0028'],
      detailKey: 'support.detail.official'
    }
  ];

  /** 按等级筛出页面分组，顺序沿用 SUPPORTED 的先后 */
  static devicesOf(level: DeviceSupportLevel): SupportedDevice[] {
    const result: SupportedDevice[] = [];
    for (let i = 0; i < DeviceSupport.SUPPORTED.length; i++) {
      if (DeviceSupport.SUPPORTED[i].level === level) {
        result.push(DeviceSupport.SUPPORTED[i]);
      }
    }
    return result;
  }

  static countOf(level: DeviceSupportLevel): number {
    let count: number = 0;
    for (let i = 0; i < DeviceSupport.SUPPORTED.length; i++) {
      if (DeviceSupport.SUPPORTED[i].level === level) {
        count++;
      }
    }
    return count;
  }

  /**
   * 优先级：耳机自报型号 > 蓝牙名；同一层级里 VERIFIED 优先。
   * 型号来自固件，用户改名不影响；名称只在型号缺失或未收录时兜底。
   */
  static judge(modelCode: string, names: string[]): DeviceVerdict {
    const matched: SupportedDevice | null =
      DeviceSupport.findMatch(DeviceSupport.SUPPORTED, modelCode, names);
    if (matched !== null) {
      return { level: matched.level, name: matched.names[0], detail: I18n.t(matched.detailKey) };
    }
    return { level: DeviceSupportLevel.UNKNOWN, name: '', detail: '' };
  }

  private static findMatch(list: SupportedDevice[], modelCode: string,
    names: string[]): SupportedDevice | null {
    const targetModel: string = DeviceSupport.normalizeModel(modelCode);
    let best: SupportedDevice | null = null;
    if (targetModel.length > 0) {
      for (let i = 0; i < list.length; i++) {
        for (let k = 0; k < list[i].modelCodes.length; k++) {
          if (DeviceSupport.sameModel(list[i].modelCodes[k], targetModel)) {
            best = DeviceSupport.better(best, list[i]);
            break;
          }
        }
      }
      if (best !== null) {
        return best;
      }
    }
    for (let i = 0; i < list.length; i++) {
      for (let k = 0; k < names.length; k++) {
        if (DeviceSupport.sameName(list[i], names[k])) {
          best = DeviceSupport.better(best, list[i]);
          break;
        }
      }
    }
    return best;
  }

  /** 同一型号出现多条时，数值更小的等级优先（VERIFIED=1 > OFFICIAL=2） */
  private static better(current: SupportedDevice | null,
    candidate: SupportedDevice): SupportedDevice {
    if (current === null || candidate.level < current.level) {
      return candidate;
    }
    return current;
  }

  /** 型号统一成大写、去空格；允许 BTFT0027-000167 这类同平台后缀 */
  private static sameModel(code: string, targetModel: string): boolean {
    const base: string = DeviceSupport.normalizeModel(code);
    if (base.length === 0) {
      return false;
    }
    if (base === targetModel) {
      return true;
    }
    return targetModel.startsWith(`${base}-`) || targetModel.startsWith(`${base}_`);
  }

  private static sameName(device: SupportedDevice, name: string): boolean {
    const target: string = DeviceSupport.normalizeName(name);
    if (target.length === 0) {
      return false;
    }
    for (let i = 0; i < device.names.length; i++) {
      if (DeviceSupport.normalizeName(device.names[i]) === target) {
        return true;
      }
    }
    return false;
  }

  private static normalizeModel(model: string): string {
    return model.trim().toUpperCase().replace(/\s+/g, '');
  }

  /** 系统蓝牙名常见写法：HUAWEI FreeClip 2 / 华为 FreeClip 2 / Huawei FreeClip2 */
  private static normalizeName(name: string): string {
    let text: string = name.trim().toLowerCase();
    text = text.replace(/\s+/g, '');
    text = text.replace('华为', 'huawei');
    return text;
  }
}

export class SupportInfo {
  /** 反馈邮箱，分享正文与关于页都会用到 */
  static readonly EMAIL: string = 'kurasen@foxmail.com';
  /** 在线反馈开关：完成联网备案并部署后端后改为 true */
  static readonly FEEDBACK_ONLINE_ENABLED: boolean = false;
  /** 应用市场详情页链接：上架后填入，例如 https://appgallery.huawei.com/app/detail?id=<bundleName> */
  static readonly APP_GALLERY_URL: string = '';
  /** 捐赠页图片（资源名或路径）：暂时留空，点击无响应 */
  static readonly DONATION_IMAGE: string = '';
}

/** 更新日志条目 */
export interface ChangelogEntry {
  version: string;
  noteKey: string;
  itemKeys: string[];
}

export class Changelog {
  static readonly ENTRIES: ChangelogEntry[] = [
    {
      version: 'v1.1.1',
      noteKey: 'changelog.v111.note',
      itemKeys: [
        'changelog.v111.i10',
        'changelog.v111.i11',
        'changelog.v111.i1',
        'changelog.v111.i2',
        'changelog.v111.i3',
        'changelog.v111.i4',
        'changelog.v111.i5',
        'changelog.v111.i6',
        'changelog.v111.i8',
        'changelog.v111.i9'
      ]
    },
    {
      version: 'v1.1.0',
      noteKey: 'changelog.v110.note',
      itemKeys: [
        'changelog.v110.i1',
        'changelog.v110.i2',
        'changelog.v110.i3',
        'changelog.v110.i4',
        'changelog.v110.i5',
        'changelog.v110.i6',
        'changelog.v110.i7'
      ]
    },
    {
      version: 'v1.0.0',
      noteKey: 'changelog.v100.note',
      itemKeys: [
        'changelog.v100.i1',
        'changelog.v100.i2',
        'changelog.v100.i3',
        'changelog.v100.i4'
      ]
    }
  ];
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
  /**
   * 音频通道还连着时的试探超时。
   * 这类局面下耳机有可能直接不回应，用完整 8 秒去等一次注定被拒的连接太贵。
   */
  static readonly CONNECT_PROBE_TIMEOUT_MS: number = 4500;
  /**
   * 刚断开音频后的第一枪超时。
   * ACL 拆链还没收敛时，sppConnect 有时既不回调成功也不回调失败，
   * 真机日志里出现整整卡满 8 秒的情况（同一份代码另一轮又只用了 0.3 秒）。
   * 这里封顶 3 秒，失败后立刻重试，比干等更有用。
   */
  static readonly CONNECT_POST_RELEASE_MS: number = 3000;
  /** 建链总预算 */
  static readonly CONNECT_TOTAL_BUDGET_MS: number = 40000;
  /** 建链重试间隔（换通道模式时） */
  static readonly CONNECT_RETRY_GAP_MS: number = 500;
  /**
   * 同一种通道模式下两次尝试的间隔。
   * 真机日志显示耳机要「被请求到第 6 次」才肯开串口（两轮写入都是第 6 次成功），
   * 原来的 1300ms 让这 6 次白等到 14 秒；缩短到 700ms 能在 5~7 秒内走完同样的次数。
   */
  static readonly CONNECT_ATTEMPT_GAP_MS: number = 700;
  /** 关掉串口后留给耳机收尾的时间 */
  static readonly SOCKET_SETTLE_MS: number = 1200;
  /** 连上后等耳机主动开口的时间 */
  static readonly LINK_READY_TIMEOUT_MS: number = 1500;
  /** 耳机收掉通道后的冷却时间 */
  static readonly LINK_COOLDOWN_MS: number = 15000;
  /**
   * 写完音效后的沉降期：这段时间耳机在擦闪存，不能开始新的传输。
   * 注意它只限制「什么时候能再传」，不限制「通道要不要留」——
   * 旧实现把两件事绑在一起（关通道 + 全局冷却），代价是每次都要重新建链。
   */
  static readonly SESSION_SETTLE_MS: number = 15000;
  /**
   * 热会话保留时长。
   * 一次操作结束后串口不立刻关，留着给下一次复用：真机一次 sppConnect 约 3 秒
   * （要在音频通道上做 SDP 与握手），而空闲保活只是一条查询包。
   * 连续切内置音、连续试写入时，省下的就是这一步。
   */
  static readonly SESSION_TTL_MS: number = 90000;
  /**
   * 断开音频通道后等它真的掉下来的上限。
   * 不再固定 sleep：真机上 A2DP 掉链约 300~800ms，轮询能在掉下去的那一刻就往下走。
   */
  static readonly AUDIO_DROP_WAIT_MS: number = 2600;
  /** A2DP 掉链到能建串口之间的余量（ACL 拆链还没彻底收敛时会拿到 -1） */
  static readonly AUDIO_SETTLE_MS: number = 500;

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
  static readonly KEY_THEME_MODE: string = 'theme_mode';
  /** AppStorage 主题纪元：切换外观时自增，触发组件重绘 */
  static readonly THEME_EPOCH: string = 'themeEpoch';
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
