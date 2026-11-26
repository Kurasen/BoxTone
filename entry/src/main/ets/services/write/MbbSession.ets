import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { Logger } from '../../common/utils/Logger';
import { MbbProtocol, ToneStatus } from '../bluetooth/MbbProtocol';
import {
  AckTimeoutError,
  CancelledError,
  TONE_CODE_UNSUPPORTED,
  ToneError,
  ToneErrorReason
} from '../bluetooth/ToneTypes';
import { AudioLink } from './AudioLink';
import { DeviceTimeline } from './DeviceTimeline';
import { PacketMatcher } from './PacketInbox';
import { SppChannel } from './SppChannel';
import { SppErrors } from './SppErrors';
import { WriteSpec } from './WriteSpec';
import { TraceSink, UploadPort } from './WriteTypes';

const MODULE: string = 'MbbSession';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

const STATUS_QUERY: string = '2bb4010110';

function isStatusPacket(packet: Uint8Array): boolean {
  return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x2b && ByteUtils.byteAt(packet, 1) === 0xb4;
}

function isDeviceInfoPacket(packet: Uint8Array): boolean {
  return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x01 && ByteUtils.byteAt(packet, 1) === 0x07;
}

/**
 * 一次 MBB 会话：在一条串口上跑命令、保活和上传。
 *
 * 和旧 ToneClient 的区别：
 * - 不再自己建链、不管热会话池、不碰全局静态状态：建链在 LinkConnector，复用在 WriteEngine；
 * - 保活与传输互斥由「静默」开关显式控制，而不是散落在定时器里的多处判断；
 * - 实现 UploadPort，上传状态机（ToneUploader）可以脱离真机单测。
 */
export class MbbSession implements UploadPort {
  readonly address: string;
  readonly channel: SppChannel;
  readonly audio: AudioLink;
  private readonly timeline: DeviceTimeline;
  private readonly trace: TraceSink;
  private keepAliveTimer: number = -1;
  /** 静默：传输与擦写期间耳机在写闪存，插任何心跳都会被当成中止信号 */
  private quiet: boolean = false;
  private cancelledFlag: boolean = false;
  private uploadProtocol: number = 2;
  private uploadVolume: number = 0;

  /** 耳机自报型号（0107 tag 15），未识别为空串；不读取 SN 等其他字段 */
  deviceModel: string = '';
  protocolUsed: number = 0;

  constructor(channel: SppChannel, audio: AudioLink, timeline: DeviceTimeline, trace: TraceSink) {
    this.address = channel.address;
    this.channel = channel;
    this.audio = audio;
    this.timeline = timeline;
    this.trace = trace;
  }

  isOpen(): boolean {
    return !this.cancelledFlag && this.channel.isOpen();
  }

  cancel(): void {
    this.cancelledFlag = true;
    this.stopKeepAlive();
    this.channel.cancel();
  }

  close(): void {
    this.stopKeepAlive();
    this.channel.close();
  }

  // ---------------------------------------------------------------- 保活

  /** 耳机串口静默约 4 秒就会被收掉：空闲时每 3 秒说一句话 */
  startKeepAlive(): void {
    this.stopKeepAlive();
    this.keepAliveTimer = setInterval(() => {
      if (!this.channel.isOpen()) {
        this.stopKeepAlive();
        return;
      }
      if (this.quiet || Date.now() < this.timeline.settleUntil) {
        return;
      }
      if (Date.now() - this.channel.lastIoAt < 3000) {
        return;
      }
      this.channel.sendPayload(ByteUtils.fromHex(STATUS_QUERY), false).catch((error: Error) => {
        this.trace(`KEEPALIVE_FAIL ${SppErrors.messageOf(error)}`);
        this.stopKeepAlive();
      });
    }, 3000);
  }

  stopKeepAlive(): void {
    if (this.keepAliveTimer >= 0) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
  }

  /** 进入/离开静默期 */
  setQuiet(quiet: boolean): void {
    this.quiet = quiet;
    this.channel.transferring = quiet;
  }

  /** 交还给热会话池前清掉旧回包：上一条 TONE_SET 回执会干扰下一次匹配 */
  resetForReuse(): void {
    this.setQuiet(false);
    this.channel.clearQueue();
  }

