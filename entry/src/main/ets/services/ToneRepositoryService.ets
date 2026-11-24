import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPath, ToneSpec } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { ConvertResult, ToneEntry, ToneIndex } from '../models/ToneModel';
import { wrapPcmAsWav } from './audio/WavCodec';

const MODULE: string = 'ToneRepo';
const INDEX_VERSION: number = 1;
const TONE_SUFFIX: string = '.pcm';

/**
 * 音效库仓库
 * 元数据写入 index.json，音频二进制以 .pcm 存放于沙箱 tones 目录
 */
export class ToneRepositoryService {
  private static context?: common.UIAbilityContext;
  private static items: ToneEntry[] = [];
  private static loaded: boolean = false;
  private static sequence: number = 0;

  public static init(context: common.UIAbilityContext): void {
    if (ToneRepositoryService.loaded && ToneRepositoryService.context !== undefined) {
      return;
    }
    ToneRepositoryService.context = context;
    const dir: string = ToneRepositoryService.toneDir();
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    ToneRepositoryService.loadIndex();
    ToneRepositoryService.loaded = true;
  }

  private static toneDir(): string {
    const context: common.UIAbilityContext | undefined = ToneRepositoryService.context;
    if (context === undefined) {
      return '';
    }
    return `${context.filesDir}/${AppPath.TONE_DIR}`;
  }

  private static indexPath(): string {
    return `${ToneRepositoryService.toneDir()}/${AppPath.TONE_INDEX}`;
  }

  private static loadIndex(): void {
    const path: string = ToneRepositoryService.indexPath();
    if (!fs.accessSync(path)) {
      ToneRepositoryService.items = [];
      if (ToneRepositoryService.recoverOrphans()) {
        ToneRepositoryService.persist();
      }
      return;
    }
    try {
      const text: string = fs.readTextSync(path);
      const parsed: ToneIndex = JSON.parse(text) as ToneIndex;
      ToneRepositoryService.items = parsed.items !== undefined && parsed.items !== null ? parsed.items : [];
      if (ToneRepositoryService.recoverOrphans()) {
        ToneRepositoryService.persist();
      }
      Logger.info(MODULE, `已加载音效库，共 ${ToneRepositoryService.items.length} 条`);
    } catch (error) {
      Logger.exception(MODULE, '音效索引损坏，尝试从音频文件恢复', error as BusinessError);
      ToneRepositoryService.items = [];
      if (ToneRepositoryService.recoverOrphans()) {
        ToneRepositoryService.persist();
      }
    }
  }

