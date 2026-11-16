import { common, bundleManager } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKey, SupportInfo } from '../common/constants/AppConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { Logger } from '../common/utils/Logger';
import { BluetoothService } from './BluetoothService';
import { FeedbackApiService, FeedbackPayload } from './FeedbackApiService';
import { LogService } from './LogService';

const MODULE: string = 'Feedback';
/** 日志附件上限：按字符截断，中文最坏情况约 360KB，不会超过 512KB */
const LOG_MAX_CHARS: number = 120000;
export const IMAGE_MAX_BYTES: number = 4 * 1024 * 1024;
export const MAX_IMAGES: number = 3;
/** 上报时所有截图 base64 后的总量上限，避免请求体过大 */
const IMAGES_TOTAL_MAX_BYTES: number = 8 * 1024 * 1024;
const MAX_RECORDS: number = 50;

export interface FeedbackTypeOption {
  key: string;
  label: string;
}

export const FEEDBACK_TYPES: FeedbackTypeOption[] = [
  { key: 'bug', label: '问题反馈' },
  { key: 'feature', label: '功能建议' },
  { key: 'ux', label: '体验问题' },
  { key: 'other', label: '其他' }
];

export interface FeedbackDraft {
  typeLabel: string;
  description: string;
  contact: string;
  /** 已复制到沙箱的截图路径 */
  imagePaths: string[];
}

export interface SubmitOutcome {
  ok: boolean;
  channel: string;
  message: string;
}

export interface FeedbackRecord {
  id: string;
  typeLabel: string;
  description: string;
  contact: string;
  createdAt: number;
  channel: string;
  status: string;
}

/**
 * 反馈服务：整理诊断日志、调用后端或系统分享、本地留存提交记录
 * 没有后端时退回系统分享，「我的反馈」只展示本机提交过的内容
 */
export class FeedbackService {
  private static context?: common.UIAbilityContext;
  private static store: preferences.Preferences | undefined = undefined;
  private static records: FeedbackRecord[] = [];

  public static init(context: common.UIAbilityContext): void {
    if (FeedbackService.context !== undefined) {
      return;
    }
    FeedbackService.context = context;
    try {
      const options: preferences.Options = { name: AppStorageKey.PREFS_NAME };
      FeedbackService.store = preferences.getPreferencesSync(context, options);
      FeedbackService.records = FeedbackService.readRecords();
      Logger.info(MODULE, `反馈记录已加载，共 ${FeedbackService.records.length} 条`);
    } catch (error) {
      Logger.exception(MODULE, '读取反馈记录失败', error as BusinessError);
    }
  }

  public static list(): FeedbackRecord[] {
    const copy: FeedbackRecord[] = [];
    for (let i = 0; i < FeedbackService.records.length; i++) {
      copy.push(FeedbackService.records[i]);
    }
    return copy;
  }

  public static async submit(draft: FeedbackDraft): Promise<SubmitOutcome> {
    const context: common.UIAbilityContext | undefined = FeedbackService.context;
    if (context === undefined) {
      return { ok: false, channel: '', message: '反馈服务未初始化，请重启应用后重试' };
    }
    try {
      const logText: string = FeedbackService.buildLogText(draft);
      const body: string = FeedbackService.buildBody(draft);
      const subject: string = `盒音工坊反馈 · ${draft.typeLabel}`;
      let channel: string = '';
      let imageCount: number = 0;

      if (FeedbackApiService.isConfigured()) {
        const images: string[] = FeedbackService.readImages(draft.imagePaths);
        imageCount = images.length;
        const payload: FeedbackPayload = {
          typeLabel: draft.typeLabel,
          description: draft.description,
          contact: draft.contact,
          device: FeedbackService.deviceName(),
          appVersion: FeedbackService.versionName(),
          createdAt: Date.now(),
          log: logText,
          images: images
        };
        await FeedbackApiService.submit(payload);
        channel = '服务器';
      } else {
        const logPath: string = FeedbackService.writeLogFile(logText, context);
        const paths: string[] = [logPath];
        for (let i = 0; i < draft.imagePaths.length; i++) {
          paths.push(draft.imagePaths[i]);
        }
        imageCount = draft.imagePaths.length;
        await FeedbackService.share(context, subject, body, paths);
        channel = '系统分享';
      }

      const record: FeedbackRecord = {
        id: `fb-${Date.now()}`,
        typeLabel: draft.typeLabel,
        description: draft.description,
        contact: draft.contact,
        createdAt: Date.now(),
        channel: channel,
        status: channel === '服务器' ? '已发送' : '已提交'
      };
      FeedbackService.saveRecord(record);
      Logger.info(MODULE, `反馈已提交 channel=${channel} 截图=${imageCount}`);
      return {
        ok: true,
        channel: channel,
        message: channel === '服务器'
          ? `已提交到反馈服务，附带 ${imageCount} 张截图`
          : `已准备好反馈内容与日志，正文已注明收件邮箱 ${SupportInfo.EMAIL}；若分享面板里没有完成发送，可再点一次提交`
      };
    } catch (error) {
      Logger.exception(MODULE, '提交反馈失败', error as BusinessError);
      const message: string = (error as Error).message !== undefined ? (error as Error).message : '未知错误';
      return { ok: false, channel: '', message: `提交失败：${message}` };
    }
  }

