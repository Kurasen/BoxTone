import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ToneSpec } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';
import { AudioConvertService } from './AudioConvertService';

const MODULE: string = 'AudioPlay';
/** 预览渲染采样率：把 16700Hz 音效升采样到此值播放，音高与写入耳机后完全一致 */
const PREVIEW_RATE: number = 48000;
/** 单次写入渲染器的字节数（约 0.34 秒），避免反复复制整个剩余缓冲 */
const WRITE_CHUNK: number = 32768;
/** 试听结束后保留渲染器的时间：连续点几次不再重复建流，久不播则释放音频焦点 */
const RENDERER_IDLE_MS: number = 8000;

/**
 * 试听服务
 * - 源文件：AVPlayer 直接播放
 * - 生成音效：AudioRenderer 以 48kHz 渲染（由 16700Hz 精确升采样）
 *
 * 渲染器复用：每次 createAudioRenderer + start 要几十到上百毫秒，
 * 连续点试听会明显感到延迟，因此实例保留到空闲一段时间后再释放。
 */
export class AudioPlayService {
  private static player: media.AVPlayer | undefined = undefined;
  private static playerFile: fs.File | undefined = undefined;
  private static renderer: audio.AudioRenderer | undefined = undefined;
  private static playing: boolean = false;
  /** 播放代号：新的播放/停止会让上一轮写入循环自行退出 */
  private static generation: number = 0;
  private static idleTimer: number = -1;
  /** 上一次升采样用的 PCM 与其 48kHz 结果：同一段音效重复试听不再重采样 */
  private static previewSource: ArrayBuffer | undefined = undefined;
  private static previewOutput: ArrayBuffer | undefined = undefined;

  public static isPlaying(): boolean {
    return AudioPlayService.playing;
  }

  public static isRendererReady(): boolean {
    return AudioPlayService.renderer !== undefined;
  }

