import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPath } from '../common/constants/AppConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { ConvertResult, ToneEntry, ToneIndex } from '../models/ToneModel';

const MODULE: string = 'ToneRepo';
const INDEX_VERSION: number = 1;

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
      return;
    }
    try {
      const text: string = fs.readTextSync(path);
      const parsed: ToneIndex = JSON.parse(text) as ToneIndex;
      ToneRepositoryService.items = parsed.items !== undefined && parsed.items !== null ? parsed.items : [];
      Logger.info(MODULE, `已加载音效库，共 ${ToneRepositoryService.items.length} 条`);
    } catch (error) {
      Logger.exception(MODULE, '音效索引损坏，已重置', error as BusinessError);
      ToneRepositoryService.items = [];
    }
  }

  private static persist(): void {
    const index: ToneIndex = { version: INDEX_VERSION, items: ToneRepositoryService.items };
    try {
      const file: fs.File = fs.openSync(ToneRepositoryService.indexPath(),
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(index));
      fs.closeSync(file);
    } catch (error) {
      Logger.exception(MODULE, '写入索引失败', error as BusinessError);
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
    fs.writeSync(file.fd, result.buffer);
    fs.closeSync(file);

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
      throw new Error('音效库未初始化');
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
   * 导出音效到用户选择的位置
   * @returns 保存的文件名，取消时返回空串
   */
  public static async exportTone(entry: ToneEntry): Promise<string> {
    if (ToneRepositoryService.context === undefined) {
      throw new Error('音效库未初始化');
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
