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
  /** 打开支持机型页 */
  static readonly OPEN_DEVICE_SUPPORT: number = 3008;
  /** 打开更新日志 */
  static readonly OPEN_CHANGELOG: number = 3009;
  /** 打开备份与导入页 */
  static readonly OPEN_BACKUP: number = 3011;
  /** 隐私闸门放行（已同意 / 确认无从征询）：需要读文件、连设备的重活等这个事件再做 */
  static readonly PRIVACY_CLEARED: number = 3012;
  /** 仅 debug 包：内存压测——自动切页签，payload 为轮数（见 docs/stability-oom.md） */
  static readonly DEBUG_STRESS_TABS: number = 3013;
  /** 仅 debug 包：内存压测——自动切换内置音效，payload 为轮数 */
  static readonly DEBUG_STRESS_TONES: number = 3014;
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

/** 业务回调与实际注册给 emitter 的包装回调的对应关系：off 时要按包装回调精确移除 */
interface Binding {
  eventId: number;
  handler: SimpleHandler | TextHandler;
  callback: (data: emitter.EventData) => void;
}

/**
 * 订阅与取消必须成对使用同一个 handler 引用：
 *   EventBus.on(AppEvent.TONE_CHANGED, this.changeHandler);
 *   EventBus.off(AppEvent.TONE_CHANGED, this.changeHandler);
 * off 只移除这一个订阅，不影响其他页面对同一事件的监听。
 */
export class EventBus {
  private static bindings: Binding[] = [];

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
    EventBus.bindings.push({ eventId: eventId, handler: handler, callback: callback });
    emitter.on(event, callback);
  }

  /**
   * 取消一个订阅。
   * 不能用 emitter.off(eventId)：它会把这个事件的全部监听一起移除，
   * 例如 ProfilePage 与 LibraryPage 都订阅了 TONE_CHANGED，一方销毁会让另一方再也收不到刷新。
   */
  public static off(eventId: number, handler: SimpleHandler | TextHandler): void {
    for (let i = EventBus.bindings.length - 1; i >= 0; i--) {
      const binding: Binding = EventBus.bindings[i];
      if (binding.eventId === eventId && binding.handler === handler) {
        emitter.off(eventId, binding.callback);
        EventBus.bindings.splice(i, 1);
      }
    }
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
    EventBus.bindings.push({ eventId: eventId, handler: handler, callback: callback });
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
