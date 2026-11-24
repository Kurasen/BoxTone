import { common } from '@kit.AbilityKit';
import { MbbSpec, ToneSpec } from '../common/constants/AppConstants';
import { ByteUtils } from '../common/utils/ByteUtils';
import { Logger } from '../common/utils/Logger';
import { Sha256Utils } from '../common/utils/Sha256Utils';
import { BuiltinTone, BuiltinToneCatalog } from './BuiltinToneCatalog';
import { SettingsService } from './SettingsService';
import type { AppSettings } from './SettingsService';
import { MbbProtocol, PacketAssembler, ToneStatus } from './bluetooth/MbbProtocol';

const MODULE: string = 'SelfCheck';

/** 单条自检结果 */
export interface CheckItem {
  name: string;
  passed: boolean;
  detail: string;
}

/** 一次自检的汇总 */
export interface CheckReport {
  total: number;
  passed: number;
  failed: number;
  elapsedMs: number;
  items: CheckItem[];
}

/** 一条用例：抛出异常即视为失败，异常 message 作为失败原因 */
type CheckRunner = () => void;

class CheckCase {
  name: string;
  runner: CheckRunner;

  constructor(name: string, runner: CheckRunner) {
    this.name = name;
    this.runner = runner;
  }
}

/**
 * 回归自检：覆盖不依赖硬件的那部分核心逻辑。
 *
 * 为什么要有它：蓝牙写入、音频播放这些链路只能上真机手测，但协议编解码、
 * 摘要、TLV、音效包结构、波形合成、设置读取都是纯计算，改 A 功能时很容易
 * 顺手碰坏 B 功能的这些基础件，而肉眼又看不出来。
 *
 * 只在 debug 构建启动时自动执行，release 包不会跑，也不影响任何业务状态。
 * 结果写入日志中心，`./tools/dev.sh log` 或应用内「日志」页可直接看到。
 */
export class SelfCheckService {
  /** debug 构建启动时调用；release 或读不到标记时直接跳过 */
  public static runIfDebug(context: common.UIAbilityContext): void {
    let debug: boolean = false;
    try {
      debug = context.applicationInfo.debug;
    } catch (error) {
      Logger.warn(MODULE, '读取 debug 标记失败，跳过自检');
      return;
    }
    if (!debug) {
      return;
    }
    SelfCheckService.runAll();
  }

  /** 执行全部用例，逐条记录结果 */
  public static runAll(): CheckReport {
    const start: number = Date.now();
    const cases: CheckCase[] = SelfCheckService.cases();
    const items: CheckItem[] = [];
    let passed: number = 0;

    for (let i = 0; i < cases.length; i++) {
      const item: CheckItem = SelfCheckService.runCase(cases[i]);
      if (item.passed) {
        passed++;
        Logger.debug(MODULE, `✓ ${item.name} ${item.detail}`);
      } else {
        Logger.error(MODULE, `✗ ${item.name}：${item.detail}`);
      }
      items.push(item);
    }

    const report: CheckReport = {
      total: cases.length,
      passed: passed,
      failed: cases.length - passed,
      elapsedMs: Date.now() - start,
      items: items
    };
    if (report.failed === 0) {
      Logger.info(MODULE, `自检通过 ${report.passed}/${report.total}，耗时 ${report.elapsedMs}ms`);
    } else {
      Logger.warn(MODULE,
        `自检失败 ${report.failed}/${report.total}，耗时 ${report.elapsedMs}ms，详情见上方 ✗ 条目`);
    }
    return report;
  }

  private static runCase(item: CheckCase): CheckItem {
    try {
      item.runner();
      return { name: item.name, passed: true, detail: 'ok' };
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : `${error}`;
      return { name: item.name, passed: false, detail: detail };
    }
  }

