import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../common/i18n/I18n';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { ToneEntry } from '../models/ToneModel';
import { ToneRepositoryService } from './ToneRepositoryService';

const MODULE: string = 'ToneBackup';
/** 备份容器魔数：8 字节 ASCII，后接 u32 清单长度（小端） */
const BACKUP_MAGIC: string = 'BOXTONE1';
const HEADER_BYTES: number = 12;
/** 清单上限：正常库远达不到，超过即视为文件损坏，避免一次性分配大内存 */
const MAX_MANIFEST_BYTES: number = 4 * 1024 * 1024;
const MAX_ENTRIES: number = 200;
const COPY_BLOCK: number = 256 * 1024;
/** 一次最多导入的 .pcm 文件数 */
const MAX_RAW_FILES: number = 20;

/** 备份清单条目：只存元数据，音频按顺序紧跟在清单之后 */
interface BackupEntry {
  name: string;
  durationMs: number;
  byteLength: number;
  createdAt: number;
  sourceName: string;
}

interface BackupManifest {
  version: number;
  entries: BackupEntry[];
}

/** 导入结果：added 为成功入库数量，failed 为被跳过的文件数 */
export class BackupResult {
  added: number;
  failed: number;

  constructor(added: number, failed: number) {
    this.added = added;
    this.failed = failed;
  }
}

/**
 * 音效库备份与导入。
 *
 * 备份是一个自包含的单文件容器（`.boxtone`）：
 * 魔数 + 清单长度 + JSON 清单 + 按清单顺序拼接的原始 PCM。
 * 不依赖 zip 等额外能力，导出/解析都可离线完成，也便于用同一份逻辑做单测。
 */
