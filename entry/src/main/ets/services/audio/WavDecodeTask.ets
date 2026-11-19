import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { decodeWavSamples, parseWavHeader, WavFormat, WavParseResult, WavSamplesResult } from './WavCodec';

/**
 * WAV 解码的 TaskPool 结果。
 * 只带回声明的元数据与 Float32 采样，主线程据此组装 SourceAudio。
 */
export interface WavTaskResult {
  ok: boolean;
  errorKey: string;
  errorArgs: string[];
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  audioFormat: number;
  totalFrames: number;
  frameCount: number;
  truncated: boolean;
  /** Float32 交错采样的 ArrayBuffer */
  frames: ArrayBuffer;
}

/**
 * 工作线程入口：读文件、解析头、解码样本。
 *
 * 5 分钟 16bit 立体声有 2600 万个采样点，放在主线程逐点转换会冻结 UI 数秒，
 * 所以整段读取与解码都搬到这里。文件打开失败直接抛出，由主线程回退同步路径，
 * 那里能拿到文件名拼出准确的错误提示。
 */
@Concurrent
export function decodeWavInTask(path: string, maxSeconds: number): WavTaskResult {
  const headerScanLimit: number = 1024 * 1024;
  const stat: fs.Stat = fs.statSync(path);
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const headerSize: number = Math.min(stat.size, headerScanLimit);
    const headerBuffer: ArrayBuffer = new ArrayBuffer(headerSize);
    fs.readSync(file.fd, headerBuffer, { offset: 0, length: headerSize });

    const parsed: WavParseResult = parseWavHeader(headerBuffer);
    if (!parsed.ok) {
      const failed: WavTaskResult = {
        ok: false,
        errorKey: parsed.errorKey,
        errorArgs: parsed.errorArgs,
        sampleRate: 0,
        channels: 0,
        bitsPerSample: 0,
        audioFormat: 0,
        totalFrames: 0,
        frameCount: 0,
        truncated: false,
        frames: new ArrayBuffer(0)
      };
      return failed;
    }

    const format: WavFormat = parsed.format;
    if (format.dataSize <= 0) {
      const empty: WavTaskResult = {
        ok: false,
        errorKey: 'audio.wavNoData',
        errorArgs: [],
        sampleRate: format.sampleRate,
        channels: format.channels,
        bitsPerSample: format.bitsPerSample,
        audioFormat: format.audioFormat,
        totalFrames: 0,
        frameCount: 0,
        truncated: false,
        frames: new ArrayBuffer(0)
      };
      return empty;
    }

    const seconds: number = maxSeconds > 0 ? maxSeconds : 60;
    const maxFrames: number = Math.floor(format.sampleRate * seconds);
    const wantedFrames: number = Math.min(format.totalFrames, maxFrames);
    const frameBytes: number = format.channels * format.bitsPerSample / 8;
    const wantedBytes: number = Math.min(format.dataSize, wantedFrames * frameBytes);

    const dataBuffer: ArrayBuffer = new ArrayBuffer(wantedBytes);
    fs.readSync(file.fd, dataBuffer, { offset: format.dataOffset, length: wantedBytes });

    const decoded: WavSamplesResult = decodeWavSamples(dataBuffer, format);
    if (!decoded.ok) {
      const failed: WavTaskResult = {
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
      return failed;
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
      truncated: format.totalFrames > maxFrames,
      frames: decoded.samples.buffer as ArrayBuffer
    };
    return result;
  } finally {
    fs.closeSync(file);
  }
}

/** TaskPool 不可用时的调用方会捕获异常并回退到主线程同步解码 */
export class WavDecodeTaskService {
  public static async decodeAsync(path: string, maxSeconds: number): Promise<WavTaskResult> {
    const result: Object = await taskpool.execute(decodeWavInTask, path, maxSeconds);
    return result as WavTaskResult;
  }
}