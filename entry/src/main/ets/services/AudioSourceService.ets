import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { decodeAudio, probeAudio, DecodedAudio, AudioProbe } from 'libaudiodec.so';
import { I18n } from '../common/i18n/I18n';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { PcmAudio, SourceAudio } from '../models/ToneModel';
import { decodeWavSamples, parseWavHeader, WavFormat, WavParseResult, WavSamplesResult } from './audio/WavCodec';
import { WavDecodeTaskService, WavTaskResult } from './audio/WavDecodeTask';
import { ImportCancelledError, ImportControl } from './audio/ImportControl';

const MODULE: string = 'AudioSource';
/**
 * 单次分析的最大时长。
 * 5 分钟素材按 48kHz 立体声算约 115MB 的 Float32 PCM，是低端机仍可承受的上限；
 * 再长的文件只载入开头一段并提示用户。
 */
const MAX_ANALYZE_SECONDS: number = 300;
/** 解析头部时最多读取的字节数 */
const HEADER_SCAN_LIMIT: number = 1024 * 1024;

/**
 * 音频导入服务
 *
 * 两条解码路径：
 * 1. WAV：自行解析头部，支持 PCM 8/16/24/32bit、IEEE Float、WAVE_FORMAT_EXTENSIBLE，
 *    可以精确知道源文件的原始位深与采样率；
 * 2. 其余主流格式（MP3 / AAC / M4A / FLAC / OGG / AMR / AIFF…）：
 *    交给系统解码器（NDK 的 AVSource + AVDemuxer + AudioCodec）解成交错 Float32。
 *    之所以走原生：HarmonyOS 的 ArkTS 侧没有开放 AVCodec 接口。
 */
export class AudioSourceService {
  private static sequence: number = 0;