  // ---------------------------------------------------------------- 命令

  private async command(payload: Uint8Array, timeoutMs: number = MbbSpec.ACK_TIMEOUT_MS,
    attempts: number = 2): Promise<Uint8Array> {
    const service: number = ByteUtils.byteAt(payload, 0);
    const commandId: number = ByteUtils.byteAt(payload, 1);
    const matcher: PacketMatcher = (packet: Uint8Array): boolean => {
      return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === service &&
        ByteUtils.byteAt(packet, 1) === commandId;
    };
    const total: number = Math.max(1, attempts);
    for (let attempt = 0; attempt < total; attempt++) {
      this.throwIfCancelled();
      await this.channel.sendPayload(payload, true);
      try {
        const reply: Uint8Array = await this.channel.wait(matcher, timeoutMs);
        // 重发会让耳机回多份回执：匹配成功后清掉同一命令的重复包
        this.channel.purge(matcher);
        return reply;
      } catch (error) {
        const timeout: boolean = error instanceof AckTimeoutError;
        if (timeout && attempt < total - 1) {
          this.trace(`ACK_TIMEOUT_RETRY attempt=${attempt + 1}/${total} seen=${this.pending()}`);
          await sleep(150);
          continue;
        }
        if (timeout) {
          this.trace(`ACK_TIMEOUT cmd=${ByteUtils.toHex(payload.slice(0, 2))} attempt=${attempt + 1}/${total} ` +
            `seen=${this.pending()}`);
        }
        throw error as Error;
      }
    }
    throw new AckTimeoutError();
  }

  private pending(): string {
    return this.channel.describePending(isDeviceInfoPacket);
  }

  /** 读当前开盒音设置。刚建链时耳机可能丢掉第一条命令，用短超时多次重发 */
  async query(): Promise<ToneStatus> {
    // 先清旧状态包：连接期耳机主动推的 2B B4 不是这次查询的回执
    this.channel.purge(isStatusPacket);
    const reply: Uint8Array = await this.command(ByteUtils.fromHex(STATUS_QUERY), MbbSpec.QUERY_TIMEOUT_MS,
      MbbSpec.QUERY_ATTEMPTS);
    return MbbProtocol.parseStatus(reply);
  }

  /** 热会话还活不活：失败只花一两秒，比拿一整包数据去撞死 socket 强得多 */
  async probeAlive(): Promise<boolean> {
    if (!this.channel.isOpen()) {
      return false;
    }
    this.channel.purge(isStatusPacket);
    try {
      await this.command(ByteUtils.fromHex(STATUS_QUERY), MbbSpec.QUERY_TIMEOUT_MS, 1);
      return true;
    } catch (error) {
      this.trace(`SESSION_PROBE_FAIL ${SppErrors.messageOf(error)}`);
      return false;
    }
  }

  /** 读耳机自报型号：只解析 15 号字段，SN 不进日志；失败返回空串，不影响写入 */
  async readDeviceModel(): Promise<string> {
    this.channel.muteRx(2000);
    try {
      const reply: Uint8Array = await this.command(ByteUtils.fromHex('01070F00'), 1200, 1);
      const field: Uint8Array | undefined = MbbProtocol.tlv(reply).get(15);
      if (field === undefined || field.length === 0 || field.length > 32) {
        return '';
      }
      const model: string = MbbSession.asciiText(field);
      if (model.length > 0) {
        this.deviceModel = model;
        this.trace(`DEVICE_MODEL ${model}`);
      }
      return model;
    } catch (error) {
      if (error instanceof CancelledError) {
        throw error as Error;
      }
      this.trace(`DEVICE_MODEL_FAIL code=${SppErrors.codeOf(error)}`);
      return '';
    } finally {
      this.channel.purge(isDeviceInfoPacket);
    }
  }