  /**
   * 扫描索引之外但仍存在的 .pcm：
   * 保存音效时先落文件再写索引，进程在这中间被结束会留下孤儿文件。
   * 这里按文件名里的时间戳补回条目，避免用户看到"文件占着空间但库里没有"。
   */
  private static recoverOrphans(): boolean {
    const dir: string = ToneRepositoryService.toneDir();
    if (dir.length === 0) {
      return false;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (error) {
      Logger.warn(MODULE, '扫描音效目录失败，跳过恢复');
      return false;
    }
    let added: number = 0;
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!name.endsWith(TONE_SUFFIX)) {
        continue;
      }
      const id: string = name.substring(0, name.length - TONE_SUFFIX.length);
      if (id.length === 0 || ToneRepositoryService.contains(id)) {
        continue;
      }
      const path: string = `${dir}/${name}`;
      let size: number = 0;
      try {
        size = fs.statSync(path).size;
      } catch (error) {
        continue;
      }
      if (size <= 0 || size % 2 !== 0) {
        continue;
      }
      const createdAt: number = ToneRepositoryService.recoverCreatedAt(id, path);
      const entry: ToneEntry = {
        id: id,
        name: I18n.f('repo.recoveredName', [DateUtils.dateTime(createdAt)]),
        fileName: name,
        durationMs: size * 1000 / ToneSpec.BYTES_PER_SECOND,
        byteLength: size,
        createdAt: createdAt,
        sourceName: I18n.t('repo.recoveredSource')
      };
      ToneRepositoryService.items.push(entry);
      added++;
    }
    if (added === 0) {
      return false;
    }
    ToneRepositoryService.items.sort((a: ToneEntry, b: ToneEntry): number => b.createdAt - a.createdAt);
    Logger.info(MODULE, `已从音频文件恢复 ${added} 条音效`);
    return true;
  }

  private static contains(id: string): boolean {
    for (let i = 0; i < ToneRepositoryService.items.length; i++) {
      if (ToneRepositoryService.items[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 优先取文件名里的毫秒时间戳，取不到再退回文件修改时间 */
  private static recoverCreatedAt(id: string, path: string): number {
    if (id.length >= 14 && id.charAt(0) === 't') {
      const parsed: number = Number(id.substring(1, 14));
      if (!isNaN(parsed) && parsed > 1600000000000 && parsed < Date.now() + 86400000) {
        return parsed;
      }
    }
    try {
      let modified: number = fs.statSync(path).mtime;
      if (modified < 100000000000) {
        modified *= 1000;
      }
      return modified;
    } catch (error) {
      return Date.now();
    }
  }

  private static persist(): void {
    const index: ToneIndex = { version: INDEX_VERSION, items: ToneRepositoryService.items };
    const target: string = ToneRepositoryService.indexPath();
    const temp: string = `${target}.tmp`;
    try {
      const file: fs.File = fs.openSync(temp,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(index));
      } finally {
        fs.closeSync(file);
      }
      try {
        fs.renameSync(temp, target);
      } catch (renameError) {
        // 部分文件系统不允许 rename 覆盖已有文件，退化为先删后改名
        if (fs.accessSync(target)) {
          fs.unlinkSync(target);
        }
        fs.renameSync(temp, target);
      }
    } catch (error) {
      Logger.exception(MODULE, '写入索引失败', error as BusinessError);
      try {
        if (fs.accessSync(temp)) {
          fs.unlinkSync(temp);
        }
      } catch (cleanupError) {
        Logger.warn(MODULE, '清理索引临时文件失败');
      }
    }
  }

  /** 音效文件在沙箱内的绝对路径 */
  public static pathOf(entry: ToneEntry): string {
    return `${ToneRepositoryService.toneDir()}/${entry.fileName}`;
  }

  public static list(): ToneEntry[] {
    const copy: ToneEntry[] = [];
    for (let i = 0; i < ToneRepositoryService.items.length; i++) {
      copy.push(ToneRepositoryService.items[i]);
    }
    return copy;
  }

  public static count(): number {
    return ToneRepositoryService.items.length;
  }

  public static totalBytes(): number {
    let total: number = 0;
    for (let i = 0; i < ToneRepositoryService.items.length; i++) {
      total += ToneRepositoryService.items[i].byteLength;
    }
    return total;
  }

  /** 保存新生成的音效 */
  public static save(name: string, result: ConvertResult, sourceName: string): ToneEntry {
    ToneRepositoryService.sequence++;
    const id: string = `t${Date.now()}${ToneRepositoryService.sequence}`;
    const fileName: string = `${id}.pcm`;
    const filePath: string = `${ToneRepositoryService.toneDir()}/${fileName}`;
    const file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, result.buffer);
    } finally {
      // 写盘失败也要关句柄：save 每次生成都会调用，泄漏会累积到进程结束
      fs.closeSync(file);
    }

    const entry: ToneEntry = {
      id: id,
      name: name,
      fileName: fileName,
      durationMs: result.durationMs,
      byteLength: result.byteLength,
      createdAt: Date.now(),
      sourceName: sourceName
    };
    ToneRepositoryService.items.unshift(entry);
    ToneRepositoryService.persist();
    Logger.info(MODULE, `已保存音效 ${name}（${result.byteLength} 字节）`);
    return entry;
  }

  /** 读取音效二进制 */
  public static readBuffer(entry: ToneEntry): ArrayBuffer {
    const path: string = ToneRepositoryService.pathOf(entry);
    const size: number = fs.statSync(path).size;
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer, { offset: 0, length: size });
    } finally {
      fs.closeSync(file);
    }
    return buffer;
  }

  /**
   * 导入一条已经符合盒端规格的音效（来自备份或 .pcm 文件）。
   *
   * 不做任何 DSP：文件必须是 16bit 单声道 16700Hz 的原始波形。
   * 允许的上限比「可写入上限」宽松（见 ToneSpec.MAX_IMPORT_BYTES），
   * 这样旧版本生成的 3~5 秒音效也能先备回来，写入时再由 CaseWriteService 拦截。
   */
  public static importTone(name: string, buffer: ArrayBuffer, sourceName: string,
    createdAt: number = 0): ToneEntry {
    const byteLength: number = buffer.byteLength;
    if (byteLength <= 0 || byteLength % ToneSpec.BYTES_PER_FRAME !== 0) {
      throw new Error(I18n.t('repo.badImportSize'));
    }
    if (byteLength > ToneSpec.MAX_IMPORT_BYTES) {
      throw new Error(I18n.f('repo.importTooLarge', [`${ToneSpec.MAX_IMPORT_BYTES}`]));
    }
    const trimmed: string = name.trim();
    const toneName: string = trimmed.length > 0 ? trimmed : I18n.t('repo.importDefaultName');

    ToneRepositoryService.sequence++;
    const id: string = `t${Date.now()}${ToneRepositoryService.sequence}`;
    const fileName: string = `${id}.pcm`;
    const filePath: string = `${ToneRepositoryService.toneDir()}/${fileName}`;
    const file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }

    const entry: ToneEntry = {
      id: id,
      name: toneName,
      fileName: fileName,
      durationMs: byteLength * 1000 / ToneSpec.BYTES_PER_SECOND,
      byteLength: byteLength,
      createdAt: createdAt > 0 ? createdAt : Date.now(),
      sourceName: sourceName
    };
    ToneRepositoryService.items.unshift(entry);
    ToneRepositoryService.persist();
    Logger.info(MODULE, `已导入音效 ${toneName}（${byteLength} 字节）`);
    return entry;
  }

  public static rename(entry: ToneEntry, newName: string): void {
    for (let i = 0; i < ToneRepositoryService.items.length; i++) {
      if (ToneRepositoryService.items[i].id === entry.id) {
        ToneRepositoryService.items[i].name = newName;
        break;
      }
    }
    ToneRepositoryService.persist();
    Logger.info(MODULE, `重命名音效为 ${newName}`);
  }

  public static remove(entry: ToneEntry): void {
    const path: string = `${ToneRepositoryService.toneDir()}/${entry.fileName}`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      Logger.exception(MODULE, '删除音效文件失败', error as BusinessError);
    }
    const remain: ToneEntry[] = [];
    for (let i = 0; i < ToneRepositoryService.items.length; i++) {
      if (ToneRepositoryService.items[i].id !== entry.id) {
        remain.push(ToneRepositoryService.items[i]);
      }
    }
    ToneRepositoryService.items = remain;
    ToneRepositoryService.persist();
    Logger.info(MODULE, `已删除音效 ${entry.name}`);
  }

  /**
   * 直接导出一段二进制到用户选择的位置（不进入音效库）
   * @returns 保存的文件名，取消时返回空串
   */
  public static async exportBuffer(buffer: ArrayBuffer, baseName: string): Promise<string> {
    if (ToneRepositoryService.context === undefined) {
      throw new Error(I18n.t('repo.notReady'));
    }
    const safeName: string = baseName.replace(/[\\/:*?"<>|]/g, '_');
    const fileName: string = `${safeName}.pcm`;
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.pcm', '.raw'];
    const documentPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(ToneRepositoryService.context);
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0) {
      return '';
    }
    const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    Logger.info(MODULE, `原始波形已导出 ${fileName}（${buffer.byteLength} 字节）`);
    return fileName;
  }

  /**
   * 生成可分享的 WAV 临时文件，返回 file:// uri。
   * 库内是裸 PCM，直接分享对方打不开，这里补上 WAV 头再给系统分享面板。
   */
  public static async prepareShareFile(entry: ToneEntry): Promise<string> {
    if (ToneRepositoryService.context === undefined) {
      throw new Error(I18n.t('repo.notReady'));
    }
    const pcm: ArrayBuffer = ToneRepositoryService.readBuffer(entry);
    const wav: ArrayBuffer = wrapPcmAsWav(pcm, ToneSpec.SAMPLE_RATE, 1);
    const safeName: string = entry.name.replace(/[\\/:*?"<>|]/g, '_');
    const path: string = `${ToneRepositoryService.context.cacheDir}/${safeName}.wav`;
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, wav);
    } finally {
      fs.closeSync(file);
    }
    Logger.info(MODULE, `已准备分享文件 ${safeName}.wav（${wav.byteLength} 字节）`);
    return fileUri.getUriFromPath(path);
  }

  /**
   * 导出音效到用户选择的位置
   * @returns 保存的文件名，取消时返回空串
   */
  public static async exportTone(entry: ToneEntry): Promise<string> {
    if (ToneRepositoryService.context === undefined) {
      throw new Error(I18n.t('repo.notReady'));
    }
    const safeName: string = entry.name.replace(/[\\/:*?"<>|]/g, '_');
    const fileName: string = `${safeName}-16k7-${DateUtils.fileStamp(entry.createdAt)}.pcm`;
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.pcm', '.raw'];
    const documentPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(ToneRepositoryService.context);
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0) {
      return '';
    }
    const buffer: ArrayBuffer = ToneRepositoryService.readBuffer(entry);
    const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    Logger.info(MODULE, `音效已导出 ${fileName}`);
    return fileName;
  }
}
