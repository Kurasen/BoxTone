import { MbbSpec, ToneSpec } from '../../common/constants/AppConstants';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { Sha256Utils } from '../../common/utils/Sha256Utils';

/**
 * 华为耳机私有 MBB 协议编解码。
 *
 * 帧：0x5A | 长度(2,大端，含控制字) | 控制字(1) [| 序号(1)] | 载荷 | CRC16(2,大端)
 * CRC：CCITT-FALSE 变体，初值 0，多项式 0x1021，对整帧（含尾部 CRC）计算结果为 0。
 */
export class MbbProtocol {
  static readonly CONTROL_SINGLE: number = 0;
  static readonly CONTROL_FIRST: number = 1;
  static readonly CONTROL_MIDDLE: number = 2;
  static readonly CONTROL_LAST: number = 3;

  static crc(data: Uint8Array): number {
    let crc: number = 0;
    for (let i = 0; i < data.length; i++) {
      crc = crc ^ ((data[i] & 0xFF) << 8);
      for (let bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) !== 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      }
      crc = crc & 0xFFFF;
    }
    return crc;
  }

  static frame(payload: Uint8Array, control: number = 0, sequence: number = 0): Uint8Array {
    const bodyLength: number = control === 0 ? payload.length + 1 : payload.length + 2;
    const packet: Uint8Array = new Uint8Array(bodyLength + 3);
    packet[0] = MbbSpec.FRAME_HEAD;
    packet[1] = (bodyLength >> 8) & 0xFF;
    packet[2] = bodyLength & 0xFF;
    packet[3] = control;
    if (control === 0) {
      packet.set(payload, 4);
    } else {
      packet[4] = sequence;
      packet.set(payload, 5);
    }
    const checksum: number = MbbProtocol.crc(packet);
    const out: Uint8Array = new Uint8Array(packet.length + 2);
    out.set(packet, 0);
    out[packet.length] = (checksum >> 8) & 0xFF;
    out[packet.length + 1] = checksum & 0xFF;
    return out;
  }

  /** 超过单帧上限的载荷自动切成 FIRST/MIDDLE/LAST 分片 */
  static frames(payload: Uint8Array): Uint8Array[] {
    if (payload.length <= MbbSpec.MAX_SINGLE_PAYLOAD) {
      return [MbbProtocol.frame(payload)];
    }
    const chunk: number = MbbSpec.FRAME_CHUNK_SIZE;
    const count: number = Math.ceil(payload.length / chunk);
    const out: Uint8Array[] = [];
    for (let i = 0; i < count; i++) {
      const start: number = i * chunk;
      let control: number = MbbProtocol.CONTROL_MIDDLE;
      if (i === 0) {
        control = MbbProtocol.CONTROL_FIRST;
      } else if (i === count - 1) {
        control = MbbProtocol.CONTROL_LAST;
      }
      out.push(MbbProtocol.frame(ByteUtils.slice(payload, start, start + chunk), control, i));
    }
    return out;
  }

  /** 解析 TLV；响应前 2 字节为服务号/命令号，从下标 2 开始 */
  static tlv(data: Uint8Array, start: number = 2): Map<number, Uint8Array> {
    const result: Map<number, Uint8Array> = new Map<number, Uint8Array>();
    let at: number = start;
    while (at < data.length) {
      if (at + 2 > data.length) {
        throw new Error('耳机返回的数据不完整');
      }
      const tag: number = data[at] & 0xFF;
      at++;
      let length: number = data[at] & 0xFF;
      at++;
      if ((length & 0x80) !== 0) {
        if (at >= data.length) {
          throw new Error('耳机返回的数据不完整');
        }
        length = ((length & 0x7F) << 7) + (data[at] & 0x7F);
        at++;
      }
      if (at + length > data.length) {
        throw new Error('耳机返回的字段长度不正确');
      }
      result.set(tag, data.slice(at, at + length));
      at += length;
    }
    return result;
  }

  /** 组装一个 TLV 字段，长度 ≥128 时使用两字节扩展长度 */
  static field(tag: number, bytes: Uint8Array): Uint8Array {
    if (bytes.length > 16383) {
      throw new Error('单条指令过长');
    }
    let header: Uint8Array;
    if (bytes.length < 128) {
      header = new Uint8Array([tag & 0xFF, bytes.length & 0xFF]);
    } else {
      header = new Uint8Array([tag & 0xFF, ((bytes.length >> 7) | 0x80) & 0xFF, bytes.length & 0x7F]);
    }
    return ByteUtils.concat([header, bytes]);
  }

  /**
   * 音效包：4 字节长度 + 32 字节 SHA-256 + 48 字节头 + PCM + 4 字节 MCU 信息。
   * 摘要覆盖「48 字节头 + PCM」，与官方 RbtPackageUtil 一致。
   */
  static tonePackage(pcm: Uint8Array, name: string = 'Whistle',
    mcu: Uint8Array = new Uint8Array(4)): Uint8Array {
    if (pcm.length === 0 || pcm.length % 2 !== 0 || pcm.length > ToneSpec.MAX_BYTES) {
      throw new Error(`开盒音效必须在 ${ToneSpec.MAX_SECONDS} 秒以内且为偶数字节`);
    }
    if (mcu.length !== 4) {
      throw new Error('耳机返回的音效格式不正确');
    }
    const nameBytes: Uint8Array = ByteUtils.utf8(name);
    const nameField: Uint8Array = new Uint8Array(MbbSpec.TONE_NAME_MAX);
    nameField.set(ByteUtils.slice(nameBytes, 0, MbbSpec.TONE_NAME_MAX), 0);

    // 10 字节描述块：魔数(LE) + 00100001 + PCM 的 16 字节块数量(LE)
    const desc: Uint8Array = new Uint8Array(10);
    desc.set(ByteUtils.u16le(MbbSpec.TONE_PACKAGE_MAGIC), 0);
    desc.set(ByteUtils.fromHex('00100001'), 2);
    desc.set(ByteUtils.u32le(Math.floor(pcm.length / 16)), 6);

    const header: Uint8Array = new Uint8Array(48);
    header.set(ByteUtils.u16le(MbbProtocol.crc(ByteUtils.concat([desc, nameField]))), 0);
    header.set(desc, 2);
    header.set(ByteUtils.u32le(ToneSpec.SAMPLE_RATE), 12);
    header.set(nameField, 16);

    const body: Uint8Array = ByteUtils.concat([header, pcm]);
    return ByteUtils.concat([ByteUtils.be32(body.length), Sha256Utils.digest(body), body, mcu]);
  }

  /** 解析音效状态：TLV[1] 为标记(必须 16)，TLV[2] 为 12 字节设置块 */
  static parseStatus(payload: Uint8Array): ToneStatus {
    const values: Map<number, Uint8Array> = MbbProtocol.tlv(payload);
    const marker: Uint8Array | undefined = values.get(1);
    if (marker === undefined || marker.length !== 1 || (marker[0] & 0xFF) !== 16) {
      throw new Error('耳机没有返回开盒音效状态');
    }
    const value: Uint8Array | undefined = values.get(2);
    if (value === undefined) {
      throw new Error('耳机没有返回开盒音效设置');
    }
    if (value.length !== 12) {
      throw new Error('耳机返回的开盒音效设置长度不正确');
    }
    return new ToneStatus((value[0] & 0xFF) === 1, (value[1] & 0xFF) === 1, value[2] & 0xFF,
      ((value[9] & 0xFF) << 8) | (value[10] & 0xFF), (value[11] & 0xFF) === 1);
  }
}

