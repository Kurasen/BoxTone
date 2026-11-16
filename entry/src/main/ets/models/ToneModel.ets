/**
 * 音频与音效模型
 */

/** 解码后的 PCM 数据，frames 为交织排列（interleaved） */
export interface PcmAudio {
  sampleRate: number;
  channels: number;
  frameCount: number;
  /** 长度 = frameCount * channels，取值范围 [-1, 1] */
  frames: Float32Array;
}

/** 导入的源音频描述 */
export interface SourceAudio {
  /** 沙箱内路径 */
  path: string;
  /** 原始文件名 */
  name: string;
  /** 容器/编码格式，如 WAV / RAW */
  format: string;
  sampleRate: number;
  channels: number;
  durationMs: number;
  /** 是否因超过分析上限而被截断 */
  truncated: boolean;
  pcm: PcmAudio;
}

/** 转换参数 */
export interface ConvertOptions {
  /** 起始位置（毫秒，相对源音频） */
  startMs: number;
  /** 目标时长（毫秒） */
  durationMs: number;
  /** 增益，单位 dB */
  gainDb: number;
  /** 淡入时长（毫秒） */
  fadeInMs: number;
  /** 淡出时长（毫秒） */
  fadeOutMs: number;
  /** 是否先做峰值归一化 */
  normalize: boolean;
}

/** 转换结果 */
export interface ConvertResult {
  /** 无文件头的 16bit 小端 PCM */
  buffer: ArrayBuffer;
  sampleCount: number;
  byteLength: number;
  durationMs: number;
  /** 峰值电平，0~1 */
  peak: number;
  /** 是否因超长被截断 */
  trimmed: boolean;
}

/** 音效库条目 */
export interface ToneEntry {
  id: string;
  name: string;
  fileName: string;
  durationMs: number;
  byteLength: number;
  createdAt: number;
  sourceName: string;
}

/** 音效库索引文件结构 */
export interface ToneIndex {
  version: number;
  items: ToneEntry[];
}

/** 波形峰值缓存 */
export interface WavePeaks {
  peaks: number[];
  durationMs: number;
}

/** 内置合成音色定义 */
export interface SynthPreset {
  id: string;
  name: string;
  desc: string;
}

export function createEmptyTone(): ToneEntry {
  const entry: ToneEntry = {
    id: '',
    name: '',
    fileName: '',
    durationMs: 0,
    byteLength: 0,
    createdAt: 0,
    sourceName: ''
  };
  return entry;
}