  private static cases(): CheckCase[] {
    return [
      new CheckCase('字节工具', SelfCheckService.checkByteUtils),
      new CheckCase('规格常量', SelfCheckService.checkToneSpec),
      new CheckCase('SHA-256', SelfCheckService.checkSha256),
      new CheckCase('MBB 单帧', SelfCheckService.checkFraming),
      new CheckCase('MBB 分片重组', SelfCheckService.checkFragments),
      new CheckCase('TLV 编解码', SelfCheckService.checkTlv),
      new CheckCase('音效包结构', SelfCheckService.checkTonePackage),
      new CheckCase('状态解析', SelfCheckService.checkParseStatus),
      new CheckCase('内置音效目录', SelfCheckService.checkBuiltinTones),
      new CheckCase('设置读取', SelfCheckService.checkSettings)
    ];
  }

  // ---------------- 用例 ----------------

  /** hex / 大小端 / 切片 / UTF-8 编解码 */
  private static checkByteUtils(): void {
    const source: Uint8Array = SelfCheckService.pattern(64, 7);
    SelfCheckService.assertBytes(ByteUtils.fromHex(ByteUtils.toHex(source)), source, 'hex 往返');

    const be32: Uint8Array = ByteUtils.be32(0x01020304);
    SelfCheckService.assert(ByteUtils.intBE(be32) === 0x01020304,
      `be32/intBE 往返得到 0x${ByteUtils.intBE(be32).toString(16)}`);

    const be16: Uint8Array = ByteUtils.be16(0xABCD);
    SelfCheckService.assert(be16[0] === 0xAB && be16[1] === 0xCD, 'be16 字节顺序错误');

    const le16: Uint8Array = ByteUtils.u16le(0x1234);
    SelfCheckService.assert(le16[0] === 0x34 && le16[1] === 0x12, 'u16le 字节顺序错误');

    const le32: Uint8Array = ByteUtils.u32le(0x89ABCDEF);
    SelfCheckService.assert(le32[0] === 0xEF && le32[3] === 0x89, 'u32le 字节顺序错误');

    SelfCheckService.assert(ByteUtils.slice(source, 10, 20).length === 10, 'slice 正常区间长度错误');
    SelfCheckService.assert(ByteUtils.slice(source, -5, 999).length === 64, 'slice 越界未收敛');
    SelfCheckService.assert(ByteUtils.slice(source, 30, 10).length === 0, 'slice 反向区间应为空');

    SelfCheckService.assert(ByteUtils.utf8('盒').length === 3, 'UTF-8 三字节字符长度错误');
    SelfCheckService.assert(ByteUtils.utf8('A').length === 1, 'UTF-8 单字节字符长度错误');
  }

  /** 摘要必须与标准向量一致，否则耳机侧校验会整包拒绝 */
  private static checkSha256(): void {
    const digest: string = ByteUtils.toHex(Sha256Utils.digest(ByteUtils.utf8('abc')))
      .split(' ').join('').toLowerCase();
    SelfCheckService.assertSame(digest,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'SHA-256("abc") 与标准向量不一致');
  }