  /** 打开系统文件选择器并导入 */
  public static async pickAndImport(context: common.UIAbilityContext): Promise<SourceAudio | null> {
    const options: picker.AudioSelectOptions = new picker.AudioSelectOptions();
    options.maxSelectNumber = 1;
    try {
      const audioPicker: picker.AudioViewPicker = new picker.AudioViewPicker(context);
      const uris: string[] = await audioPicker.select(options);
      if (uris.length === 0) {
        Logger.info(MODULE, '用户取消选择音频');
        return null;
      }
      // 先让选择器的收起动画画完一帧，再开始读文件与解码
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 30);
      });
      return await AudioSourceService.importFromUri(context, uris[0]);
    } catch (error) {
      Logger.exception(MODULE, '选择音频失败', error as BusinessError);
      throw error as Error;
    }
  }

  /** 从 URI 导入：复制到沙箱后解析 */
  public static async importFromUri(context: common.UIAbilityContext, uri: string): Promise<SourceAudio> {
    const rawName: string = AudioSourceService.fileNameOf(uri);
    const dir: string = `${context.filesDir}/sources`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    AudioSourceService.sequence++;
    const safeName: string = rawName.replace(/[\\/:*?"<>|]/g, '_');
    const target: string = `${dir}/${Date.now()}_${AudioSourceService.sequence}_${safeName}`;
    AudioSourceService.copyInto(uri, target, rawName);
    ImportControl.throwIfCancelled();
    return await AudioSourceService.loadSource(target, rawName);
  }

  /**
   * 把选择器给的 URI 复制进沙箱。
   *
   * 不能把 URI 直接当路径丢给 copyFileSync：
   * 文档/媒体类 URI 是百分号编码的（中文名会变成 %E9%97%AD…），
   * 系统会按字面去打开带 % 的路径，直接报 13900002 No such file or directory。
   * 正确做法是先 openSync 拿到 fd，再按 fd 拷贝。
   */
  private static copyInto(uri: string, target: string, displayName: string): void {
    let source: fs.File | null = null;
    let firstError: BusinessError | null = null;
    try {
      source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    } catch (error) {
      firstError = error as BusinessError;
      Logger.exception(MODULE, `打开音频失败 uri=${uri} code=${firstError.code}`, firstError);
      throw new Error(I18n.f('audio.openFailed', [displayName, `${firstError.code}`]));
    }
    if (source === null) {
      throw new Error(I18n.f('audio.openFailedShort', [displayName]));
    }
    try {
      fs.copyFileSync(source.fd, target);
      return;
    } catch (error) {
      firstError = error as BusinessError;
      Logger.warn(MODULE, `按描述符复制失败 code=${firstError.code}，改用手动读写`);
    } finally {
      try {
        fs.closeSync(source);
      } catch (closeError) {
        Logger.warn(MODULE, '关闭源文件失败');
      }
    }
    try {
      AudioSourceService.copyByStream(uri, target, displayName);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE,
        `复制音频文件失败 uri=${uri} code=${businessError.code}（首次错误 ${firstError !== null ? firstError.code : 0}）`,
        businessError);
      throw new Error(I18n.f('audio.readFailed', [displayName, `${businessError.code}`]));
    }
  }

  /** 兜底复制：沙箱环境对某些 URI 不支持 copyFileSync 时逐块搬运 */
  private static copyByStream(uri: string, target: string, displayName: string): void {
    const source: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let sink: fs.File | null = null;
    try {
      sink = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const buffer: ArrayBuffer = new ArrayBuffer(256 * 1024);
      let total: number = 0;
      while (true) {
        const read: number = fs.readSync(source.fd, buffer, { length: buffer.byteLength });
        if (read <= 0) {
          break;
        }
        fs.writeSync(sink.fd, buffer, { length: read });
        total += read;
      }
      if (total <= 0) {
        throw new Error(I18n.f('audio.emptyFile', [displayName]));
      }
    } finally {
      try {
        fs.closeSync(source);
      } catch (error) {
        Logger.warn(MODULE, '关闭源文件失败');
      }
      if (sink !== null) {
        try {
          fs.closeSync(sink);
        } catch (error) {
          Logger.warn(MODULE, '关闭目标文件失败');
        }
      }
    }
  }

  /** 按文件实际内容分派：RIFF/WAVE 自行解析，其余交给系统解码器 */
  public static async loadSource(path: string, displayName: string): Promise<SourceAudio> {
    if (AudioSourceService.isWav(path)) {
      try {
        return await AudioSourceService.loadWavAsync(path, displayName);
      } catch (error) {
        if (error instanceof ImportCancelledError) {
          throw error;
        }
        // 压缩型 WAV（ADPCM、WAV 里封装 MP3 等）自己解不了，退回系统解码器
        Logger.warn(MODULE, `WAV 自行解析失败，改用系统解码：${(error as Error).message}`);
        return await AudioSourceService.loadDecoded(path, displayName);
      }
    }
    return await AudioSourceService.loadDecoded(path, displayName);
  }

  /** 读前 12 字节判断是不是标准 WAV */
  private static isWav(path: string): boolean {
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const head: ArrayBuffer = new ArrayBuffer(12);
        fs.readSync(file.fd, head, { offset: 0, length: 12 });
        const view: DataView = new DataView(head);
        return AudioSourceService.readFourCC(view, 0) === 'RIFF' &&
          AudioSourceService.readFourCC(view, 8) === 'WAVE';
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      return false;
    }
  }

  /** 用系统解码器解码 MP3 / AAC / M4A / FLAC / OGG 等 */
  private static async loadDecoded(path: string, displayName: string): Promise<SourceAudio> {
    ImportControl.throwIfCancelled();
    // 先探测：只解封装读轨道信息，能明确区分"容器打不开"和"解码器出问题"
    const probe: AudioProbe = probeAudio(path);
    if (!probe.ok) {
      const reason: string = probe.error !== undefined ? probe.error : I18n.t('audio.cannotParse');
      Logger.warn(MODULE, `探测失败 ${displayName}（阶段 ${probe.stage}）：${reason}`);
      throw new Error(reason);
    }
    Logger.info(MODULE, `探测 ${displayName}：${probe.mime} ${probe.sampleRate}Hz ` +
      `${probe.channels}声道 时长 ${FormatUtils.duration(probe.durationMs)}`);

    let decoded: DecodedAudio;
    try {
      // 检查工具解析不到自定义 .so 模块签名会误报；native 侧 DecodeAudio 经 napi_create_promise 返回 Promise
      decoded = await (decodeAudio(path, MAX_ANALYZE_SECONDS) as Promise<DecodedAudio>);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE, `原生解码异常 ${displayName}`, businessError);
      throw new Error(I18n.f('audio.decodeFailed', [displayName, businessError.message]));
    }
    if (!decoded.ok) {
      if (decoded.cancelled || ImportControl.isCancelled()) {
        throw new ImportCancelledError();
      }
      const reason: string = decoded.error !== undefined ? decoded.error : I18n.t('audio.cannotParse');
      Logger.warn(MODULE, `解码失败 ${displayName}（阶段 ${decoded.stage}）：${reason}`);
      throw new Error(reason);
    }
    ImportControl.throwIfCancelled();
    if (decoded.frameCount <= 0 || decoded.frames.length === 0) {
      throw new Error(I18n.t('audio.noAudioData'));
    }

    const channels: number = decoded.channels > 0 ? decoded.channels : 1;
    const sampleRate: number = decoded.sampleRate > 0 ? decoded.sampleRate : 44100;
    const pcm: PcmAudio = {
      sampleRate: sampleRate,
      channels: channels,
      frameCount: decoded.frameCount,
      frames: decoded.frames
    };
    const durationMs: number = decoded.frameCount * 1000 / sampleRate;
    const source: SourceAudio = {
      path: path,
      name: displayName,
      format: AudioSourceService.formatNameOf(displayName),
      sampleRate: sampleRate,
      channels: channels,
      durationMs: durationMs,
      truncated: decoded.truncated,
      pcm: pcm
    };
    Logger.info(MODULE, `已解码 ${displayName}：${FormatUtils.sampleRate(sampleRate)} ` +
      `${FormatUtils.channelName(channels)} 时长 ${FormatUtils.duration(durationMs)}` +
      (decoded.truncated ? '（超出上限已截断）' : ''));
    return source;
  }

  /** 从扩展名推断展示用的格式名 */
  private static formatNameOf(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    if (dot < 0 || dot >= fileName.length - 1) {
      return I18n.t('audio.generic');
    }
    const ext: string = fileName.substring(dot + 1).toUpperCase();
    if (ext === 'M4A' || ext === 'MP4') {
      return 'M4A / AAC';
    }
    if (ext === 'OGG' || ext === 'OGA') {
      return 'OGG';
    }
    return ext;
  }

  /**
   * 解析本地 WAV 文件（TaskPool）。
   * 5 分钟素材有 2600 万个采样点，逐点转换放在主线程会冻结 UI 数秒，
   * 读取与解码整段交给工作线程；任务池不可用时回退下面的同步实现。
   */
  public static async loadWavAsync(path: string, displayName: string): Promise<SourceAudio> {
    let result: WavTaskResult;
    try {
      result = await WavDecodeTaskService.decodeAsync(path, MAX_ANALYZE_SECONDS);
    } catch (error) {
      if (error instanceof ImportCancelledError) {
        throw error;
      }
      Logger.warn(MODULE, `WAV 解码任务失败，回退主线程：${(error as Error).message}`);
      return AudioSourceService.loadWav(path, displayName);
    }
    ImportControl.throwIfCancelled();
    if (!result.ok) {
      throw new Error(AudioSourceService.errorText(result.errorKey, result.errorArgs));
    }

    const frames: Float32Array = new Float32Array(result.frames);
    const channels: number = result.channels > 0 ? result.channels : 1;
    const frameCount: number = result.frameCount > 0
      ? result.frameCount : Math.floor(frames.length / channels);
    const pcm: PcmAudio = {
      sampleRate: result.sampleRate,
      channels: channels,
      frameCount: frameCount,
      frames: frames
    };
    const durationMs: number = result.totalFrames * 1000 / result.sampleRate;
    const source: SourceAudio = {
      path: path,
      name: displayName,
      format: result.audioFormat === 3 ? 'WAV / Float' : 'WAV / PCM',
      sampleRate: result.sampleRate,
      channels: channels,
      durationMs: durationMs,
      truncated: result.truncated,
      pcm: pcm
    };
    Logger.info(MODULE, `已导入 ${displayName}：${FormatUtils.sampleRate(result.sampleRate)} ` +
      `${FormatUtils.channelName(channels)} ${result.bitsPerSample}bit ` +
      `时长 ${FormatUtils.duration(durationMs)}（工作线程解码）`);
    return source;
  }

  /** 主线程同步解码，仅作为 TaskPool 不可用时的兜底 */
  public static loadWav(path: string, displayName: string): SourceAudio {
    const stat: fs.Stat = fs.statSync(path);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const headerSize: number = Math.min(stat.size, HEADER_SCAN_LIMIT);
      const headerBuffer: ArrayBuffer = new ArrayBuffer(headerSize);
      fs.readSync(file.fd, headerBuffer, { offset: 0, length: headerSize });

      const parsed: WavParseResult = parseWavHeader(headerBuffer);
      if (!parsed.ok) {
        throw new Error(AudioSourceService.errorText(parsed.errorKey, parsed.errorArgs));
      }
      const format: WavFormat = parsed.format;
      if (format.dataSize <= 0) {
        throw new Error(I18n.t('audio.wavNoData'));
      }

      const maxFrames: number = Math.floor(format.sampleRate * MAX_ANALYZE_SECONDS);
      const wantedFrames: number = Math.min(format.totalFrames, maxFrames);
      const frameBytes: number = format.channels * format.bitsPerSample / 8;
      const wantedBytes: number = Math.min(format.dataSize, wantedFrames * frameBytes);

      const dataBuffer: ArrayBuffer = new ArrayBuffer(wantedBytes);
      fs.readSync(file.fd, dataBuffer, { offset: format.dataOffset, length: wantedBytes });

      const decoded: WavSamplesResult = decodeWavSamples(dataBuffer, format);
      if (!decoded.ok) {
        throw new Error(AudioSourceService.errorText(decoded.errorKey, decoded.errorArgs));
      }
      const frames: Float32Array = decoded.samples;
      const frameCount: number = Math.floor(frames.length / format.channels);

      const pcm: PcmAudio = {
        sampleRate: format.sampleRate,
        channels: format.channels,
        frameCount: frameCount,
        frames: frames
      };
      const durationMs: number = format.totalFrames * 1000 / format.sampleRate;
      const truncated: boolean = format.totalFrames > maxFrames;

      let formatName: string = 'WAV / PCM';
      if (format.audioFormat === 3) {
        formatName = 'WAV / Float';
      }
      const source: SourceAudio = {
        path: path,
        name: displayName,
        format: formatName,
        sampleRate: format.sampleRate,
        channels: format.channels,
        durationMs: durationMs,
        truncated: truncated,
        pcm: pcm
      };
      Logger.info(MODULE, `已导入 ${displayName}：${FormatUtils.sampleRate(format.sampleRate)} ` +
        `${FormatUtils.channelName(format.channels)} ${format.bitsPerSample}bit ` +
        `时长 ${FormatUtils.duration(durationMs)}`);
      return source;
    } finally {
      fs.closeSync(file);
    }
  }

  /** 把 WavCodec 返回的 i18n key 翻成当前语言文案 */
  private static errorText(key: string, args: string[]): string {
    return args.length > 0 ? I18n.f(key, args) : I18n.t(key);
  }

  /** 读取四字节标识（判断 RIFF/WAVE 用） */
  private static readFourCC(view: DataView, offset: number): string {
    let text: string = '';
    for (let i = 0; i < 4; i++) {
      text += String.fromCharCode(view.getUint8(offset + i));
    }
    return text;
  }

  private static fileNameOf(uri: string): string {
    const index: number = uri.lastIndexOf('/');
    const segment: string = index >= 0 ? uri.substring(index + 1) : uri;
    try {
      return decodeURIComponent(segment);
    } catch (error) {
      return segment;
    }
  }
}
