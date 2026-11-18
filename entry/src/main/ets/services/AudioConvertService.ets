import { ToneSpec } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { ConvertOptions, ConvertResult, PcmAudio, WavePeaks } from '../models/ToneModel';

const MODULE: string = 'AudioConvert';

/** 单边插值半径，越大质量越高、耗时越长 */
const TAPS: number = 12;
/**
 * 截止频率余量：理想核的截止点正好压在 8350Hz 上，过渡带一半落在带内，
 * 导致 10kHz 处只剩 -57dB 抑制。留 10% 余量（截止 7515Hz）后提升到 -78dB，
 * 而 6kHz 以下完全无衰减，对提示音内容（几乎都在 5kHz 内）零代价。
 */
const CUTOFF_MARGIN: number = 0.9;
/** sin(πx) 查表精度 */
const SIN_TABLE_SIZE: number = 2048;
/** Blackman 窗查表精度 */
const WINDOW_TABLE_SIZE: number = 1024;

/**
 * 重采样使用 Blackman 窗加权的 sinc 插值：
 * 通带平坦、镜像抑制约 54dB，保证 44.1k/48k 素材降到 16700Hz 不产生可闻混叠。
 * 为控制单次转换耗时，三角函数改为查表插值（误差 < 1e-7）。
 */
function buildSinTable(): Float32Array {
  const table: Float32Array = new Float32Array(SIN_TABLE_SIZE + 1);
  for (let i = 0; i <= SIN_TABLE_SIZE; i++) {
    table[i] = Math.sin(Math.PI * i / SIN_TABLE_SIZE);
  }
  return table;
}

function buildWindowTable(): Float32Array {
  const table: Float32Array = new Float32Array(WINDOW_TABLE_SIZE + 1);
  for (let i = 0; i <= WINDOW_TABLE_SIZE; i++) {
    const u: number = i / WINDOW_TABLE_SIZE;
    table[i] = 0.42 + 0.5 * Math.cos(Math.PI * u) + 0.08 * Math.cos(2 * Math.PI * u);
  }
  return table;
}

const SIN_TABLE: Float32Array = buildSinTable();
const WINDOW_TABLE: Float32Array = buildWindowTable();

/** sin(πx)，利用周期性把参数折叠到 [0, π] */
function sinPi(x: number): number {
  const base: number = Math.floor(x);
  const fraction: number = x - base;
  const position: number = fraction * SIN_TABLE_SIZE;
  const index: number = Math.floor(position);
  const weight: number = position - index;
  const low: number = SIN_TABLE[index];
  const high: number = index + 1 <= SIN_TABLE_SIZE ? SIN_TABLE[index + 1] : 0;
  const value: number = low * (1 - weight) + high * weight;
  return base % 2 === 0 ? value : -value;
}

function sinc(x: number): number {
  if (Math.abs(x) < 1e-9) {
    return 1;
  }
  return sinPi(x) / (Math.PI * x);
}

/** Blackman 窗，u = |距离| / 半径 ∈ [0,1]，中心 1 边缘 0 */
function blackmanAt(u: number): number {
  if (u >= 1) {
    return 0;
  }
  const position: number = u * WINDOW_TABLE_SIZE;
  const index: number = Math.floor(position);
  const weight: number = position - index;
  const low: number = WINDOW_TABLE[index];
  const high: number = index + 1 <= WINDOW_TABLE_SIZE ? WINDOW_TABLE[index + 1] : 0;
  return low * (1 - weight) + high * weight;
}

/** 相位核数量上限：非标准采样率下周期可能很长，超了就退回逐点计算 */
const MAX_PHASES: number = 512;

/**
 * 重采样相位核。
 * sinc 窗的取值只跟"当前输出点落在两个输入帧之间的位置"有关，
 * 而该位置按固定周期重复，所以把每个相位的抽头权重预先算好，
 * 运行时只剩乘加，不再逐抽头算 sinc/Blackman。
 */
class PhaseKernel {
  phaseCount: number;
  tapCount: number;
  minStart: number;
  weights: Float32Array;
  sums: Float32Array;

  constructor(phaseCount: number, tapCount: number, minStart: number,
    weights: Float32Array, sums: Float32Array) {
    this.phaseCount = phaseCount;
    this.tapCount = tapCount;
    this.minStart = minStart;
    this.weights = weights;
    this.sums = sums;
  }
}

function gcd(a: number, b: number): number {
  let x: number = a;
  let y: number = b;
  while (y !== 0) {
    const rest: number = x % y;
    x = y;
    y = rest;
  }
  return x;
}