  /**
   * 规格上限必须自洽。
   *
   * 界面用 MAX_SECONDS 画滑块，写入用 MAX_BYTES 拦截：两者不一致时会出现
   * 「界面允许、写入拒绝」的割裂体验；MAX_BYTES 也必须是由采样率推导出来的偶数，
   * 否则音效包长度会对不齐。
   */
  private static checkToneSpec(): void {
    SelfCheckService.assert(ToneSpec.BYTES_PER_FRAME === 2,
      `每帧字节数为 ${ToneSpec.BYTES_PER_FRAME}，16bit 单声道应为 2`);
    SelfCheckService.assert(ToneSpec.BYTES_PER_SECOND === ToneSpec.SAMPLE_RATE * ToneSpec.BYTES_PER_FRAME,
      `每秒字节数 ${ToneSpec.BYTES_PER_SECOND} 与采样率 ${ToneSpec.SAMPLE_RATE} 不自洽`);
    SelfCheckService.assert(ToneSpec.MAX_BYTES === Math.floor(ToneSpec.BYTES_PER_SECOND * ToneSpec.MAX_SECONDS),
      `上限 ${ToneSpec.MAX_BYTES} 字节与 ${ToneSpec.MAX_SECONDS} 秒不一致`);
    SelfCheckService.assert(ToneSpec.MAX_BYTES % ToneSpec.BYTES_PER_FRAME === 0,
      `上限 ${ToneSpec.MAX_BYTES} 不是整帧长度`);
    SelfCheckService.assert(ToneSpec.MIN_SECONDS > 0 && ToneSpec.MIN_SECONDS < ToneSpec.MAX_SECONDS,
      `时长区间 ${ToneSpec.MIN_SECONDS}~${ToneSpec.MAX_SECONDS} 非法`);
    SelfCheckService.assert(ToneSpec.MAX_IMPORT_BYTES > ToneSpec.MAX_BYTES &&
      ToneSpec.MAX_IMPORT_BYTES % ToneSpec.BYTES_PER_FRAME === 0,
      `导入上限 ${ToneSpec.MAX_IMPORT_BYTES} 小于可写入上限或不是整帧长度`);

    // 超限音效包必须被拒绝：放过一次就可能让耳机擦写阶段卡死
    let rejected: boolean = false;
    try {
      MbbProtocol.tonePackage(new Uint8Array(ToneSpec.MAX_BYTES + ToneSpec.BYTES_PER_FRAME), 'over');
    } catch (error) {
      rejected = true;
    }
    SelfCheckService.assert(rejected, '超过上限的音效包未被拒绝');
  }

  /** 单帧：帧头、长度字段、CRC 自校验、载荷位置 */
  private static checkFraming(): void {
    const payload: Uint8Array = SelfCheckService.pattern(64, 11);
    const packet: Uint8Array = MbbProtocol.frame(payload);

    SelfCheckService.assert(packet[0] === MbbSpec.FRAME_HEAD, '帧头错误');
    const bodyLength: number = ((packet[1] & 0xFF) << 8) | (packet[2] & 0xFF);
    SelfCheckService.assert(bodyLength === payload.length + 1,
      `长度字段为 ${bodyLength}，期望 ${payload.length + 1}`);
    SelfCheckService.assert(packet.length === bodyLength + 5,
      `整帧长度 ${packet.length} 与长度字段 ${bodyLength} 不自洽`);
    SelfCheckService.assert(MbbProtocol.crc(packet) === 0, '整帧 CRC 不为 0');

    SelfCheckService.assertBytes(packet.slice(4, packet.length - 2), payload, '载荷位置偏移');
  }

  /** 超长载荷：分片控制字/序号正确，且能被拆包器原样拼回 */
  private static checkFragments(): void {
    const payload: Uint8Array = SelfCheckService.pattern(3000, 17);
    const frames: Uint8Array[] = MbbProtocol.frames(payload);
    const expected: number = Math.ceil(payload.length / MbbSpec.FRAME_CHUNK_SIZE);
    SelfCheckService.assert(frames.length === expected,
      `分片数为 ${frames.length}，期望 ${expected}`);

    SelfCheckService.assert((frames[0][3] & 0xFF) === MbbProtocol.CONTROL_FIRST, '首片控制字错误');
    SelfCheckService.assert((frames[frames.length - 1][3] & 0xFF) === MbbProtocol.CONTROL_LAST,
      '末片控制字错误');
    for (let i = 1; i < frames.length - 1; i++) {
      SelfCheckService.assert((frames[i][3] & 0xFF) === MbbProtocol.CONTROL_MIDDLE,
        `第 ${i} 片控制字错误`);
    }
    SelfCheckService.assert((frames[1][4] & 0xFF) === 1, '第二片序号错误');

    // 按不等长切片喂给拆包器，模拟串口一次回调只有半个帧的情况
    const received: Uint8Array[] = [];
    const errors: string[] = [];
    const assembler: PacketAssembler = new PacketAssembler((packed: Uint8Array): void => {
      received.push(packed);
    }, (message: string): void => {
      errors.push(message);
    });
    const stream: Uint8Array = ByteUtils.concat(frames);
    const chunks: number[] = [7, 13, 100, 1, 900, 511, 1500];
    let offset: number = 0;
    let step: number = 0;
    while (offset < stream.length) {
      let size: number = chunks[step % chunks.length];
      if (size > stream.length - offset) {
        size = stream.length - offset;
      }
      assembler.feed(stream.slice(offset, offset + size));
      offset += size;
      step++;
      if (step > 1000) {
        throw new Error('拆包器喂数据循环未收敛');
      }
    }

    SelfCheckService.assert(errors.length === 0, `拆包报错：${errors.join('；')}`);
    SelfCheckService.assert(received.length === 1, `重组出 ${received.length} 个包，期望 1 个`);
    SelfCheckService.assertBytes(received[0], payload, '重组内容不一致');
  }

