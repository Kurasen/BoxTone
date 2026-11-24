import { taskpool } from '@kit.ArkTS';
import { decodeWavSamples, parseWavHeader, WavFormat, WavParseResult, WavSamplesResult } from './WavCodec';
import { WavTaskResult } from './WavDecodeTask';

/**
 * rawfile 内置音效的 TaskPool 解码入口。
 *
 * 与 WavDecodeTask 的区别：那边从文件路径读，这边直接接收已经读进内存的字节，
 * 用于 resourceManager 才能访问的 rawfile 资源。
 *
 * 内置音效里最长的一条有 18.8 秒（31 万个采样点），在主线程逐点转换会明显掉帧，
 * 所以解码统一放到工作线程，主线程只负责把字节递进来、把 Float32 接回去。
 *
 * 注意：@Concurrent 函数内只能引用导入变量和局部变量，失败返回必须就地表构造，
 * 不能抽成同文件的普通函数，否则 es2abc 会报 10705000。
 */
@Concurrent
export function decodeWavBufferInTask(buffer: ArrayBuffer): WavTaskResult {
  let parsed: WavParseResult;
  try {
    parsed = parseWavHeader(buffer);
  } catch (error) {
    const fallback: WavFormat = {
      audioFormat: 1,
      channels: 1,
      sampleRate: 44100,
      bitsPerSample: 16,
      dataOffset: 0,
      dataSize: 0,
      totalFrames: 0
    };
    const badHeader: WavTaskResult = {
      ok: false,
      errorKey: 'audio.wavBadHeader',
      errorArgs: [],
      sampleRate: fallback.sampleRate,
      channels: fallback.channels,
      bitsPerSample: fallback.bitsPerSample,
      audioFormat: fallback.audioFormat,
      totalFrames: 0,
      frameCount: 0,
      truncated: false,
      frames: new ArrayBuffer(0)
    };
    return badHeader;
  }

  const format: WavFormat = parsed.format;
  if (!parsed.ok || format.dataSize <= 0) {
    const failed: WavTaskResult = {
      ok: false,
      errorKey: parsed.ok ? 'audio.wavNoData' : parsed.errorKey,
      errorArgs: parsed.ok ? [] : parsed.errorArgs,
      sampleRate: format.sampleRate,
      channels: format.channels,
      bitsPerSample: format.bitsPerSample,
      audioFormat: format.audioFormat,
      totalFrames: format.totalFrames,
      frameCount: 0,
      truncated: false,
      frames: new ArrayBuffer(0)
    };
    return failed;
  }

  // 只取 data 段：头部字节不是采样，混进去会在开头多出一下爆音
  const available: number = Math.max(0, buffer.byteLength - format.dataOffset);
  const wantedBytes: number = Math.min(format.dataSize, available);
  const dataBuffer: ArrayBuffer = buffer.slice(format.dataOffset, format.dataOffset + wantedBytes);

  const decoded: WavSamplesResult = decodeWavSamples(dataBuffer, format);
  if (!decoded.ok) {
    const decodeFailed: WavTaskResult = {
      ok: false,
      errorKey: decoded.errorKey,
      errorArgs: decoded.errorArgs,
      sampleRate: format.sampleRate,
      channels: format.channels,
      bitsPerSample: format.bitsPerSample,
      audioFormat: format.audioFormat,
      totalFrames: format.totalFrames,
      frameCount: 0,
      truncated: false,
      frames: new ArrayBuffer(0)
    };
    return decodeFailed;
  }

  const frameCount: number = Math.floor(decoded.samples.length / format.channels);
  const result: WavTaskResult = {
    ok: true,
    errorKey: '',
    errorArgs: [],
    sampleRate: format.sampleRate,
    channels: format.channels,
    bitsPerSample: format.bitsPerSample,
    audioFormat: format.audioFormat,
    totalFrames: format.totalFrames,
    frameCount: frameCount,
    truncated: false,
    frames: decoded.samples.buffer as ArrayBuffer
  };
  return result;
}

export class BuiltinDecodeTaskService {
  /** TaskPool 不可用时由调用方捕获异常，回退主线程同步解码 */
  public static async decodeAsync(buffer: ArrayBuffer): Promise<WavTaskResult> {
    const result: Object = await taskpool.execute(decodeWavBufferInTask, buffer);
    return result as WavTaskResult;
  }
}
