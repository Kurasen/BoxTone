/**
 * WAV 头解析与样本解码
 *
 * 纯计算、无业务依赖：主线程回退路径与 TaskPool 解码任务共用同一份实现，
 * 避免两处逻辑各写一遍后行为不一致。
 * 错误以 i18n key + 插值参数返回，由调用方在主线程翻译。
 */

/** 解析出的 WAV 格式信息 */
export interface WavFormat {
  audioFormat: number;
  channels: number;
  sampleRate: number;
  bitsPerSample: number;
  dataOffset: number;
  dataSize: number;
  /** 文件中实际的音频帧总数（未截断） */
  totalFrames: number;
}

export interface WavParseResult {
  ok: boolean;
  errorKey: string;
  errorArgs: string[];
  format: WavFormat;
}

export interface WavSamplesResult {
  ok: boolean;
  errorKey: string;
  errorArgs: string[];
  samples: Float32Array;
}

function emptyFormat(): WavFormat {
  const format: WavFormat = {
    audioFormat: 1,
    channels: 1,
    sampleRate: 44100,
    bitsPerSample: 16,
    dataOffset: 0,
    dataSize: 0,
    totalFrames: 0
  };
  return format;
}

function parseFail(errorKey: string, errorArgs: string[]): WavParseResult {
  const result: WavParseResult = {
    ok: false,
    errorKey: errorKey,
    errorArgs: errorArgs,
    format: emptyFormat()
  };
  return result;
}

function readFourCC(view: DataView, offset: number): string {
  let text: string = '';
  for (let i = 0; i < 4; i++) {
    text += String.fromCharCode(view.getUint8(offset + i));
  }
  return text;
}

/** 解析 RIFF/WAVE 头；失败时 format 为默认值 */
export function parseWavHeader(buffer: ArrayBuffer): WavParseResult {
  if (buffer.byteLength < 44) {
    return parseFail('audio.wavTooSmall', []);
  }
  const view: DataView = new DataView(buffer);
  const riff: string = readFourCC(view, 0);
  const wave: string = readFourCC(view, 8);
  if (riff !== 'RIFF' || wave !== 'WAVE') {
    return parseFail('audio.wavBadHeader', []);
  }

  const result: WavFormat = emptyFormat();
  let hasFormat: boolean = false;
  let offset: number = 12;
  while (offset + 8 <= buffer.byteLength) {
    const chunkId: string = readFourCC(view, offset);
    const chunkSize: number = view.getUint32(offset + 4, true);
    const body: number = offset + 8;

    if (chunkId === 'fmt ' && body + 16 <= buffer.byteLength) {
      result.audioFormat = view.getUint16(body, true);
      result.channels = view.getUint16(body + 2, true);
      result.sampleRate = view.getUint32(body + 4, true);
      result.bitsPerSample = view.getUint16(body + 14, true);
      // WAVE_FORMAT_EXTENSIBLE：真实格式在 SubFormat GUID 前两字节
      if (result.audioFormat === 0xFFFE && body + 26 <= buffer.byteLength) {
        result.audioFormat = view.getUint16(body + 24, true);
      }
      hasFormat = true;
    } else if (chunkId === 'data') {
      result.dataOffset = body;
      result.dataSize = chunkSize;
      const remain: number = buffer.byteLength - body;
      if (chunkSize === 0 || chunkSize > remain) {
        result.dataSize = remain;
      }
      break;
    }
    offset = body + chunkSize + (chunkSize % 2);
  }

  if (!hasFormat) {
    return parseFail('audio.wavNoFmt', []);
  }
  if (result.channels < 1 || result.channels > 8) {
    return parseFail('audio.unsupportedChannels', [`${result.channels}`]);
  }
  if (result.sampleRate < 4000 || result.sampleRate > 192000) {
    return parseFail('audio.unsupportedRate', [`${result.sampleRate}`]);
  }
  if (result.audioFormat !== 1 && result.audioFormat !== 3) {
    return parseFail('audio.unsupportedWav', []);
  }
  if (result.audioFormat === 3 && result.bitsPerSample !== 32) {
    return parseFail('audio.float32Only', []);
  }

  const frameBytes: number = result.channels * result.bitsPerSample / 8;
  result.totalFrames = frameBytes > 0 ? Math.floor(result.dataSize / frameBytes) : 0;

  const parsed: WavParseResult = {
    ok: true,
    errorKey: '',
    errorArgs: [],
    format: result
  };
  return parsed;
}

function decodeFail(errorKey: string, errorArgs: string[]): WavSamplesResult {
  const result: WavSamplesResult = {
    ok: false,
    errorKey: errorKey,
    errorArgs: errorArgs,
    samples: new Float32Array(0)
  };
  return result;
}

/** 把原始 PCM 缓冲转成 [-1, 1] 的 Float32（保持交织顺序） */
export function decodeWavSamples(buffer: ArrayBuffer, format: WavFormat): WavSamplesResult {
  const view: DataView = new DataView(buffer);
  const bits: number = format.bitsPerSample;
  const isFloat: boolean = format.audioFormat === 3;
  const bytesPerSample: number = bits / 8;
  const sampleCount: number = Math.floor(buffer.byteLength / bytesPerSample);
  const out: Float32Array = new Float32Array(sampleCount);

  if (isFloat) {
    for (let i = 0; i < sampleCount; i++) {
      out[i] = view.getFloat32(i * 4, true);
    }
  } else if (bits === 8) {
    for (let i = 0; i < sampleCount; i++) {
      out[i] = (view.getUint8(i) - 128) / 128;
    }
  } else if (bits === 16) {
    for (let i = 0; i < sampleCount; i++) {
      out[i] = view.getInt16(i * 2, true) / 32768;
    }
  } else if (bits === 24) {
    for (let i = 0; i < sampleCount; i++) {
      const base: number = i * 3;
      const b0: number = view.getUint8(base);
      const b1: number = view.getUint8(base + 1);
      const b2: number = view.getUint8(base + 2);
      let value: number = (b2 << 16) | (b1 << 8) | b0;
      if ((value & 0x800000) !== 0) {
        value = value - 0x1000000;
      }
      out[i] = value / 8388608;
    }
  } else if (bits === 32) {
    for (let i = 0; i < sampleCount; i++) {
      out[i] = view.getInt32(i * 4, true) / 2147483648;
    }
  } else {
    return decodeFail('audio.unsupportedBits', [`${bits}`]);
  }

  const result: WavSamplesResult = {
    ok: true,
    errorKey: '',
    errorArgs: [],
    samples: out
  };
  return result;
}