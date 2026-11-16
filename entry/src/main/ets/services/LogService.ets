import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { LogLevel } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { LogEntry } from '../models/LogModel';

const MODULE: string = 'LogService';
/** 内存中最多保留的日志条数 */
const MAX_MEMORY_ENTRIES: number = 600;
/** 累积多少条后落盘 */
const FLUSH_THRESHOLD: number = 12;
/** 历史日志保留天数（含今天） */
const LOG_RETENTION_DAYS: number = 7;
/** 历史日志总占用上限：超出后从最旧的开始删 */
const LOG_TOTAL_MAX_BYTES: number = 2 * 1024 * 1024;
const LOG_FILE_PREFIX: string = 'boxtone-';
const LOG_FILE_SUFFIX: string = '.log';

interface LogFileInfo {
  name: string;
  path: string;
  size: number;
  /** 文件名里的 yyyyMMdd，用于判断新旧 */
  day: number;
}

export type LogChangeListener = (entries: LogEntry[]) => void;

/**
 * 日志中心：收集全局日志，支持落盘、导出、复制
 * 导出格式为 UTF-8 纯文本，便于反馈问题
 */
export class LogService {
  private static instance: LogService | undefined = undefined;

  private entries: LogEntry[] = [];
  private pending: string[] = [];
  private listeners: LogChangeListener[] = [];
  private context?: common.UIAbilityContext;
  private logFilePath: string = '';
  private sequence: number = 0;
  private dirty: boolean = false;

  public static getInstance(): LogService {
    if (LogService.instance === undefined) {
      LogService.instance = new LogService();
    }
    return LogService.instance;
  }

  public init(context: common.UIAbilityContext): void {
    this.context = context;
    const dir: string = `${context.filesDir}/logs`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    LogService.pruneLogs(dir);
    const today: string = DateUtils.fileStamp(Date.now()).substring(0, 8);
    this.logFilePath = `${dir}/boxtone-${today}.log`;
    Logger.setSink((level: LogLevel, module: string, message: string): void => {
      this.append(level, module, message);
    });
    this.append(LogLevel.INFO, MODULE, '日志中心已启动');
  }

