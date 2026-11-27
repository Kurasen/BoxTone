import { I18n } from '../i18n/I18n';

/**
 * 全局常量定义
 * 音频规格严格对齐华为充电盒的解码标准
 */

export class ToneSpec {
  /** 目标采样率：盒端标定 16700Hz（区分耳机提示音与手机通知音） */
  static readonly SAMPLE_RATE: number = 16700;
  /** 每帧字节数 = 声道 × 16bit / 8 */
  static readonly BYTES_PER_FRAME: number = 2;
  /** 每秒字节数 = 16700 * 2 = 33400 */
  static readonly BYTES_PER_SECOND: number = 33400;
  /**
   * 可写音效的字节上限 = 2.8s × 33400 = 93520。
   *
   * 2026-11 真机实测结论：
   * - 2.5s（83KB）稳定；3.2s（106KB）压线；
   * - 4.5s / 5.7s 数据能完整送达，但耳机擦写第二阶段会卡死（>106KB 不稳）；
   * - 系统 SPP 分段 480B / 20ms ≈ 23KB/s，应用层没有接口可改。
   * 2.8 秒（92KB）落在「稳定」与「压线」之间，放开后的实际表现需继续观察。
   * 详见 docs/write-duration-gap.md。
   */
  static readonly MAX_BYTES: number = 93520;
  /** 对应时长 93520 / 33400 = 2.8 秒 */
  static readonly MAX_SECONDS: number = 2.8;
  /** 导入/备份恢复允许的上限：兼容旧版本生成的长音效，真正写入仍受 MAX_BYTES 约束 */
  static readonly MAX_IMPORT_BYTES: number = 192000;
  /** 时长下限（秒），过短会被盒端忽略 */
  static readonly MIN_SECONDS: number = 0.2;
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
      level: DeviceSupportLevel.VERIFIED,
      names: ['HUAWEI FreeBuds Pro 5', 'HUAWEI FreeBuds Pro 5 悦彰耳机',
        'HUAWEI FreeBuds Pro 5 马年典藏款', '华为 FreeBuds Pro 5'],
      modelCodes: ['BTFT0023'],
      detailKey: 'support.detail.verifiedHorse'
    },
    {
      level: DeviceSupportLevel.VERIFIED,
      names: ['HUAWEI FreeBuds 7', 'HUAWEI FreeBuds 7 悦彰耳机', '华为 FreeBuds 7'],
      modelCodes: ['BTFT0028'],
      detailKey: 'support.detail.verified'
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
  /** 应用市场详情页链接：用于「五星好评」入口 */
  static readonly APP_GALLERY_URL: string =
    'https://appgallery.huawei.com/app/detail?id=com.boxtone.audiokit&channelId=SHARE&source=appshare';
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
      version: 'v1.3.0',
      noteKey: 'changelog.v130.note',
      itemKeys: [
        'changelog.v130.i4',
        'changelog.v130.i1',
        'changelog.v130.i2',
        'changelog.v130.i3',
        'changelog.v130.i5',
        'changelog.v130.i6',
        'changelog.v130.i7'
      ]
    },
    {
      version: 'v1.2.0',
      noteKey: 'changelog.v120.note',
      itemKeys: [
        'changelog.v120.i2',
        'changelog.v120.i3',
        'changelog.v120.i4',
        'changelog.v120.i6',
        'changelog.v120.i7'
      ]
    },
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

  /**
   * 自定义开盒音槽位号。
   *
   * 官方音效表里 43 是出厂「口哨」（固定大小的预置槽），100~179 才是留给自建音效的区间。
   * 参考实现（OpenFreebuds）写的是 **100**：
   * 抓它的运行日志，上传前那条 `2BB4` 写入的 12 字节里 `[9:11] = 0x0064`。
   * 之前我们写 43，等于一直在覆盖一个预置音效，而且它的容量明显小于自定义区
   * （实测 3.2 秒能写满、3.5 秒就卡在擦写阶段）。
   */
  static readonly TONE_CUSTOM_ID: number = 100;
  /** 音效包头魔数 15470 = 0x3C6E */
  static readonly TONE_PACKAGE_MAGIC: number = 15470;
  /** 音效名称字段长度 */
  static readonly TONE_NAME_MAX: number = 32;

  /** 串口写入分片（协议栈缓冲建议值） */
  static readonly SPP_WRITE_CHUNK: number = 480;
  /** 分包写入之间的空档：耳机接收缓冲有限，连发会丢包（仅在整窗合并写失败时才会用到） */
  static readonly SPP_WRITE_GAP_MS: number = 4;
  /**
   * 一个分片组（8 帧）合并成一次写入的上限。
   *
   * 参考实现（Windows/OpenFreebuds）用的是阻塞 socket，8 次 send 只是把数据塞进内核缓冲，
   * 真正发送由驱动连续排完；鸿蒙每次 sppWriteAsync 都是一次跨线程往返（实测 ~7ms），
   * 再叠加每帧空档，一个窗口本地就要 130ms 以上，比耳机自己的处理时间还长。
   */
  static readonly BULK_WRITE_BYTES: number = 8192;
  /** 串口服务 UUID（标准 SPP） */
  static readonly SPP_UUID: string = '00001101-0000-1000-8000-00805F9B34FB';

  /**
   * 单次建链超时。
   *
   * 实测健康的耳机 0.3~3 秒内必然回包（连上或回 -1），8 秒只在
   * 「耳机完全不回应」时才会走满——那种局面下等 8 秒除了拖慢体验没有别的收益，
   * 因为下一轮重试反正也要等。压到 4 秒让「无响应」的失败来得更早、重试更密集。
   */
  static readonly CONNECT_TIMEOUT_MS: number = 4000;
  /**
   * 音频通道还连着时的试探超时。
   * 这类局面下耳机有可能直接不回应，用完整超时去等一次注定被拒的连接太贵。
   */
  static readonly CONNECT_PROBE_TIMEOUT_MS: number = 3000;
  /**
   * 刚断开音频后的第一枪超时。
   * ACL 拆链还没收敛时，sppConnect 有时既不回调成功也不回调失败，
   * 真机日志里出现整整卡满 8 秒的情况（同一份代码另一轮又只用了 0.3 秒）。
   * 这里封顶 3 秒，失败后立刻重试，比干等更有用。
   */
  static readonly CONNECT_POST_RELEASE_MS: number = 3000;
  /**
   * 建链总预算。
   *
   * 旧值 40 秒几乎等于「死等」：耳机连续几轮不回包时用户只能干看转圈。
   * 缩到 15 秒——覆盖健康耳机（2~3 秒）和「耳机忙但最终回应」（实测 ~13 秒），
   * 真无响应则尽快失败并给出「合盖再开盖」的明确指引，而不是耗满 40 秒。
   */
  static readonly CONNECT_TOTAL_BUDGET_MS: number = 15000;
  /** 建链重试间隔（换通道模式时） */
  static readonly CONNECT_RETRY_GAP_MS: number = 500;
  /** 关掉串口后留给耳机收尾的时间 */
  static readonly SOCKET_SETTLE_MS: number = 1200;
  /**
   * 连上后等耳机主动开口的时间。
   *
   * 真机上耳机一旦可用，连接后 23~31ms 就会推状态包；而「连上但一声不吭」的连接
   * 是 ACL 还没收敛时的半死通道（14:53 那轮等了 1502ms 才判定，白耗 1.5 秒）。
   * 600ms 对正常通道仍有近 20 倍余量，判死后换一种通道重连只要 0.3 秒。
   */
  static readonly LINK_READY_TIMEOUT_MS: number = 600;
  /** 耳机收掉通道后的冷却时间 */
  static readonly LINK_COOLDOWN_MS: number = 15000;
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
  /**
   * A2DP 掉链到能建串口之间的余量。
   *
   * 「A2DP profile 已断开」不等于「ACL 已拆完」：真机上把这一枪发在断开后 500ms，
   * 要么被回 2900099（协议栈直接拒，51ms）、要么拿到一个连得上却不吭声的半死 socket
   * （14:53 那轮 1406ms 连上、之后 1.5 秒零回包）。
   * 把多轮日志按「断开音频 → 连接成功」对齐，**每一次成功都发生在 1000ms 之后**
   * （1051ms / 1690ms / 2177ms…），没有一次是 500ms 那一枪打中的。
   * 所以这里等到 1 秒再发第一枪：宁可多等 0.5 秒，也别白打一枪（0.05~1.4 秒）再补一次。
   */
  static readonly AUDIO_SETTLE_MS: number = 1000;

  /** 普通命令回执超时 */
  static readonly ACK_TIMEOUT_MS: number = 3000;
  static readonly QUERY_TIMEOUT_MS: number = 1200;
  static readonly QUERY_ATTEMPTS: number = 4;

  /** 整包上传预算与空闲超时 */
  static readonly UPLOAD_TOTAL_TIMEOUT_MS: number = 180000;
  /**
   * 数据阶段（耳机还没收完整包）的空闲超时。
   *
   * 健康传输里每个 8 帧分片组 300~500ms 就回一次包，18 秒意味着要连续丢
   * 三四十个回执才判失败——真机里「音频被系统连回来打断传输」时，正是
   * 这个 18 秒让用户干等（20:22 那轮 31.2s 卡到 49.2s）。压到 8 秒，
   * 既不误伤正常传输（仍有 16 倍余量），又能让「链路被掐」快速收场去重试。
   */
  static readonly UPLOAD_IDLE_TIMEOUT_MS: number = 8000;
  /**
   * 数据全部送达后的擦写静默预算。
   *
   * 擦写进度每 ~82ms 一包；停在 62%~99% 不动、随后系统把 A2DP 连回来，
   * 是耳机在收尾阶段重启/放弃本轮写入的表现。静默预算给到 30 秒，
   * 期间发现音频回连就主动压下去让擦写继续；真断链由串口判死后立即上抛。
   */
  static readonly UPLOAD_FLUSH_TIMEOUT_MS: number = 30000;
  /**
   * 擦写进度到 100% 后，再等耳机最终确认（09 06）的时间。
   *
   * Windows 版 100% 后约 3 秒会再补一条 09 06；FreeClip 2 实测从不补，
   * 每次都等到静默超时（20:33 两轮都是 confirm=silent）。留 3 秒对齐 Windows，
   * 既给会补 09 06 的机型留出确认窗口，又不让 FreeClip 2 白等 5 秒。
   */
  static readonly UPLOAD_FLUSH_CONFIRM_MS: number = 3000;
}