  /** 固件支持哪一版音效传输协议：2 = 09 命令族，1 = 2BB6 分片 */
  async protocolVersion(): Promise<number> {
    if (this.timeline.protocol > 0) {
      this.trace(`PROTOCOL_CACHED ${this.timeline.protocol}`);
      this.protocolUsed = this.timeline.protocol;
      return this.timeline.protocol;
    }
    const rawCaps: Uint8Array = await this.command(ByteUtils.fromHex('2bb30101010e0100150100'));
    const capsHex: string = ByteUtils.toHex(rawCaps);
    // 原始能力字段全量入库：其他机型兼容性只能靠这些 tag 判断
    Logger.info(MODULE, `CAPS ${capsHex}`);
    const caps: Map<number, Uint8Array> = MbbProtocol.tlv(rawCaps);
    const supported: (tag: number) => boolean = (tag: number): boolean => {
      const value: Uint8Array | undefined = caps.get(tag);
      return value !== undefined && value.length >= 2 && ByteUtils.byteAt(value, 1) === 1;
    };
    let protocol: number = 0;
    if (supported(21)) {
      protocol = 2;
    } else if (supported(14)) {
      protocol = 1;
    }
    if (protocol > 0) {
      this.timeline.protocol = protocol;
      this.protocolUsed = protocol;
      return protocol;
    }
    const declared: boolean = caps.has(21) || caps.has(14);
    const failure: ToneError = new ToneError(declared ? I18n.t('toneErr.unsupportedReported') :
      I18n.t('toneErr.unknownFirmware'), TONE_CODE_UNSUPPORTED);
    failure.reason = ToneErrorReason.UNSUPPORTED;
    failure.diagnostic = `CAPS=${capsHex} declared=${declared ? 1 : 0}`;
    throw failure;
  }

  /** 发一条「选中音效」设置，只解析回包、不做语义校验 */
  async setToneRaw(id: number, selected: boolean, volume: number,
    timeoutMs: number = MbbSpec.ACK_TIMEOUT_MS, attempts: number = 2): Promise<ToneStatus> {
    const clamped: number = volume < 0 ? 0 : (volume > 15 ? 15 : volume);
    const setting: Uint8Array = new Uint8Array(12);
    setting[0] = 1;
    setting[1] = 1;
    setting[2] = clamped;
    setting.set(ByteUtils.be16(id), 9);
    setting[11] = selected ? 1 : 0;
    const payload: Uint8Array = ByteUtils.concat([ByteUtils.fromHex(STATUS_QUERY), MbbProtocol.field(2, setting)]);
    const status: ToneStatus = MbbProtocol.parseStatus(await this.command(payload, timeoutMs, attempts));
    this.trace(`TONE_SET id=${id} sel=${selected} vol=${clamped} -> enabled=${status.enabled} ` +
      `tone=${status.toneId} selected=${status.selected}`);
    return status;
  }

  async setTone(id: number, selected: boolean, volume: number,
    timeoutMs: number = MbbSpec.ACK_TIMEOUT_MS, attempts: number = 2): Promise<ToneStatus> {
    const status: ToneStatus = await this.setToneRaw(id, selected, volume, timeoutMs, attempts);
    if (!status.enabled || status.selected !== selected) {
      throw new ToneError(I18n.t('toneErr.applyFailed'));
    }
    return status;
  }

  /**
   * 选中盒端内置音效。selected 标志在不同固件上语义不一致，这里不猜：
   * 先按「恢复出厂」的写法发，没生效再补一次 selected=true。
   */
  async selectBuiltIn(id: number): Promise<ToneStatus> {
    const current: ToneStatus = await this.query();
    const first: ToneStatus = await this.setToneRaw(id, false, current.volume);
    if (first.toneId === id) {
      return first;
    }
    const second: ToneStatus = await this.setToneRaw(id, true, current.volume);
    if (second.toneId !== id) {
      throw new ToneError(I18n.t('toneErr.applyFailed'));
    }
    return second;
  }

  async restoreDefault(): Promise<ToneStatus> {
    const current: ToneStatus = await this.query();
    return await this.setTone(0, false, current.volume);
  }