  /** 反馈正文 + 诊断日志，限制总长度 */
  private static buildLogText(draft: FeedbackDraft): string {
    let text: string = FeedbackService.buildBody(draft);
    text += '\n\n==== 诊断日志 ====\n';
    text += LogService.getInstance().buildReport();
    if (text.length > LOG_MAX_CHARS) {
      text = '（较早的日志已省略）\n' + text.substring(text.length - LOG_MAX_CHARS);
    }
    return text;
  }

  /** 系统分享时需要一个真实的 txt 文件 */
  private static writeLogFile(text: string, context: common.UIAbilityContext): string {
    const path: string = `${context.cacheDir}/boxtone-feedback-log.txt`;
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (error) {
      Logger.exception(MODULE, '写入反馈日志失败', error as BusinessError);
    }
    return path;
  }

  private static buildBody(draft: FeedbackDraft): string {
    const lines: string[] = [];
    lines.push('==== 盒音工坊 反馈 ====');
    lines.push(`请发送到：${SupportInfo.EMAIL}`);
    lines.push(`反馈类型：${draft.typeLabel}`);
    lines.push(`提交时间：${DateUtils.dateTime(Date.now())}`);
    lines.push(`应用版本：${FeedbackService.versionName()}`);
    lines.push(`耳机：${FeedbackService.deviceName()}`);
    lines.push(`联系方式：${draft.contact.length > 0 ? draft.contact : '未填写'}`);
    lines.push('');
    lines.push('描述：');
    lines.push(draft.description);
    return lines.join('\n');
  }

  /** 截图转 base64，超出总预算的跳过，避免请求体过大 */
  private static readImages(paths: string[]): string[] {
    const result: string[] = [];
    let total: number = 0;
    for (let i = 0; i < paths.length; i++) {
      try {
        const size: number = fs.statSync(paths[i]).size;
        if (size <= 0 || total + size > IMAGES_TOTAL_MAX_BYTES) {
          continue;
        }
        const file: fs.File = fs.openSync(paths[i], fs.OpenMode.READ_ONLY);
        try {
          const buffer: ArrayBuffer = new ArrayBuffer(size);
          const read: number = fs.readSync(file.fd, buffer);
          const bytes: Uint8Array = new Uint8Array(buffer, 0, read);
          result.push(new util.Base64Helper().encodeToStringSync(bytes));
          total += size;
        } finally {
          fs.closeSync(file);
        }
      } catch (error) {
        Logger.warn(MODULE, '读取截图失败，已跳过');
      }
    }
    return result;
  }

  /** 未配置后端时退回系统分享：用户自己选邮件或 QQ，日志已经作为附件带上 */
  private static async share(context: common.UIAbilityContext, subject: string,
    body: string, paths: string[]): Promise<void> {
    const first: systemShare.SharedRecord = {
      utd: 'general.plain-text',
      content: body,
      title: subject
    };
    const data: systemShare.SharedData = new systemShare.SharedData(first);
    for (let i = 0; i < paths.length; i++) {
      const record: systemShare.SharedRecord = {
        utd: 'general.file',
        uri: fileUri.getUriFromPath(paths[i]),
        title: paths[i].substring(paths[i].lastIndexOf('/') + 1)
      };
      data.addRecord(record);
    }
    const options: systemShare.ShareControllerOptions = {};
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    await controller.show(context, options);
  }

  private static versionName(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      return 'unknown';
    }
  }

  private static deviceName(): string {
    const name: string = BluetoothService.getSnapshot().activeName;
    return name.length > 0 ? name : '未连接耳机';
  }

  public static suffixOf(path: string): string {
    const dot: number = path.lastIndexOf('.');
    if (dot < 0 || dot < path.length - 6) {
      return '.jpg';
    }
    return path.substring(dot).toLowerCase();
  }

  private static readRecords(): FeedbackRecord[] {
    const store: preferences.Preferences | undefined = FeedbackService.store;
    if (store === undefined) {
      return [];
    }
    try {
      const text: string = store.getSync(AppStorageKey.KEY_FEEDBACK_RECORDS, '[]') as string;
      const parsed: FeedbackRecord[] = JSON.parse(text) as FeedbackRecord[];
      return parsed !== undefined && parsed !== null ? parsed : [];
    } catch (error) {
      Logger.warn(MODULE, '反馈记录损坏，已重置');
      return [];
    }
  }

  private static saveRecord(record: FeedbackRecord): void {
    FeedbackService.records.unshift(record);
    if (FeedbackService.records.length > MAX_RECORDS) {
      FeedbackService.records.splice(MAX_RECORDS, FeedbackService.records.length - MAX_RECORDS);
    }
    const store: preferences.Preferences | undefined = FeedbackService.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(AppStorageKey.KEY_FEEDBACK_RECORDS, JSON.stringify(FeedbackService.records));
      store.flush();
    } catch (error) {
      Logger.exception(MODULE, '保存反馈记录失败', error as BusinessError);
    }
  }
}
