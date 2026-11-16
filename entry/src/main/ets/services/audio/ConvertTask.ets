import { taskpool } from '@kit.ArkTS';
import { I18n } from '../../common/i18n/I18n';
import { Logger } from '../../common/utils/Logger';
import { ConvertOptions, ConvertResult, PcmAudio } from '../../models/ToneModel';
import { AudioConvertService } from '../AudioConvertService';

const MODULE: string = 'AudioConvertTask';

/** TaskPool 入参：只带裁剪后的交织采样，避免把整段素材复制进工作线程 */
export interface ConvertTaskRequest {
  frames: ArrayBuffer;
  sampleRate: number;
  channels: number;
  frameCount: number;
  options: ConvertOptions;
}

/**
 * 工作线程入口。
 * 必须单独成模块：@Concurrent 函数只能引用导入变量或局部变量，
 * 不能直接引用同文件里定义的类。
 */
@Concurrent
export function convertInTask(request: ConvertTaskRequest): ConvertResult {
  const pcm: PcmAudio = {
    sampleRate: request.sampleRate,
    channels: request.channels,
    frameCount: request.frameCount,
    frames: new Float32Array(request.frames)
  };
  return AudioConvertService.convert(pcm, request.options);
}

/**
 * 异步转换入口：把重采样放到 TaskPool，避免主线程被 1 秒以上的计算冻住。
 * TaskPool 不可用时回退同步实现，结果与同步路径一致。
 */
export class AudioConvertTaskService {
  public static async convertAsync(source: PcmAudio, options: ConvertOptions): Promise<ConvertResult> {
    if (source.frameCount === 0) {
      throw new Error(I18n.t('audio.emptySource'));
    }
    const window: Float32Array = AudioConvertTaskService.windowOf(source, options);
    const channels: number = source.channels > 0 ? source.channels : 1;
    const request: ConvertTaskRequest = {
      frames: window.buffer as ArrayBuffer,
      sampleRate: source.sampleRate,
      channels: source.channels,
      frameCount: Math.floor(window.length / channels),
      options: {
        startMs: 0,
        durationMs: options.durationMs,
        gainDb: options.gainDb,
        fadeInMs: options.fadeInMs,
        fadeOutMs: options.fadeOutMs,
        normalize: options.normalize
      }
    };
    try {
      const result: Object = await taskpool.execute(convertInTask, request);
      return result as ConvertResult;
    } catch (error) {
      Logger.warn(MODULE, `TaskPool 转换失败，回退主线程：${(error as Error).message}`);
      return AudioConvertService.convert(source, options);
    }
  }

  /** 按转换参数裁出需要的交织帧，供工作线程使用 */
  private static windowOf(source: PcmAudio, options: ConvertOptions): Float32Array {
    const channels: number = source.channels > 0 ? source.channels : 1;
    const startFrame: number = Math.max(0,
      Math.round(options.startMs * source.sampleRate / 1000));
    const safeStart: number = Math.min(startFrame, source.frameCount - 1);
    const wantFrames: number = Math.max(1, Math.round(options.durationMs * source.sampleRate / 1000));
    const available: number = Math.max(1, source.frameCount - safeStart);
    const count: number = Math.min(wantFrames, available);
    const from: number = safeStart * channels;
    const to: number = Math.min(source.frames.length, (safeStart + count) * channels);
    const window: Float32Array = source.frames.slice(from, to);
    if (window.length === 0) {
      return new Float32Array(channels);
    }
    return window;
  }
}
