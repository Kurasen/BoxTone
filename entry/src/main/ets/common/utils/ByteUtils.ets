/**
 * 字节工具：大小端、hex、切片、拼接
 *
 * 统一以 Uint8Array 交互。SPP 是字节流，协议层每一步都要做切片与拼接，
 * 用 Uint8Array 可以避免 number[] 在大包（64KB 音效包）上反复分配带来的拷贝开销。
 */
export class ByteUtils {
  static byteAt(bytes: Uint8Array, index: number): number {
    if (index < 0 || index >= bytes.length) {
      return 0;
    }
    return bytes[index] & 0xFF;
  }

  static toHex(bytes: Uint8Array): string {
    const parts: string[] = [];
    for (let i = 0; i < bytes.length; i++) {
      const value: number = bytes[i] & 0xFF;
      parts.push(value < 16 ? `0${value.toString(16)}` : value.toString(16));
    }
    return parts.join(' ').toUpperCase();
  }

  static fromHex(text: string): Uint8Array {
    const clean: string = text.replace(/ /g, '');
    const out: Uint8Array = new Uint8Array(Math.floor(clean.length / 2));
    for (let i = 0; i < out.length; i++) {
      out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16) & 0xFF;
    }
    return out;
  }

  static be16(value: number): Uint8Array {
    return new Uint8Array([(value >> 8) & 0xFF, value & 0xFF]);
  }

  static be32(value: number): Uint8Array {
    return new Uint8Array([(value >>> 24) & 0xFF, (value >>> 16) & 0xFF, (value >>> 8) & 0xFF, value & 0xFF]);
  }

  /** 大端 4 字节转整数（协议里的长度/偏移都是大端） */
  static intBE(bytes: Uint8Array): number {
    return ((bytes[0] & 0xFF) * 0x1000000) + (((bytes[1] & 0xFF) << 16) | ((bytes[2] & 0xFF) << 8) |
      (bytes[3] & 0xFF));
  }

  static u16le(value: number): Uint8Array {
    return new Uint8Array([value & 0xFF, (value >> 8) & 0xFF]);
  }

  static u32le(value: number): Uint8Array {
    return new Uint8Array([value & 0xFF, (value >>> 8) & 0xFF, (value >>> 16) & 0xFF, (value >>> 24) & 0xFF]);
  }

  static concat(parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let at: number = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], at);
      at += parts[i].length;
    }
    return out;
  }

  static slice(bytes: Uint8Array, start: number, end: number): Uint8Array {
    const from: number = start < 0 ? 0 : start;
    const to: number = end > bytes.length ? bytes.length : end;
    if (to <= from) {
      return new Uint8Array(0);
    }
    return bytes.slice(from, to);
  }

  static utf8(text: string): Uint8Array {
    // UTF-8 单字符最多 3 字节，按 text.length 分配会被中文撑爆而静默截断
    const out: Uint8Array = new Uint8Array(text.length * 3);
    let length: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x80) {
        out[length] = code;
        length++;
      } else if (code < 0x800) {
        out[length] = 0xC0 | (code >> 6);
        out[length + 1] = 0x80 | (code & 0x3F);
        length += 2;
      } else {
        out[length] = 0xE0 | (code >> 12);
        out[length + 1] = 0x80 | ((code >> 6) & 0x3F);
        out[length + 2] = 0x80 | (code & 0x3F);
        length += 3;
      }
    }
    return out.slice(0, length);
  }

  static toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(bytes.length);
    new Uint8Array(buffer).set(bytes);
    return buffer;
  }
}