function buildPhaseKernel(srcRate: number, dstRate: number): PhaseKernel {
  const ratio: number = dstRate / srcRate;
  const scale: number = (ratio < 1 ? ratio : 1) * CUTOFF_MARGIN;
  const halfWidth: number = TAPS / scale;
  const divisor: number = Math.max(1, gcd(Math.round(srcRate), Math.round(dstRate)));
  const dstFrames: number = Math.round(dstRate);
  const phaseCount: number = Math.max(1, Math.round(dstFrames / divisor));

  let minStart: number = 0;
  let maxStart: number = 0;
  for (let p = 0; p < phaseCount; p++) {
    const frac: number = p * divisor / dstFrames;
    const start: number = Math.ceil(frac - halfWidth);
    const end: number = Math.floor(frac + halfWidth);
    if (p === 0 || start < minStart) {
      minStart = start;
    }
    if (p === 0 || end > maxStart) {
      maxStart = end;
    }
  }

  const tapCount: number = maxStart - minStart + 1;
  const weights: Float32Array = new Float32Array(phaseCount * tapCount);
  const sums: Float32Array = new Float32Array(phaseCount);
  for (let p = 0; p < phaseCount; p++) {
    const frac: number = p * divisor / dstFrames;
    const start: number = Math.ceil(frac - halfWidth);
    const end: number = Math.floor(frac + halfWidth);
    let sum: number = 0;
    for (let offset = start; offset <= end; offset++) {
      const distance: number = frac - offset;
      const u: number = Math.abs(distance) / halfWidth;
      if (u >= 1) {
        continue;
      }
      const weight: number = scale * sinc(scale * distance) * blackmanAt(u);
      weights[p * tapCount + (offset - minStart)] = weight;
      sum += weight;
    }
    sums[p] = sum;
  }
  return new PhaseKernel(phaseCount, tapCount, minStart, weights, sums);
}

/**
 * 音频格式转换核心
 *
 * 处理链：下混单声道 → 时间裁剪 → 峰值归一化 → 窗口化 sinc 重采样(→16700Hz)
 *        → 增益与淡入淡出 → 有符号 16bit 小端量化
 */
export class AudioConvertService {
  private static kernels: Map<string, PhaseKernel> = new Map<string, PhaseKernel>();
  /**
   * 执行转换
   * @throws Error 源数据为空时抛出
   */
  public static convert(source: PcmAudio, options: ConvertOptions): ConvertResult {
    if (source.frameCount === 0) {
      throw new Error(I18n.t('audio.emptySource'));
    }
    const started: number = Date.now();

    // 先按时间窗口裁出源帧再下混：素材可能有几十秒，
    // 之前每点一次试听/生成都要把整段素材下混一遍，5 秒音效也要 4 秒才出结果
    const startFrame: number = Math.max(0, Math.round(options.startMs * source.sampleRate / 1000));
    const wantFrames: number = Math.max(1, Math.round(options.durationMs * source.sampleRate / 1000));
    const available: number = Math.max(0, source.frameCount - startFrame);
    const frameCount: number = Math.min(wantFrames, available);
    const mono: Float32Array = AudioConvertService.toMonoRange(source, startFrame,
      frameCount > 0 ? frameCount : 1);

    const normalized: Float32Array = options.normalize
      ? AudioConvertService.normalize(mono) : mono;

    const resampled: Float32Array = AudioConvertService.resample(normalized,
      source.sampleRate, ToneSpec.SAMPLE_RATE);

    const shaped: Float32Array = AudioConvertService.applyGainAndFade(resampled,
      options.gainDb, options.fadeInMs, options.fadeOutMs);

    // 硬性限制规格上限：按字节上限换算帧数，避免时长与字节两个口径打架
    const maxFrames: number = Math.floor(ToneSpec.MAX_BYTES / ToneSpec.BYTES_PER_FRAME);
    let finalSamples: Float32Array = shaped;
    let trimmed: boolean = false;
    if (shaped.length > maxFrames) {
      finalSamples = shaped.slice(0, maxFrames);
      trimmed = true;
    }

    const buffer: ArrayBuffer = AudioConvertService.encodeInt16(finalSamples);
    let peak: number = 0;
    for (let i = 0; i < finalSamples.length; i++) {
      const abs: number = Math.abs(finalSamples[i]);
      if (abs > peak) {
        peak = abs;
      }
    }

    const durationMs: number = finalSamples.length * 1000 / ToneSpec.SAMPLE_RATE;
    const cost: number = Date.now() - started;
    Logger.info(MODULE, `转换完成 ${FormatUtils.seconds(durationMs)} / ${buffer.byteLength} 字节 / 耗时 ${cost}ms`);

    const result: ConvertResult = {
      buffer: buffer,
      sampleCount: finalSamples.length,
      byteLength: buffer.byteLength,
      durationMs: durationMs,
      peak: Math.min(1, peak),
      trimmed: trimmed
    };
    return result;
  }