  /**
   * 补发「选中自定义槽位」。只在同一条链路上快速重试；链路已断就抛 DATA_WRITTEN，
   * 让引擎换一条新链路只补这一条命令，而不是重传整包。
   */
  async confirmCustom(volume: number): Promise<ToneStatus> {
    const waits: number[] = [0, 260, 520, 900, 1400];
    let lastError: ToneError | null = null;
    for (let i = 0; i < waits.length; i++) {
      if (waits[i] > 0) {
        await sleep(waits[i]);
      }
      this.throwIfCancelled();
      if (!this.channel.isOpen()) {
        break;
      }
      try {
        return await this.setTone(MbbSpec.TONE_CUSTOM_ID, true, volume, 1500, 1);
      } catch (error) {
        if (error instanceof CancelledError) {
          throw error as Error;
        }
        lastError = SppErrors.describe(error);
        this.trace(`TONE_CONFIRM_RETRY attempt=${i + 1}/${waits.length} ${SppErrors.messageOf(error)}`);
      }
    }
    if (!this.channel.isOpen()) {
      const written: ToneError = new ToneError(I18n.t('toneErr.writtenNoSwitch'), SppErrors.IO_ERROR);
      written.reason = ToneErrorReason.DATA_WRITTEN;
      throw written;
    }
    throw lastError !== null ? lastError : new ToneError(I18n.t('toneErr.applyTimeout'));
  }

  // ---------------------------------------------------------------- 上传端口

  /** 上传开始前调用：记下协议与音量，进入静默 */
  beginUpload(protocol: number, volume: number): void {
    this.uploadProtocol = protocol;
    this.uploadVolume = volume;
    this.setQuiet(true);
  }

  /** 上传结束（无论成败）：记沉降期 */
  endUpload(flashed: boolean): void {
    if (flashed) {
      const audioDown: boolean = !this.audio.isLinked();
      this.timeline.noteFlashed();
      Logger.info(MODULE, `TONE_SETTLED settle=${WriteSpec.postFlashGapMs()}ms audioDown=${audioDown}`);
    }
    this.setQuiet(false);
  }

  send(payload: Uint8Array): Promise<void> {
    this.throwIfCancelled();
    return this.channel.sendPayload(payload, true);
  }

  sendWindow(payloads: Uint8Array[]): Promise<void> {
    this.throwIfCancelled();
    const frames: Uint8Array[] = [];
    for (let i = 0; i < payloads.length; i++) {
      const parts: Uint8Array[] = MbbProtocol.frames(payloads[i]);
      for (let p = 0; p < parts.length; p++) {
        frames.push(parts[p]);
      }
    }
    return this.channel.sendFrames(frames);
  }

  chunkHint(chunkSize: number): void {
    this.channel.applyChunkHint(chunkSize);
  }

  next(timeoutMs: number): Promise<Uint8Array> {
    const protocol: number = this.uploadProtocol;
    return this.channel.wait((packet: Uint8Array): boolean => {
      if (packet.length < 2) {
        return false;
      }
      if (protocol === 1) {
        return ByteUtils.byteAt(packet, 0) === 0x2b && ByteUtils.byteAt(packet, 1) === 0xb6;
      }
      return ByteUtils.byteAt(packet, 0) === 0x09;
    }, timeoutMs);
  }

  async preselect(): Promise<boolean> {
    try {
      await this.setTone(MbbSpec.TONE_CUSTOM_ID, true, this.uploadVolume, 1500, 1);
      return true;
    } catch (error) {
      if (error instanceof CancelledError || !this.channel.isOpen()) {
        throw error as Error;
      }
      // 耳机对这条命令不一定回执：不影响传输，收尾时再确认
      this.trace(`TONE_PRESELECT_IGNORED ${SppErrors.messageOf(error)}`);
      return false;
    }
  }

  async idle(suppressAudio: boolean): Promise<void> {
    if (this.cancelledFlag || !this.channel.isOpen() || !suppressAudio) {
      return;
    }
    if (this.audio.isLinked()) {
      this.trace('AUDIO_RELINK_SUPPRESS 传输/擦写期间音频被连回，先断开它');
      await this.audio.suppress();
    }
  }

  now(): number {
    return Date.now();
  }

  private throwIfCancelled(): void {
    if (this.cancelledFlag) {
      throw new CancelledError();
    }
  }

  private static asciiText(bytes: Uint8Array): string {
    let text: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const value: number = bytes[i] & 0xFF;
      if (value === 0) {
        break;
      }
      if (value < 0x20 || value > 0x7E) {
        return '';
      }
      text += String.fromCharCode(value);
    }
    return text.trim();
  }
}