export class ToneBackupService {
  /** 导出整库；用户取消返回空串 */
  public static async exportAll(context: common.UIAbilityContext): Promise<string> {
    const items: ToneEntry[] = ToneRepositoryService.list();
    if (items.length === 0) {
      throw new Error(I18n.t('backup.emptyLibrary'));
    }
    const manifest: BackupManifest = { version: 1, entries: [] };
    const buffers: Uint8Array[] = [];
    let total: number = 0;
    for (let i = 0; i < items.length; i++) {
      const entry: ToneEntry = items[i];
      const buffer: ArrayBuffer = ToneRepositoryService.readBuffer(entry);
      const bytes: Uint8Array = new Uint8Array(buffer);
      const item: BackupEntry = {
        name: entry.name,
        durationMs: entry.durationMs,
        byteLength: bytes.length,
        createdAt: entry.createdAt,
        sourceName: entry.sourceName
      };
      manifest.entries.push(item);
      buffers.push(bytes);
      total += bytes.length;
    }
    const manifestBytes: Uint8Array = ToneBackupService.encodeText(JSON.stringify(manifest));
    if (manifestBytes.length > MAX_MANIFEST_BYTES) {
      throw new Error(I18n.t('backup.tooLarge'));
    }

    const data: Uint8Array = new Uint8Array(HEADER_BYTES + manifestBytes.length + total);
    data.set(ToneBackupService.encodeText(BACKUP_MAGIC), 0);
    data.set(ToneBackupService.u32le(manifestBytes.length), 8);
    data.set(manifestBytes, HEADER_BYTES);
    let offset: number = HEADER_BYTES + manifestBytes.length;
    for (let i = 0; i < buffers.length; i++) {
      data.set(buffers[i], offset);
      offset += buffers[i].length;
    }

    const fileName: string = `boxtone-backup-${DateUtils.fileStamp(Date.now())}.boxtone`;
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.boxtone'];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0) {
      return '';
    }
    const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer);
    } finally {
      fs.closeSync(file);
    }
    Logger.info(MODULE, `已导出整库备份 ${fileName}：${items.length} 条 / ${total} 字节`);
    return fileName;
  }

  /** 从整库备份恢复：同名音效不会覆盖，按新条目追加 */
  public static async importBackup(context: common.UIAbilityContext): Promise<BackupResult> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.boxtone'];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0) {
      return new BackupResult(0, 0);
    }
    const temp: string = ToneBackupService.copyToTemp(context, uris[0], '.boxtone');
    try {
      const buffer: ArrayBuffer = ToneBackupService.readFile(temp);
      return ToneBackupService.restore(buffer);
    } finally {
      ToneBackupService.removeTemp(temp);
    }
  }

  /** 直接导入 .pcm / .raw：不经过 DSP，按 16700Hz 单声道 16bit 解读 */
  public static async importRawFiles(context: common.UIAbilityContext): Promise<BackupResult> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = MAX_RAW_FILES;
    options.fileSuffixFilters = ['.pcm', '.raw'];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0) {
      return new BackupResult(0, 0);
    }
    let added: number = 0;
    let failed: number = 0;
    for (let i = 0; i < uris.length; i++) {
      const temp: string = ToneBackupService.copyToTemp(context, uris[i], '.pcm');
      try {
        const buffer: ArrayBuffer = ToneBackupService.readFile(temp);
        ToneRepositoryService.importTone(
          ToneBackupService.fileBaseName(uris[i]), buffer, I18n.t('repo.importSource'));
        added++;
      } catch (error) {
        failed++;
        Logger.warn(MODULE, `导入 ${ToneBackupService.fileBaseName(uris[i])} 失败：` +
          `${(error as BusinessError).message}`);
      } finally {
        ToneBackupService.removeTemp(temp);
      }
    }
    Logger.info(MODULE, `导入音效文件完成：成功 ${added}，失败 ${failed}`);
    return new BackupResult(added, failed);
  }

  /**
   * 解析并还原备份。
   * 只信任清单里的长度字段，但总长度必须与文件剩余字节严格相等，
   * 否则宁可整份拒绝，也不写出半条数据。
   */
  private static restore(buffer: ArrayBuffer): BackupResult {
    const bytes: Uint8Array = new Uint8Array(buffer);
    if (bytes.length < HEADER_BYTES) {
      throw new Error(I18n.t('backup.badFormat'));
    }
    if (ToneBackupService.decodeText(bytes, 0, BACKUP_MAGIC.length) !== BACKUP_MAGIC) {
      throw new Error(I18n.t('backup.badFormat'));
    }
    const manifestLength: number = ToneBackupService.readU32le(bytes, 8);
    if (manifestLength <= 0 || manifestLength > MAX_MANIFEST_BYTES ||
      HEADER_BYTES + manifestLength > bytes.length) {
      throw new Error(I18n.t('backup.badFormat'));
    }
    let manifest: BackupManifest = { version: 1, entries: [] };
    try {
      const manifestText: string = ToneBackupService.decodeText(bytes, HEADER_BYTES, manifestLength);
      manifest = JSON.parse(manifestText) as BackupManifest;
    } catch (error) {
      throw new Error(I18n.t('backup.badFormat'));
    }
    const entries: BackupEntry[] = manifest.entries;
    if (entries === undefined || entries === null || entries.length === 0 ||
      entries.length > MAX_ENTRIES) {
      throw new Error(I18n.t('backup.badFormat'));
    }
    let total: number = 0;
    for (let i = 0; i < entries.length; i++) {
      total += entries[i].byteLength;
    }
    if (HEADER_BYTES + manifestLength + total !== bytes.length) {
      throw new Error(I18n.t('backup.badFormat'));
    }

    let offset: number = HEADER_BYTES + manifestLength;
    let added: number = 0;
    let failed: number = 0;
    for (let i = 0; i < entries.length; i++) {
      const entry: BackupEntry = entries[i];
      const pcm: Uint8Array = bytes.slice(offset, offset + entry.byteLength);
      offset += entry.byteLength;
      const name: string = entry.name !== undefined && entry.name.length > 0
        ? entry.name : I18n.t('repo.importDefaultName');
      const source: string = entry.sourceName !== undefined && entry.sourceName.length > 0
        ? entry.sourceName : I18n.t('repo.importSource');
      const created: number = entry.createdAt !== undefined && entry.createdAt > 0 ? entry.createdAt : 0;
      // Uint8Array 的 buffer 是 ArrayBufferLike，ArkTS 不做结构化兼容，复制成精确长度的 ArrayBuffer
      const pcmBuffer: ArrayBuffer = new ArrayBuffer(pcm.length);
      new Uint8Array(pcmBuffer).set(pcm);
      try {
        ToneRepositoryService.importTone(name, pcmBuffer, source, created);
        added++;
      } catch (error) {
        failed++;
        Logger.warn(MODULE, `恢复「${name}」失败：${(error as BusinessError).message}`);
      }
    }
    Logger.info(MODULE, `备份恢复完成：成功 ${added}，失败 ${failed}`);
    return new BackupResult(added, failed);
  }

  /** 把选择器给的 URI 复制进缓存目录：文档 URI 不能直接当路径做 stat */
  private static copyToTemp(context: common.UIAbilityContext, uri: string, suffix: string): string {
    const temp: string = `${context.cacheDir}/boxtone-${Date.now()}${suffix}`;
    const source: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let sink: fs.File | null = null;
    try {
      sink = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const block: ArrayBuffer = new ArrayBuffer(COPY_BLOCK);
      let total: number = 0;
      while (true) {
        const read: number = fs.readSync(source.fd, block, { length: block.byteLength });
        if (read <= 0) {
          break;
        }
        fs.writeSync(sink.fd, block, { length: read });
        total += read;
      }
      if (total <= 0) {
        throw new Error(I18n.t('backup.emptyFile'));
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
          Logger.warn(MODULE, '关闭缓存文件失败');
        }
      }
    }
    return temp;
  }

  private static readFile(path: string): ArrayBuffer {
    const size: number = fs.statSync(path).size;
    if (size <= 0) {
      throw new Error(I18n.t('backup.emptyFile'));
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer, { offset: 0, length: size });
    } finally {
      fs.closeSync(file);
    }
    return buffer;
  }

  private static removeTemp(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      Logger.warn(MODULE, '清理备份缓存失败');
    }
  }

  /** 文件名去掉路径与扩展名，作为音效名 */
  private static fileBaseName(uri: string): string {
    const index: number = uri.lastIndexOf('/');
    const segment: string = index >= 0 ? uri.substring(index + 1) : uri;
    let name: string = segment;
    try {
      name = decodeURIComponent(segment);
    } catch (error) {
      name = segment;
    }
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    return base.trim().length > 0 ? base.trim() : I18n.t('repo.importDefaultName');
  }

  private static encodeText(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(text);
  }

  private static decodeText(bytes: Uint8Array, offset: number, length: number): string {
    const slice: Uint8Array = bytes.slice(offset, offset + length);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(slice);
  }

  private static u32le(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(4);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    out[2] = (value >>> 16) & 0xFF;
    out[3] = (value >>> 24) & 0xFF;
    return out;
  }

  private static readU32le(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8) |
      ((bytes[offset + 2] & 0xFF) << 16) | ((bytes[offset + 3] & 0xFF) << 24);
  }
}