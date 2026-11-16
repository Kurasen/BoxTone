import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { LogLevel } from '../common/constants/AppConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { LogEntry } from '../models/LogModel';

const MODULE: string = 'LogService';
/** 内存中最多保留的日志条数 */
const MAX_MEMORY_ENTRIES: number = 600;
/** 累积多少条后落盘 */
const FLUSH_THRESHOLD: number = 12;

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
    const today: string = DateUtils.fileStamp(Date.now()).substring(0, 8);
    this.logFilePath = `${dir}/boxtone-${today}.log`;
    Logger.setSink((level: LogLevel, module: string, message: string): void => {
      this.append(level, module, message);
    });
    this.append(LogLevel.INFO, MODULE, '日志中心已启动');
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
    try {
      if (fs.accessSync(this.logFilePath)) {
        fs.unlinkSync(this.logFilePath);
      }
    } catch (error) {
      Logger.exception(MODULE, '清空日志文件失败', error as BusinessError);
    }
    this.append(LogLevel.INFO, MODULE, '日志已清空');
  }

  /** 生成可导出的报告文本 */
  public buildReport(): string {
    this.flush();
    const lines: string[] = [];
    lines.push('==== 盒音工坊 诊断日志 ====');
    lines.push(`导出时间：${DateUtils.dateTime(Date.now())}`);
    lines.push(`条目数量：${this.entries.length}`);
    lines.push(`系统版本：${this.systemVersion()}`);
    lines.push('----------------------------');
    // 先输出错误，便于快速定位
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].level === LogLevel.ERROR) {
        lines.push(this.formatLine(this.entries[i]));
      }
    }
    lines.push('------ 全部记录 ------');
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
      throw new Error('日志服务未初始化');
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