export class AppStorageKey {
  static readonly PREFS_NAME: string = 'boxtone_settings';
  static readonly KEY_DEFAULT_DURATION: string = 'default_duration_ms';
  static readonly KEY_DEFAULT_GAIN: string = 'default_gain_db';
  static readonly KEY_AUTO_NORMALIZE: string = 'auto_normalize';
  static readonly KEY_FEEDBACK_RECORDS: string = 'feedback_records';
  /** 最近一次成功写入盒内的音效 id：音效库的「盒内」标记 */
  static readonly KEY_LAST_WRITTEN_TONE: string = 'last_written_tone';
  static readonly KEY_THEME_MODE: string = 'theme_mode';
  /** 累计成功写入次数：应用评分的前置条件之一 */
  static readonly KEY_WRITE_SUCCESS_COUNT: string = 'write_success_count';
  /** 首次成功写入的时间戳：用来判断「用了一段时间」而不是刚装上就来要评分 */
  static readonly KEY_FIRST_USE_AT: string = 'first_use_at';
  /** 最近一次写入失败的时间戳：刚失败过的用户不打扰 */
  static readonly KEY_LAST_WRITE_FAIL_AT: string = 'last_write_fail_at';
  /** 上次请求应用评分的时间戳：90 天内不重复请求 */
  static readonly KEY_RATING_ASKED_AT: string = 'rating_asked_at';
  /** 调试：写后间隔覆盖（毫秒），0 = 默认。只在 debug 包读取 */
  static readonly KEY_DEBUG_FLASH_GAP: string = 'debug_flash_gap_ms';
  /** AppStorage 主题纪元：切换外观时自增，触发组件重绘 */
  static readonly THEME_EPOCH: string = 'themeEpoch';
}

export class AppPath {
  static readonly TONE_DIR: string = 'tones';
  static readonly TONE_INDEX: string = 'index.json';
}

export class LogTag {
  static readonly DOMAIN: number = 0x0A01;
  static readonly TAG: string = 'BoxTone';
}

/** 日志级别 */
export enum LogLevel {
  DEBUG = 'D',
  INFO = 'I',
  WARN = 'W',
  ERROR = 'E'
}
