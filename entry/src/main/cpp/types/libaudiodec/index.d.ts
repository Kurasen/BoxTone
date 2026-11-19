/**
 * 原生音频解码：把 MP3 / AAC / M4A / FLAC / OGG / AMR 等交给系统解码器解成 PCM。
 *
 * 解码在原生线程池里执行并返回 Promise，不阻塞 UI 线程。
 */
export interface DecodedAudio {
  /** 是否解码成功 */
  ok: boolean;
  /** 失败原因（ok 为 false 时有效） */
  error?: string;
  /** 失败发生在哪一步：open/source/track/codec/format/configure/prepare/start/demuxer/decode/done */
  stage: string;
  /** 交错排列的 [-1, 1] 浮点采样，长度 = frameCount * channels */
  frames: Float32Array;
  sampleRate: number;
  channels: number;
  /** 每个声道的采样帧数 */
  frameCount: number;
  /** 是否因为超过时长上限被截断 */
  truncated: boolean;
  /** 是否被 cancelDecode() 取消；为 true 时 ok 一定为 false */
  cancelled: boolean;
}

/** 当前解码进度 */
export interface DecodeProgress {
  /** 是否有解码任务在跑 */
  active: boolean;
  /** 已解码采样占目标采样的比例，0~1 */
  progress: number;
  /** 解码已耗时（毫秒） */
  elapsedMs: number;
}

export interface AudioProbe {
  ok: boolean;
  error?: string;
  /** open/source/track/done */
  stage: string;
  /** 例如 audio/mpeg、audio/mp4a-latm */
  mime: string;
  sampleRate: number;
  channels: number;
  durationMs: number;
}

/**
 * 轻量探测：只解封装、读轨道信息，不做解码。
 * 用于在进入解码前把格式写进日志，也用于给出更明确的失败原因。
 */
export const probeAudio: (path: string) => AudioProbe;

/**
 * 解码音频文件。
 * @param path 应用沙箱内的绝对路径
 * @param maxSeconds 最多解码多少秒，超出部分丢弃
 */
export const decodeAudio: (path: string, maxSeconds: number) => Promise<DecodedAudio>;

/** 查询当前解码进度，用于导入遮罩显示百分比和预计剩余时间 */
export const getDecodeProgress: () => DecodeProgress;

/** 取消当前解码，解码循环会在几十毫秒内退出 */
export const cancelDecode: () => void;