  /** 交织多声道 → 单声道（等权平均下混） */
  public static toMono(source: PcmAudio): Float32Array {
    return AudioConvertService.toMonoRange(source, 0, source.frameCount);
  }

  /** 只对 [start, start+count) 这段帧下混，避免整段素材参与计算 */
  private static toMonoRange(source: PcmAudio, start: number, count: number): Float32Array {
    const channels: number = source.channels;
    const frames: Float32Array = source.frames;
    const safeStart: number = Math.max(0, Math.min(start, source.frameCount - 1));
    const safeCount: number = Math.max(1, Math.min(count, source.frameCount - safeStart));
    const mono: Float32Array = new Float32Array(safeCount);
    if (channels <= 1) {
      for (let i = 0; i < safeCount; i++) {
        mono[i] = frames[safeStart + i];
      }
      return mono;
    }
    const gain: number = 1 / channels;
    for (let i = 0; i < safeCount; i++) {
      let sum: number = 0;
      const base: number = (safeStart + i) * channels;
      for (let c = 0; c < channels; c++) {
        sum += frames[base + c];
      }
      mono[i] = sum * gain;
    }
    return mono;
  }

  /** 峰值归一化到 -0.2dBFS，避免写入后削顶 */
  private static normalize(input: Float32Array): Float32Array {
    let peak: number = 0;
    for (let i = 0; i < input.length; i++) {
      const abs: number = Math.abs(input[i]);
      if (abs > peak) {
        peak = abs;
      }
    }
    if (peak <= 0.0001) {
      return input;
    }
    const scale: number = 0.978 / peak;
    const out: Float32Array = new Float32Array(input.length);
    for (let i = 0; i < input.length; i++) {
      out[i] = input[i] * scale;
    }
    return out;
  }

  /** 窗口化 sinc 重采样；降采样时同步收紧截止频率以抑制混叠 */
  public static resample(input: Float32Array, srcRate: number, dstRate: number): Float32Array {
    if (srcRate === dstRate || input.length === 0) {
      return input;
    }
    const ratio: number = dstRate / srcRate;
    const outLength: number = Math.max(1, Math.round(input.length * ratio));
    const out: Float32Array = new Float32Array(outLength);
    const last: number = input.length - 1;
    const divisor: number = Math.max(1, gcd(Math.round(srcRate), Math.round(dstRate)));
    const dstFrames: number = Math.round(dstRate);
    const phaseCount: number = Math.max(1, Math.round(dstFrames / divisor));
    if (phaseCount > MAX_PHASES) {
      AudioConvertService.resampleDirect(input, srcRate, dstRate, out, ratio);
      return out;
    }

    const kernel: PhaseKernel = AudioConvertService.kernelFor(srcRate, dstRate);
    const step: number = Math.round(srcRate) / divisor;
    for (let i = 0; i < outLength; i++) {
      const t: number = i / ratio;
      const base: number = Math.floor(t);
      const phase: number = (i * step) % kernel.phaseCount;
      const row: number = phase * kernel.tapCount;
      let acc: number = 0;
      for (let j = 0; j < kernel.tapCount; j++) {
        const weight: number = kernel.weights[row + j];
        if (weight === 0) {
          continue;
        }
        let k: number = base + kernel.minStart + j;
        if (k < 0) {
          k = 0;
        } else if (k > last) {
          k = last;
        }
        acc += input[k] * weight;
      }
      out[i] = acc / kernel.sums[phase];
    }
    return out;
  }

  private static kernelFor(srcRate: number, dstRate: number): PhaseKernel {
    const key: string = `${Math.round(srcRate)}_${Math.round(dstRate)}`;
    const cached: PhaseKernel | undefined = AudioConvertService.kernels.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const kernel: PhaseKernel = buildPhaseKernel(srcRate, dstRate);
    AudioConvertService.kernels.set(key, kernel);
    return kernel;
  }

  /** 非标准采样率（相位过长）时的逐点实现，结果与相位核一致 */
  private static resampleDirect(input: Float32Array, srcRate: number, dstRate: number,
    out: Float32Array, ratio: number): void {
    const scale: number = (ratio < 1 ? ratio : 1) * CUTOFF_MARGIN;
    const halfWidth: number = TAPS / scale;
    const last: number = input.length - 1;
    for (let i = 0; i < out.length; i++) {
      const t: number = i / ratio;
      const lo: number = Math.ceil(t - halfWidth);
      const hi: number = Math.floor(t + halfWidth);
      let acc: number = 0;
      let weightSum: number = 0;
      for (let k = lo; k <= hi; k++) {
        const distance: number = t - k;
        const normalizedDistance: number = Math.abs(distance) / halfWidth;
        if (normalizedDistance >= 1) {
          continue;
        }
        const kernel: number = scale * sinc(scale * distance) * blackmanAt(normalizedDistance);
        const index: number = k < 0 ? 0 : (k > last ? last : k);
        acc += input[index] * kernel;
        weightSum += kernel;
      }
      out[i] = weightSum !== 0 ? acc / weightSum : 0;
    }
  }

