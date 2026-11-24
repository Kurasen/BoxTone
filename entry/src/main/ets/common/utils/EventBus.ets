import { emitter } from '@kit.BasicServicesKit';

/**
 * 轻量事件总线：解耦页面之间的数据刷新
 * 使用 emitter 而非全局状态，避免跨版本装饰器差异
 */
export class AppEvent {
  /** 音效库发生变化（新增 / 删除 / 重命名） */
  static readonly TONE_CHANGED: number = 3001;
  /** 打开日志中心 */
  static readonly OPEN_LOG: number = 3004;
  /** 打开反馈与建议 */
  static readonly OPEN_FEEDBACK: number = 3006;
  /** 全屏忙碌遮罩：payload 为空串表示收起 */
  static readonly BUSY_CHANGED: number = 3005;
  /** 忙碌遮罩的进度明细（JSON 字符串，见 BusyState） */
  static readonly BUSY_PROGRESS: number = 3010;
  /** 托管隐私弹窗已签署同意，业务服务完成初始化 */
  static readonly PRIVACY_READY: number = 3007;
  /** 打开支持机型页 */
  static readonly OPEN_DEVICE_SUPPORT: number = 3008;
  /** 打开更新日志 */
  static readonly OPEN_CHANGELOG: number = 3009;
  /** 打开备份与导入页 */
  static readonly OPEN_BACKUP: number = 3011;
}

export type SimpleHandler = (payload: number) => void;
export type TextHandler = (payload: string) => void;

/** 忙碌遮罩明细：进度为 -1 时显示不确定进度 */
export interface BusyState {
  text: string;
  detail: string;
  progress: number;
  cancellable: boolean;
}

export class EventBus {
  public static on(eventId: number, handler: SimpleHandler): void {
    const event: emitter.InnerEvent = { eventId: eventId };
    const callback: (data: emitter.EventData) => void = (data: emitter.EventData): void => {
      let value: number = 0;
      const payload: Record<string, Object> | undefined = data.data;
      if (payload !== undefined && payload !== null) {
        const raw: Object | undefined = payload['value'];
        if (raw !== undefined && raw !== null) {
          value = raw as number;
        }
      }
      handler(value);
    };
    emitter.on(event, callback);
  }

  public static off(eventId: number): void {
    emitter.off(eventId);
  }

  public static emit(eventId: number, payload: number = 0): void {
    const event: emitter.InnerEvent = { eventId: eventId };
    const data: emitter.EventData = { data: { value: payload } };
    emitter.emit(event, data);
  }

  public static onText(eventId: number, handler: TextHandler): void {
    const event: emitter.InnerEvent = { eventId: eventId };
    const callback: (data: emitter.EventData) => void = (data: emitter.EventData): void => {
      let value: string = '';
      const payload: Record<string, Object> | undefined = data.data;
      if (payload !== undefined && payload !== null) {
        const raw: Object | undefined = payload['value'];
        if (raw !== undefined && raw !== null) {
          value = raw as string;
        }
      }
      handler(value);
    };
    emitter.on(event, callback);
  }

  public static emitText(eventId: number, payload: string): void {
    const event: emitter.InnerEvent = { eventId: eventId };
    const data: emitter.EventData = { data: { value: payload } };
    emitter.emit(event, data);
  }

  /** 更新遮罩的进度、剩余时间与取消按钮 */
  public static emitBusy(state: BusyState): void {
    EventBus.emitText(AppEvent.BUSY_PROGRESS, JSON.stringify(state));
  }

  public static resetBusy(): void {
    EventBus.emitText(AppEvent.BUSY_PROGRESS, '');
  }
}