/** 耳机当前的开盒音效设置 */
export class ToneStatus {
  enabled: boolean;
  master: boolean;
  volume: number;
  toneId: number;
  selected: boolean;

  constructor(enabled: boolean, master: boolean, volume: number, toneId: number, selected: boolean) {
    this.enabled = enabled;
    this.master = master;
    this.volume = volume;
    this.toneId = toneId;
    this.selected = selected;
  }
}

/**
 * 流式拆包器。
 * 串口是字节流，一次回调可能包含半个帧或若干个帧；这里负责缓存、
 * 校验 CRC、重组 MBB 分片，只有完整业务包才回调给上层。
 */
export class PacketAssembler {
  private buffer: Uint8Array = new Uint8Array(0);
  private fragments: Uint8Array | null = null;
  private nextSequence: number = 0;
  private onPacket: (payload: Uint8Array) => void;
  private onError: (message: string) => void;

  constructor(onPacket: (payload: Uint8Array) => void, onError: (message: string) => void) {
    this.onPacket = onPacket;
    this.onError = onError;
  }

  reset(): void {
    this.buffer = new Uint8Array(0);
    this.fragments = null;
    this.nextSequence = 0;
  }

  feed(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    this.buffer = ByteUtils.concat([this.buffer, chunk]);
    while (this.buffer.length >= 3) {
      if ((this.buffer[0] & 0xFF) !== MbbSpec.FRAME_HEAD) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      const size: number = (((this.buffer[1] & 0xFF) << 8) | (this.buffer[2] & 0xFF)) + 5;
      if (size < MbbSpec.MIN_FRAME_BYTES || size > MbbSpec.MAX_FRAME_BYTES) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      if (this.buffer.length < size) {
        return;
      }
      const packet: Uint8Array = this.buffer.slice(0, size);
      this.buffer = this.buffer.slice(size);
      if (MbbProtocol.crc(packet) !== 0) {
        this.onError('收到校验失败的蓝牙数据');
        this.fragments = null;
        continue;
      }
      this.consume(packet);
    }
  }

