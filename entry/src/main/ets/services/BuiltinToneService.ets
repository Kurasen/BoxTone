import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';
import { PcmAudio } from '../models/ToneModel';
import { decodeWavSamples, parseWavHeader } from './audio/WavCodec';
import { BuiltinDecodeTaskService } from './audio/BuiltinDecodeTask';
import { WavTaskResult } from './audio/WavDecodeTask';

const MODULE: string = 'BuiltinTone';

/**
 * 内置音效加载服务
 *
 * 音效以标准 WAV 打包在 rawfile/ 下，读取后复用应用自有的 WavCodec 解码，
 * 得到与用户导入音频一致的 PcmAudio，后续裁剪/增益/转换路径完全共用。
 *
 * 解码放在 TaskPool 里跑，解码结果按 id 常驻内存：内置音效体积固定、总量不到 2MB，
 * 换来的是重复点击零等待。页面还会在空闲时预热一遍，首次点击也基本命中缓存。
 */
export class BuiltinToneService {
  private static readonly cache: Map<string, PcmAudio> = new Map<string, PcmAudio>();

  /** 已解码过就直接返回，调用方据此判断是否需要显示加载态 */
  public static cached(id: string): PcmAudio | undefined {
    return BuiltinToneService.cache.get(id);
  }

  /** 读取并解码一个内置音效；失败时抛错，由调用方提示用户 */
  public static async load(context: common.UIAbilityContext, id: string): Promise<PcmAudio> {
    const hit: PcmAudio | undefined = BuiltinToneService.cache.get(id);
    if (hit !== undefined) {
      return hit;
    }

    // rawfile 根目录下的文件名即音效 id；兼容曾经放在 builtin/ 子目录下的打包方式
    const candidates: string[] = [`${id}.wav`, `builtin/${id}.wav`];
    let bytes: Uint8Array | undefined = undefined;
    let path: string = candidates[0];
    let lastCode: number = 0;
    for (let i = 0; i < candidates.length; i++) {
      try {
        bytes = await context.resourceManager.getRawFileContent(candidates[i]);
        path = candidates[i];
        break;
      } catch (error) {
        lastCode = (error as BusinessError).code;
      }
    }
    if (bytes === undefined) {
      Logger.error(MODULE, `读取内置音效失败 ${id} code=${lastCode}（已尝试 ${candidates.join(', ')}）`);
      throw new Error(`builtin read failed: ${id}`);
    }

    // 转成独立 ArrayBuffer：TaskPool 与 DataView 都需要一个可转移的缓冲
    const buffer: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
    const view: Uint8Array = new Uint8Array(buffer);
    view.set(bytes);

    let pcm: PcmAudio | undefined = undefined;
    try {
      const result: WavTaskResult = await BuiltinDecodeTaskService.decodeAsync(buffer);
      if (result.ok) {
        pcm = {
          sampleRate: result.sampleRate,
          channels: result.channels,
          frameCount: result.frameCount,
          frames: new Float32Array(result.frames)
        };
      } else {
        Logger.warn(MODULE, `内置音效解码失败 ${path}: ${result.errorKey}`);
      }
    } catch (error) {
      Logger.warn(MODULE, `后台解码不可用，回退主线程：${(error as Error).message}`);
    }

    // 回退路径：TaskPool 不可用或解码失败时在主线程同步解一遍
    if (pcm === undefined) {
      const parsed = parseWavHeader(buffer);
      if (!parsed.ok) {
        Logger.warn(MODULE, `内置音效 WAV 头解析失败 ${path}: ${parsed.errorKey}`);
        throw new Error(`builtin wav header invalid: ${path}`);
      }
      const available: number = Math.max(0, buffer.byteLength - parsed.format.dataOffset);
      const dataBuffer: ArrayBuffer = buffer.slice(parsed.format.dataOffset,
        parsed.format.dataOffset + Math.min(parsed.format.dataSize, available));
      const decoded = decodeWavSamples(dataBuffer, parsed.format);
      if (!decoded.ok) {
        Logger.warn(MODULE, `内置音效样本解码失败 ${path}: ${decoded.errorKey}`);
        throw new Error(`builtin wav decode failed: ${path}`);
      }
      pcm = {
        sampleRate: parsed.format.sampleRate,
        channels: parsed.format.channels,
        frameCount: Math.floor(decoded.samples.length / parsed.format.channels),
        frames: decoded.samples
      };
    }

    BuiltinToneService.cache.set(id, pcm);
    Logger.info(MODULE, `内置音效已载入 ${path}：${pcm.sampleRate}Hz ${pcm.channels}声道 ` +
      `${pcm.frameCount}帧 ${(pcm.frameCount * 1000 / pcm.sampleRate).toFixed(0)}ms`);
    return pcm;
  }

  /** 预热：失败静默，不影响正常点击时的加载 */
  public static async preload(context: common.UIAbilityContext, id: string): Promise<void> {
    if (BuiltinToneService.cache.has(id)) {
      return;
    }
    try {
      await BuiltinToneService.load(context, id);
    } catch (error) {
      Logger.warn(MODULE, `预载内置音效失败 ${id}`);
    }
  }
}