  /** 播放音频文件 */
  public static async playFile(path: string, onEnd: () => void): Promise<void> {
    await AudioPlayService.stop();
    AudioPlayService.playing = true;
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const player: media.AVPlayer = await media.createAVPlayer();
      AudioPlayService.player = player;
      AudioPlayService.playerFile = file;

      player.on('stateChange', (state: media.AVPlayerState) => {
        if (state === 'initialized') {
          player.prepare().catch((error: BusinessError) => {
            Logger.exception(MODULE, 'prepare 失败', error);
          });
        } else if (state === 'prepared') {
          player.play().catch((error: BusinessError) => {
            Logger.exception(MODULE, '播放失败', error);
          });
        } else if (state === 'completed') {
          AudioPlayService.playing = false;
          onEnd();
        }
      });
      player.on('error', (error: BusinessError) => {
        Logger.exception(MODULE, 'AVPlayer 异常', error);
        AudioPlayService.playing = false;
        onEnd();
      });

      player.url = `fd://${file.fd}`;
      Logger.info(MODULE, `开始播放源文件 ${path}`);
    } catch (error) {
      AudioPlayService.playing = false;
      Logger.exception(MODULE, '打开音频失败', error as BusinessError);
      throw error as Error;
    }
  }

  /** 等待指定毫秒，用于暂缓收尾或让渲染缓冲先排空 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 播放生成的原始波形
   * @param buffer 无文件头 16bit PCM（16700Hz 单声道）
   */
  public static async playRaw(buffer: ArrayBuffer, onEnd: () => void): Promise<void> {
    await AudioPlayService.stop();
    const token: number = await AudioPlayService.beginPlayback();
    try {
      let output: ArrayBuffer;
      if (AudioPlayService.previewSource === buffer && AudioPlayService.previewOutput !== undefined) {
        output = AudioPlayService.previewOutput;
      } else {
        const pcm: Float32Array = AudioConvertService.decodeInt16(buffer);
        const upsampled: Float32Array =
          AudioConvertService.resample(pcm, ToneSpec.SAMPLE_RATE, PREVIEW_RATE);
        output = AudioConvertService.encodeInt16(upsampled);
        AudioPlayService.previewSource = buffer;
        AudioPlayService.previewOutput = output;
      }
      if (token !== AudioPlayService.generation) {
        return;
      }

      const renderer: audio.AudioRenderer = await AudioPlayService.ensureRenderer();
      if (token !== AudioPlayService.generation) {
        return;
      }
      await renderer.start();
      AudioPlayService.playing = true;
      const startedAt: number = Date.now();

      let written: number = 0;
      let stalls: number = 0;
      let restarted: boolean = false;
      const total: number = output.byteLength;
      while (written < total && token === AudioPlayService.generation) {
        const end: number = Math.min(written + WRITE_CHUNK, total);
        const chunk: ArrayBuffer = output.slice(written, end);
        const size: number = await renderer.write(chunk);
        if (size <= 0) {
          // 渲染缓冲满时 write 会先返回 0，直接 break 会把后半段吃掉
          stalls++;
          if (stalls === 20 && !restarted) {
            // 渲染器被上一轮遗留的 stop 停掉时 write 会一直返回 0，这里自愈一次
            restarted = true;
            try {
              await renderer.start();
              Logger.warn(MODULE, '盒音渲染器意外停止，已重新启动');
            } catch (error) {
              Logger.warn(MODULE, `重启渲染器失败 code=${(error as BusinessError).code}`);
            }
          }
          if (stalls > 50) {
            break;
          }
          await AudioPlayService.delay(10);
          continue;
        }
        stalls = 0;
        written += size;
      }
      if (token !== AudioPlayService.generation) {
        return;
      }
      if (written < total) {
        Logger.warn(MODULE, `盒音试听未写完 ${written}/${total} 字节`);
      } else {
        Logger.info(MODULE, `盒音试听写入 ${written}/${total} 字节`);
      }
      /**
       * write 只是把数据塞进渲染缓冲，立刻 stop 会把还没播完的尾巴切掉。
       * write 本身可能已经阻塞到接近播完，所以只补差值 + 缓冲余量。
       */
      const durationMs: number = Math.round(total / (PREVIEW_RATE * 2) * 1000);
      const elapsed: number = Date.now() - startedAt;
      await AudioPlayService.delay(Math.max(0, durationMs - elapsed) + 300);
      if (token !== AudioPlayService.generation) {
        return;
      }
      AudioPlayService.playing = false;
      await AudioPlayService.quietRenderer();
      onEnd();
    } catch (error) {
      if (token === AudioPlayService.generation) {
        AudioPlayService.playing = false;
        Logger.exception(MODULE, '盒音试听失败', error as BusinessError);
        await AudioPlayService.quietRenderer();
        onEnd();
      }
    }
  }

  /** 开始一轮播放：打断上一轮、取消空闲释放 */
  private static async beginPlayback(): Promise<number> {
    AudioPlayService.generation++;
    AudioPlayService.playing = true;
    AudioPlayService.cancelIdleRelease();
    await AudioPlayService.stopRenderer();
    return AudioPlayService.generation;
  }

  /** 复用渲染器：不存在时才创建 */
  private static async ensureRenderer(): Promise<audio.AudioRenderer> {
    const existing: audio.AudioRenderer | undefined = AudioPlayService.renderer;
    if (existing !== undefined) {
      return existing;
    }
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
    };
    const created: audio.AudioRenderer = await audio.createAudioRenderer(options);
    AudioPlayService.renderer = created;
    return created;
  }

  /**
   * 停掉渲染但不销毁，下一次 start 即可继续用。
   * 必须等 stop 真正完成：上一轮的 stop 落后于下一轮的 start 时，
   * 会把刚启动的渲染器再停掉，表现为 write 一直返回 0、试听没声音。
   */
  private static async stopRenderer(): Promise<void> {
    const renderer: audio.AudioRenderer | undefined = AudioPlayService.renderer;
    if (renderer === undefined) {
      return;
    }
    try {
      await renderer.stop();
    } catch (error) {
      Logger.warn(MODULE, '停止渲染失败');
    }
  }

  /** 一次播放结束：停流并安排空闲释放，避免长时间占着音频焦点 */
  private static async quietRenderer(): Promise<void> {
    await AudioPlayService.stopRenderer();
    AudioPlayService.scheduleIdleRelease();
  }

  private static scheduleIdleRelease(): void {
    AudioPlayService.cancelIdleRelease();
    AudioPlayService.idleTimer = setTimeout(() => {
      AudioPlayService.idleTimer = -1;
      if (AudioPlayService.playing) {
        return;
      }
      AudioPlayService.releaseRenderer();
    }, RENDERER_IDLE_MS);
  }

  private static cancelIdleRelease(): void {
    if (AudioPlayService.idleTimer >= 0) {
      clearTimeout(AudioPlayService.idleTimer);
      AudioPlayService.idleTimer = -1;
    }
  }

  private static releaseRenderer(): void {
    const renderer: audio.AudioRenderer | undefined = AudioPlayService.renderer;
    AudioPlayService.renderer = undefined;
    if (renderer === undefined) {
      return;
    }
    renderer.release().then(() => {
    }).catch((error: BusinessError) => {
      Logger.warn(MODULE, `释放渲染器失败 code=${error.code}`);
    });
  }

  /** 停止播放（保留渲染器以备下次快速开始） */
  public static async stop(): Promise<void> {
    AudioPlayService.generation++;
    AudioPlayService.playing = false;
    AudioPlayService.cancelIdleRelease();
    await AudioPlayService.stopRenderer();
    if (AudioPlayService.player !== undefined) {
      const player: media.AVPlayer = AudioPlayService.player;
      AudioPlayService.player = undefined;
      try {
        await player.release();
      } catch (error) {
        Logger.exception(MODULE, '释放播放器失败', error as BusinessError);
      }
    }
    if (AudioPlayService.playerFile !== undefined) {
      const file: fs.File = AudioPlayService.playerFile;
      AudioPlayService.playerFile = undefined;
      try {
        fs.closeSync(file);
      } catch (error) {
        Logger.exception(MODULE, '关闭文件失败', error as BusinessError);
      }
    }
    AudioPlayService.scheduleIdleRelease();
  }

  /** 页面退出时彻底释放 */
  public static async release(): Promise<void> {
    await AudioPlayService.stop();
    AudioPlayService.cancelIdleRelease();
    AudioPlayService.releaseRenderer();
  }
}