  /**
   * 启动时清理历史日志：
   * 1. 删除保留期之外的文件；
   * 2. 总量超过上限时从最旧的开始删。
   * 日期直接读文件名，避免依赖 stat.mtime 的单位差异。
   */
  private static pruneLogs(dir: string): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (error) {
      Logger.warn(MODULE, '读取日志目录失败，跳过清理');
      return;
    }
    const files: LogFileInfo[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!name.startsWith(LOG_FILE_PREFIX) || !name.endsWith(LOG_FILE_SUFFIX)) {
        continue;
      }
      const dayText: string = name.substring(LOG_FILE_PREFIX.length,
        name.length - LOG_FILE_SUFFIX.length);
      if (dayText.length !== 8) {
        continue;
      }
      const day: number = Number(dayText);
      if (isNaN(day)) {
        continue;
      }
      const path: string = `${dir}/${name}`;
      let size: number = 0;
      try {
        size = fs.statSync(path).size;
      } catch (error) {
        continue;
      }
      files.push({ name: name, path: path, size: size, day: day });
    }
    if (files.length === 0) {
      return;
    }
    const cutoffDate: Date = new Date(Date.now() - (LOG_RETENTION_DAYS - 1) * 86400000);
    const cutoff: number = cutoffDate.getFullYear() * 10000 +
      (cutoffDate.getMonth() + 1) * 100 + cutoffDate.getDate();
    const remain: LogFileInfo[] = [];
    let total: number = 0;
    let expired: number = 0;
    for (let i = 0; i < files.length; i++) {
      if (files[i].day < cutoff) {
        if (LogService.unlinkQuietly(files[i].path)) {
          expired++;
        }
        continue;
      }
      remain.push(files[i]);
      total += files[i].size;
    }
    remain.sort((a: LogFileInfo, b: LogFileInfo): number => a.day - b.day);
    let oversized: number = 0;
    let index: number = 0;
    // 至少保留最新一份，哪怕它自己就超过上限
    while (total > LOG_TOTAL_MAX_BYTES && index < remain.length - 1) {
      if (LogService.unlinkQuietly(remain[index].path)) {
        total -= remain[index].size;
        oversized++;
      }
      index++;
    }
    if (expired > 0 || oversized > 0) {
      Logger.info(MODULE, `日志清理完成：过期 ${expired} 份，超量 ${oversized} 份，保留 ${remain.length - oversized} 份`);
    }
  }

  private static unlinkQuietly(path: string): boolean {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
        return true;
      }
    } catch (error) {
      Logger.warn(MODULE, `删除日志失败 ${path.substring(path.lastIndexOf('/') + 1)}`);
    }
    return false;
  }

  public append(level: LogLevel, module: string, message: string): void {
    this.sequence++;
    const entry: LogEntry = {
      id: `log-${this.sequence}`,
      level: level as string,
      module: module,
      message: message,
      timestamp: Date.now()
    };
    this.entries.push(entry);
    if (this.entries.length > MAX_MEMORY_ENTRIES) {
      this.entries.splice(0, this.entries.length - MAX_MEMORY_ENTRIES);
    }
    this.pending.push(this.formatLine(entry));
    this.dirty = true;
    // 错误立即落盘：进程被系统杀掉时，缓冲区里没刷下去的内容会一起消失
    if (this.pending.length >= FLUSH_THRESHOLD || level === LogLevel.ERROR) {
      this.flush();
    }
    this.notify();
  }

  private formatLine(entry: LogEntry): string {
    return `${DateUtils.dateTime(entry.timestamp)} ${DateUtils.timeWithMillis(entry.timestamp)} ` +
      `[${entry.level}] ${entry.module}: ${entry.message}`;
  }

  /** 把缓冲区内容写入日志文件 */
  public flush(): void {
    if (this.pending.length === 0 || this.logFilePath.length === 0) {
      return;
    }
    const payload: string = `${this.pending.join('\n')}\n`;
    this.pending = [];
    try {
      const file: fs.File = fs.openSync(this.logFilePath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, payload);
      fs.closeSync(file);
    } catch (error) {
      Logger.exception(MODULE, '写入日志文件失败', error as BusinessError);
    }
  }

  public getEntries(): LogEntry[] {
    return this.entries;
  }

  public countOf(level: string): number {
    let count: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].level === level) {
        count++;
      }
    }
    return count;
  }

  public getEntryCount(): number {
    return this.entries.length;
  }

  /** 日志文件占用的字节数 */
  public getLogFileSize(): number {
    try {
      if (this.logFilePath.length === 0 || !fs.accessSync(this.logFilePath)) {
        return 0;
      }
      return fs.statSync(this.logFilePath).size;
    } catch (error) {
      return 0;
    }
  }

  public onChange(listener: LogChangeListener): void {
    this.listeners.push(listener);
  }

  public offChange(listener: LogChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notify(): void {
    if (!this.dirty) {
      return;
    }
    this.dirty = false;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](this.entries);
    }
  }

  public clear(): void {
    this.entries = [];
    this.pending = [];
    let removed: number = 0;
    const context: common.UIAbilityContext | undefined = this.context;
    if (context !== undefined) {
      const dir: string = `${context.filesDir}/logs`;
      try {
        const names: string[] = fs.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          if (!names[i].startsWith(LOG_FILE_PREFIX) || !names[i].endsWith(LOG_FILE_SUFFIX)) {
            continue;
          }
          if (LogService.unlinkQuietly(`${dir}/${names[i]}`)) {
            removed++;
          }
        }
      } catch (error) {
        Logger.warn(MODULE, `读取日志目录失败 code=${(error as BusinessError).code}`);
      }
    }
    if (removed === 0 && this.logFilePath.length > 0) {
      LogService.unlinkQuietly(this.logFilePath);
    }
    Logger.info(MODULE, `已清空日志文件 ${removed} 份`);
    this.append(LogLevel.INFO, MODULE, '日志已清空');
  }

  /** 生成可导出的报告文本 */
  public buildReport(): string {
    this.flush();
    const lines: string[] = [];
    lines.push(I18n.t('log.reportHeader'));
    lines.push(I18n.f('log.reportTime', [DateUtils.dateTime(Date.now())]));
    lines.push(I18n.f('log.reportCount', [`${this.entries.length}`]));
    lines.push(I18n.f('log.reportSystem', [this.systemVersion()]));
    lines.push('----------------------------');
    // 先输出错误，便于快速定位
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].level === LogLevel.ERROR) {
        lines.push(this.formatLine(this.entries[i]));
      }
    }
    lines.push(I18n.t('log.reportAll'));
    for (let i = 0; i < this.entries.length; i++) {
      lines.push(this.formatLine(this.entries[i]));
    }
    return lines.join('\n');
  }

  private systemVersion(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return `versionName=${info.versionName} versionCode=${info.versionCode}`;
    } catch (error) {
      Logger.exception(MODULE, '读取版本信息失败', error as BusinessError);
      return 'unknown';
    }
  }

  /**
   * 导出日志到用户选择的目录
   * @returns 保存成功返回文件名，用户取消返回空串
   */
  public async exportToFile(): Promise<string> {
    if (this.context === undefined) {
      throw new Error(I18n.t('log.notReady'));
    }
    const fileName: string = `boxtone-log-${DateUtils.fileStamp(Date.now())}.txt`;
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.txt'];
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return '';
      }
      const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.buildReport());
      fs.closeSync(file);
      Logger.info(MODULE, `日志已导出：${fileName}`);
      return fileName;
    } catch (error) {
      Logger.exception(MODULE, '导出日志失败', error as BusinessError);
      throw error as Error;
    }
  }

  /** 复制全部日志到剪贴板 */
  public async copyToClipboard(): Promise<void> {
    try {
      const report: string = this.buildReport();
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, report);
      await pasteboard.getSystemPasteboard().setData(data);
      Logger.info(MODULE, '日志已复制到剪贴板');
    } catch (error) {
      Logger.exception(MODULE, '复制日志失败', error as BusinessError);
      throw error as Error;
    }
  }
}
