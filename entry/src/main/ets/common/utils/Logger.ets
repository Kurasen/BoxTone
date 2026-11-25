import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogLevel, LogTag } from '../constants/AppConstants';
import { AppEnv } from './AppEnv';

export type LogSink = (level: LogLevel, module: string, message: string) => void;

/**
 * 统一日志出口：封装 hilog，并向日志中心（LogService）投放数据
 * 注意：此处不直接依赖 LogService，避免循环引用
 */
export class Logger {
  private static sink: LogSink | undefined = undefined;

  public static setSink(sink: LogSink): void {
    Logger.sink = sink;
  }

  /**
   * 调试级日志：release 构建直接丢弃，既不写 hilog 也不进日志中心。
   *
   * 这条门控是「正式包不在用户设备上留报文」的关键：ToneClient 的 SPP 收发帧
   * 全部走这里，release 下连字符串都不会落盘（日志中心 2MB 上限里不会出现设备地址）。
   */
  public static debug(module: string, message: string): void {
    if (!AppEnv.isDebug()) {
      return;
    }
    hilog.debug(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s', module, message);
    Logger.dispatch(LogLevel.DEBUG, module, message);
  }

  public static info(module: string, message: string): void {
    hilog.info(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s', module, message);
    Logger.dispatch(LogLevel.INFO, module, message);
  }

  public static warn(module: string, message: string): void {
    hilog.warn(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s', module, message);
    Logger.dispatch(LogLevel.WARN, module, message);
  }

  public static error(module: string, message: string): void {
    hilog.error(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s', module, message);
    Logger.dispatch(LogLevel.ERROR, module, message);
  }

  /**
   * 仅开发期输出：release 构建直接丢弃。
   *
   * debug 包本身是给开发/测试用的，日志中心里记一份方便排查；
   * release 包连 hilog 都不写，用户翻日志中心也看不到任何内部判断过程。
   */
  public static dev(module: string, message: string): void {
    if (!AppEnv.isDebug()) {
      return;
    }
    hilog.debug(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s', module, message);
    Logger.dispatch(LogLevel.DEBUG, module, message);
  }

  /** 记录异常，自动展开 code / message / stack */
  public static exception(module: string, context: string, error: object): void {
    const detail: string = Logger.describeError(error);
    hilog.error(LogTag.DOMAIN, LogTag.TAG, '[%{public}s] %{public}s: %{public}s', module, context, detail);
    Logger.dispatch(LogLevel.ERROR, module, `${context} → ${detail}`);
  }

  private static describeError(error: object): string {
    const businessError: BusinessError = error as BusinessError;
    const parts: string[] = [];
    const name: string | undefined = businessError.name;
    if (name !== undefined && name !== null && name.length > 0) {
      parts.push(`name=${name}`);
    }
    const code: number | undefined = businessError.code;
    if (code !== undefined && code !== null) {
      parts.push(`code=${code}`);
    }
    const message: string | undefined = businessError.message;
    if (message !== undefined && message !== null && message.length > 0) {
      parts.push(`msg=${message}`);
    }
    if (parts.length === 0) {
      return 'unknown error';
    }
    return parts.join(' ');
  }

  private static dispatch(level: LogLevel, module: string, message: string): void {
    const handler: LogSink | undefined = Logger.sink;
    if (handler !== undefined) {
      handler(level, module, message);
    }
  }
}
