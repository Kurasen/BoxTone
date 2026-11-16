import { LogLevel } from '../common/constants/AppConstants';

export interface LogEntry {
  id: string;
  /** D / I / W / E */
  level: string;
  module: string;
  message: string;
  timestamp: number;
}

export interface LogFilterOption {
  key: string;
  label: string;
  /** 需要显示的级别，空数组表示全部 */
  levels: string[];
}

export const LOG_FILTERS: LogFilterOption[] = [
  { key: 'all', label: '全部', levels: [] },
  { key: 'warn', label: '警告及以上', levels: [LogLevel.WARN, LogLevel.ERROR] },
  { key: 'error', label: '仅错误', levels: [LogLevel.ERROR] }
];

export class LogLevelStyle {
  public static colorOf(level: string): string {
    if (level === LogLevel.ERROR) {
      return '#FF6B7A';
    }
    if (level === LogLevel.WARN) {
      return '#FFB84D';
    }
    if (level === LogLevel.INFO) {
      return '#4ED8FF';
    }
    return '#5E697B';
  }

  public static labelOf(level: string): string {
    if (level === LogLevel.ERROR) {
      return '错误';
    }
    if (level === LogLevel.WARN) {
      return '警告';
    }
    if (level === LogLevel.INFO) {
      return '信息';
    }
    return '调试';
  }
}