  /** TLV：短值与两字节扩展长度都要能还原 */
  private static checkTlv(): void {
    const shortValue: Uint8Array = SelfCheckService.pattern(20, 3);
    const longValue: Uint8Array = SelfCheckService.pattern(300, 5);
    const payload: Uint8Array = ByteUtils.concat([
      MbbProtocol.field(1, shortValue),
      MbbProtocol.field(2, longValue)
    ]);

    const values: Map<number, Uint8Array> = MbbProtocol.tlv(payload, 0);
    const first: Uint8Array | undefined = values.get(1);
    const second: Uint8Array | undefined = values.get(2);
    if (first === undefined || second === undefined) {
      throw new Error('TLV 缺少字段 1 或 2');
    }
    SelfCheckService.assertBytes(first, shortValue, '短 TLV 值不一致');
    SelfCheckService.assertBytes(second, longValue, '长 TLV 值不一致');
  }

  /** 音效包：长度前缀、摘要覆盖范围、头内采样率 */
  private static checkTonePackage(): void {
    const pcm: Uint8Array = SelfCheckService.pattern(400, 9);
    const pkg: Uint8Array = MbbProtocol.tonePackage(pcm, 'Whistle');

    const expectedLength: number = 4 + 32 + 48 + pcm.length + 4;
    SelfCheckService.assert(pkg.length === expectedLength,
      `包长 ${pkg.length}，期望 ${expectedLength}`);

    const bodyLength: number = ByteUtils.intBE(pkg.slice(0, 4));
    SelfCheckService.assert(bodyLength === 48 + pcm.length,
      `长度前缀为 ${bodyLength}，期望 ${48 + pcm.length}`);

    const body: Uint8Array = pkg.slice(36, 36 + bodyLength);
    SelfCheckService.assertBytes(pkg.slice(4, 36), Sha256Utils.digest(body), '摘要未覆盖 48 字节头 + PCM');

    const rate: number = (body[12] & 0xFF) | ((body[13] & 0xFF) << 8) |
      ((body[14] & 0xFF) << 16) | ((body[15] & 0xFF) << 24);
    SelfCheckService.assert(rate === ToneSpec.SAMPLE_RATE,
      `头内采样率为 ${rate}，期望 ${ToneSpec.SAMPLE_RATE}`);

    // 中文名称必须完整写进 32 字节名称字段（曾因缓冲区按字符数分配而被截断）
    const chineseName: string = '测试音';
    const nameBytes: Uint8Array = ByteUtils.utf8(chineseName);
    SelfCheckService.assert(nameBytes.length === chineseName.length * 3,
      `中文名 UTF-8 长度为 ${nameBytes.length}，期望 ${chineseName.length * 3}`);
    const named: Uint8Array = MbbProtocol.tonePackage(pcm, chineseName);
    SelfCheckService.assertBytes(named.slice(36 + 16, 36 + 16 + nameBytes.length), nameBytes,
      '中文名称未完整写入包头');
  }

