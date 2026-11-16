import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { decodeAudio, probeAudio, DecodedAudio, AudioProbe } from 'libaudiodec.so';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { PcmAudio, SourceAudio } from '../models/ToneModel';

const MODULE: string = 'AudioSource';
/** 单次分析的最大时长，避免长音频占用过多内存 */
const MAX_ANALYZE_SECONDS: number = 60;
/** 解析头部时最多读取的字节数 */
const HEADER_SCAN_LIMIT: number = 1024 * 1024;

interface WavFormat {
  audioFormat: number;
  channels: number;
  sampleRate: number;
  bitsPerSample: number;
  dataOffset: number;
  dataSize: number;
  /** 文件中实际的音频帧总数（未截断） */
  totalFrames: number;
}

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
      // 解码是同步的原生调用，先让选择器的收起动画画完一帧
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
      throw new Error(`无法打开「${displayName}」（${firstError.code}）。` +
        '如果是网盘或微信里的文件，请先保存到本机「文件管理」再导入');
    }
    if (source === null) {
      throw new Error(`无法打开「${displayName}」`);
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
      throw new Error(`无法读取「${displayName}」（${businessError.code}），请确认文件仍可访问`);
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
        throw new Error(`「${displayName}」是空文件`);
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
        return AudioSourceService.loadWav(path, displayName);
      } catch (error) {
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
    // 先探测：只解封装读轨道信息，能明确区分"容器打不开"和"解码器出问题"
    const probe: AudioProbe = probeAudio(path);
    if (!probe.ok) {
      const reason: string = probe.error !== undefined ? probe.error : '系统无法解析该音频';
      Logger.warn(MODULE, `探测失败 ${displayName}（阶段 ${probe.stage}）：${reason}`);
      throw new Error(reason);
    }
    Logger.info(MODULE, `探测 ${displayName}：${probe.mime} ${probe.sampleRate}Hz ` +
      `${probe.channels}声道 时长 ${FormatUtils.duration(probe.durationMs)}`);

    let decoded: DecodedAudio;
    try {
      decoded = await decodeAudio(path, MAX_ANALYZE_SECONDS);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE, `原生解码异常 ${displayName}`, businessError);
      throw new Error(`解码「${displayName}」失败：${businessError.message}`);
    }
    if (!decoded.ok) {
      const reason: string = decoded.error !== undefined ? decoded.error : '系统无法解析该音频';
      Logger.warn(MODULE, `解码失败 ${displayName}（阶段 ${decoded.stage}）：${reason}`);
      throw new Error(reason);
    }
    if (decoded.frameCount <= 0 || decoded.frames.length === 0) {
      throw new Error('这个文件里没有可用的音频数据');
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
      return '音频';
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

  /** 解析本地 WAV 文件 */
  public static loadWav(path: string, displayName: string): SourceAudio {
    const stat: fs.Stat = fs.statSync(path);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const headerSize: number = Math.min(stat.size, HEADER_SCAN_LIMIT);
      const headerBuffer: ArrayBuffer = new ArrayBuffer(headerSize);
      fs.readSync(file.fd, headerBuffer, { offset: 0, length: headerSize });

      const format: WavFormat = AudioSourceService.parseHeader(headerBuffer);
      if (format.dataSize <= 0) {
        throw new Error('文件中没有可用的音频数据');
      }

      const maxFrames: number = Math.floor(format.sampleRate * MAX_ANALYZE_SECONDS);
      const wantedFrames: number = Math.min(format.totalFrames, maxFrames);
      const frameBytes: number = format.channels * format.bitsPerSample / 8;
      const wantedBytes: number = Math.min(format.dataSize, wantedFrames * frameBytes);

      const dataBuffer: ArrayBuffer = new ArrayBuffer(wantedBytes);
      fs.readSync(file.fd, dataBuffer, { offset: format.dataOffset, length: wantedBytes });

      const frames: Float32Array = AudioSourceService.decodeSamples(dataBuffer, format);
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

  private static parseHeader(buffer: ArrayBuffer): WavFormat {
    if (buffer.byteLength < 44) {
      throw new Error('文件过小，不是有效的 WAV 音频');
    }
    const view: DataView = new DataView(buffer);
    const riff: string = AudioSourceService.readFourCC(view, 0);
    const wave: string = AudioSourceService.readFourCC(view, 8);
    if (riff !== 'RIFF' || wave !== 'WAVE') {
      throw new Error('这个文件的 WAV 头不完整，请重新导出后导入');
    }

    const result: WavFormat = {
      audioFormat: 1,
      channels: 1,
      sampleRate: 44100,
      bitsPerSample: 16,
      dataOffset: 0,
      dataSize: 0,
      totalFrames: 0
    };
    let hasFormat: boolean = false;
    let offset: number = 12;
    while (offset + 8 <= buffer.byteLength) {
      const chunkId: string = AudioSourceService.readFourCC(view, offset);
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
      throw new Error('WAV 文件缺少格式信息（fmt 块），无法解析');
    }
    if (result.channels < 1 || result.channels > 8) {
      throw new Error(`不支持的声道数：${result.channels}`);
    }
    if (result.sampleRate < 4000 || result.sampleRate > 192000) {
      throw new Error(`不支持的采样率：${result.sampleRate}Hz`);
    }
    if (result.audioFormat !== 1 && result.audioFormat !== 3) {
      throw new Error('仅支持未压缩的 WAV（PCM 或 IEEE Float）');
    }
    if (result.audioFormat === 3 && result.bitsPerSample !== 32) {
      throw new Error('浮点 WAV 仅支持 32bit');
    }

    const frameBytes: number = result.channels * result.bitsPerSample / 8;
    result.totalFrames = frameBytes > 0 ? Math.floor(result.dataSize / frameBytes) : 0;
    return result;
  }

  private static decodeSamples(buffer: ArrayBuffer, format: WavFormat): Float32Array {
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
      return out;
    }
    if (bits === 8) {
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
      throw new Error(`不支持的位深：${bits}bit`);
    }
    return out;
  }

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

  /** 删除导入的临时源文件 */
  public static removeSource(path: string): void {
    try {
      if (path.length > 0 && fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      Logger.exception(MODULE, '删除源文件失败', error as BusinessError);
    }
  }
}