  /** 增益与首尾淡入淡出（半余弦包络，听感更自然） */
  private static applyGainAndFade(input: Float32Array, gainDb: number,
    fadeInMs: number, fadeOutMs: number): Float32Array {
    const out: Float32Array = new Float32Array(input.length);
    const linearGain: number = Math.pow(10, gainDb / 20);
    const fadeInFrames: number = Math.round(fadeInMs * ToneSpec.SAMPLE_RATE / 1000);
    const fadeOutFrames: number = Math.round(fadeOutMs * ToneSpec.SAMPLE_RATE / 1000);
    const total: number = input.length;

    for (let i = 0; i < total; i++) {
      let env: number = 1;
      if (fadeInFrames > 0 && i < fadeInFrames) {
        env = 0.5 - 0.5 * Math.cos(Math.PI * i / fadeInFrames);
      }
      const fromEnd: number = total - 1 - i;
      if (fadeOutFrames > 0 && fromEnd < fadeOutFrames) {
        const tail: number = 0.5 - 0.5 * Math.cos(Math.PI * fromEnd / fadeOutFrames);
        env = Math.min(env, tail);
      }
      let value: number = input[i] * linearGain * env;
      if (value > 1) {
        value = 1;
      } else if (value < -1) {
        value = -1;
      }
      out[i] = value;
    }
    return out;
  }

  /** 量化并写为小端 16bit，无文件头 */
  public static encodeInt16(samples: Float32Array): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(samples.length * 2);
    const view: DataView = new DataView(buffer);
    for (let i = 0; i < samples.length; i++) {
      let value: number = samples[i];
      if (value > 1) {
        value = 1;
      } else if (value < -1) {
        value = -1;
      }
      let quantized: number = value < 0 ? Math.round(value * 32768) : Math.round(value * 32767);
      if (quantized > 32767) {
        quantized = 32767;
      } else if (quantized < -32768) {
        quantized = -32768;
      }
      view.setInt16(i * 2, quantized, true);
    }
    return buffer;
  }

  /** 解码无文件头的 16bit 小端 PCM */
  public static decodeInt16(buffer: ArrayBuffer): Float32Array {
    const view: DataView = new DataView(buffer);
    const count: number = Math.floor(buffer.byteLength / 2);
    const out: Float32Array = new Float32Array(count);
    for (let i = 0; i < count; i++) {
      out[i] = view.getInt16(i * 2, true) / 32768;
    }
    return out;
  }

  /** 生成波形预览峰值，buckets 为柱数 */
  public static buildPeaks(source: PcmAudio, buckets: number): WavePeaks {
    const mono: Float32Array = AudioConvertService.toMono(source);
    const count: number = Math.min(buckets, Math.max(1, mono.length));
    const peaks: number[] = [];
    if (mono.length === 0) {
      const empty: WavePeaks = { peaks: peaks, durationMs: 0 };
      return empty;
    }
    const step: number = mono.length / count;
    let globalMax: number = 0.0001;
    for (let b = 0; b < count; b++) {
      const start: number = Math.floor(b * step);
      const end: number = Math.min(mono.length, Math.floor((b + 1) * step));
      let localMax: number = 0;
      for (let i = start; i < end; i++) {
        const abs: number = Math.abs(mono[i]);
        if (abs > localMax) {
          localMax = abs;
        }
      }
      peaks.push(localMax);
      if (localMax > globalMax) {
        globalMax = localMax;
      }
    }
    // 归一化，并取平方根让低电平细节可见
    for (let b = 0; b < peaks.length; b++) {
      let ratio: number = peaks[b] / globalMax;
      if (ratio > 1) {
        ratio = 1;
      }
      peaks[b] = Math.sqrt(ratio);
    }
    const result: WavePeaks = {
      peaks: peaks,
      durationMs: mono.length * 1000 / source.sampleRate
    };
    return result;
  }

  /** 按目标规格换算字节数，用于 UI 预览 */
  public static estimateBytes(durationMs: number): number {
    return Math.round(durationMs * ToneSpec.BYTES_PER_SECOND / 1000);
  }
}