  private consume(packet: Uint8Array): void {
    const control: number = packet[3] & 0xFF;
    if (control === MbbProtocol.CONTROL_SINGLE) {
      this.fragments = null;
      this.onPacket(packet.slice(4, packet.length - 2));
      return;
    }
    if (control === MbbProtocol.CONTROL_FIRST) {
      if (packet.length < 7 || (packet[4] & 0xFF) !== 0) {
        this.fragments = null;
        return;
      }
      this.fragments = packet.slice(5, packet.length - 2);
      this.nextSequence = 1;
      return;
    }
    if (control === MbbProtocol.CONTROL_MIDDLE || control === MbbProtocol.CONTROL_LAST) {
      const pending: Uint8Array | null = this.fragments;
      if (pending === null) {
        return;
      }
      if (packet.length < 7 || (packet[4] & 0xFF) !== this.nextSequence) {
        this.fragments = null;
        return;
      }
      this.nextSequence++;
      const merged: Uint8Array = ByteUtils.concat([pending, packet.slice(5, packet.length - 2)]);
      if (control === MbbProtocol.CONTROL_LAST) {
        this.fragments = null;
        this.onPacket(merged);
      } else {
        this.fragments = merged;
      }
    }
  }
}

/** 耳机侧错误码翻译：这些码是实测中会稳定出现的拒绝原因 */
export class ToneStatusCodec {
  /** 是否是已知的、有明确处置建议的错误码 */
  static isKnown(code: number): boolean {
    if (code === 100010 || code === 109012) {
      return true;
    }
    if (code === 100011 || code === 109002 || code === 109024) {
      return true;
    }
    if (code === 100012 || code === 109006 || code === 100013 || code === 109022) {
      return true;
    }
    return false;
  }

  static errorText(code: number): string {
    if (code === 100010 || code === 109012) {
      return '请将两只耳机放入充电盒后重试';
    }
    if (code === 100011 || code === 109002 || code === 109024) {
      return '充电盒电量不足，请充电后重试';
    }
    if (code === 100012 || code === 109006) {
      return '耳机正在更新，请等待更新完成';
    }
    if (code === 100013) {
      return '耳机正在传输其他数据，请稍后重试';
    }
    if (code === 109022) {
      return '耳机正在录音，请结束录音后重试';
    }
    return `耳机拒绝了音效传输（${code}）`;
  }
}