  /** 状态响应解析：标记位与 12 字节设置块 */
  private static checkParseStatus(): void {
    const block: Uint8Array = new Uint8Array([1, 1, 42, 0, 0, 0, 0, 0, 0, 0x01, 0x2C, 1]);
    const payload: Uint8Array = ByteUtils.concat([
      new Uint8Array([0x01, 0x06]),
      MbbProtocol.field(1, new Uint8Array([16])),
      MbbProtocol.field(2, block)
    ]);

    const status: ToneStatus = MbbProtocol.parseStatus(payload);
    SelfCheckService.assert(status.enabled, 'enabled 解析错误');
    SelfCheckService.assert(status.master, 'master 解析错误');
    SelfCheckService.assert(status.volume === 42, `音量解析为 ${status.volume}，期望 42`);
    SelfCheckService.assert(status.toneId === 300, `音效 ID 解析为 ${status.toneId}，期望 300`);
    SelfCheckService.assert(status.selected, 'selected 解析错误');
  }

  /** 内置音效目录：id 唯一、名称与路径合法、展示顺序固定 */
  private static checkBuiltinTones(): void {
    const tones: BuiltinTone[] = BuiltinToneCatalog.all();
    SelfCheckService.assert(tones.length === 9, `内置音效数量异常：${tones.length}`);
    const seen: string[] = [];
    for (let i = 0; i < tones.length; i++) {
      const tone: BuiltinTone = tones[i];
      SelfCheckService.assert(tone.id.length > 0, `第 ${i} 项 id 为空`);
      SelfCheckService.assert(tone.zh.length > 0, `${tone.id} 中文名为空`);
      SelfCheckService.assert(seen.indexOf(tone.id) < 0, `id 重复：${tone.id}`);
      SelfCheckService.assert(/^[a-z0-9_]+$/.test(tone.id), `id 含非法字符：${tone.id}`);
      seen.push(tone.id);
    }
    // 展示顺序由产品侧指定，防止改动时被重排
    const expected: string = 'faq,demo,zako,wow,kobe,woqu,taishuai,xiexie,bendan';
    SelfCheckService.assert(seen.join(',') === expected, `内置音效顺序错误：${seen.join(',')}`);
  }

  /** 设置读出的值必须落在业务允许区间内 */
  private static checkSettings(): void {
    const settings: AppSettings = SettingsService.get();
    const minMs: number = ToneSpec.MIN_SECONDS * 1000;
    const maxMs: number = ToneSpec.MAX_SECONDS * 1000;
    SelfCheckService.assert(settings.defaultDurationMs >= minMs && settings.defaultDurationMs <= maxMs,
      `默认时长 ${settings.defaultDurationMs}ms 超出 ${minMs}~${maxMs}ms`);
    SelfCheckService.assert(Number.isFinite(settings.defaultGainDb),
      `默认增益不是有效数字：${settings.defaultGainDb}`);
    SelfCheckService.assert(settings.defaultGainDb >= -60 && settings.defaultGainDb <= 12,
      `默认增益 ${settings.defaultGainDb}dB 超出 -60~12dB`);
  }

  // ---------------- 工具 ----------------

  /** 确定性字节序列，避免用例之间互相影响 */
  private static pattern(length: number, seed: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(length);
    let state: number = seed >>> 0;
    for (let i = 0; i < length; i++) {
      state = (state * 1664525 + 1013904223) % 4294967296;
      out[i] = Math.floor(state / 16777216) & 0xFF;
    }
    return out;
  }

  private static assert(condition: boolean, message: string): void {
    if (!condition) {
      throw new Error(message);
    }
  }

  private static assertSame(actual: string, expected: string, message: string): void {
    if (actual !== expected) {
      throw new Error(`${message}：期望 ${expected}，实际 ${actual}`);
    }
  }

  private static assertBytes(actual: Uint8Array, expected: Uint8Array, message: string): void {
    if (actual.length !== expected.length) {
      throw new Error(`${message}：长度 ${actual.length}，期望 ${expected.length}`);
    }
    for (let i = 0; i < actual.length; i++) {
      if (actual[i] !== expected[i]) {
        throw new Error(`${message}：下标 ${i} 为 0x${actual[i].toString(16)}，期望 0x${expected[i].toString(16)}`);
      }
    }
  }
}
