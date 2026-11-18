import { LogLevel } from '../common/constants/AppConstants';
import { Palette } from '../common/constants/ThemeConstants';
import { I18n } from '../common/i18n/I18n';

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
  labelKey: string;
  /** 需要显示的级别，空数组表示全部 */
  levels: string[];
}

export const LOG_FILTERS: LogFilterOption[] = [
  { key: 'all', labelKey: 'log.all', levels: [] },
  { key: 'warn', labelKey: 'log.warnPlus', levels: [LogLevel.WARN, LogLevel.ERROR] },
  { key: 'error', labelKey: 'log.errorOnly', levels: [LogLevel.ERROR] }
];

export class LogLevelStyle {
  public static colorOf(level: string): string {
    if (level === LogLevel.ERROR) {
      return Palette.DANGER;
    }
    if (level === LogLevel.WARN) {
      return Palette.WARNING;
    }
    if (level === LogLevel.INFO) {
      return Palette.ACCENT_TEXT;
    }
    return Palette.TEXT_TERTIARY;
  }

  public static labelOf(level: string): string {
    if (level === LogLevel.ERROR) {
      return I18n.t('log.level.error');
    }
    if (level === LogLevel.WARN) {
      return I18n.t('log.level.warn');
    }
    if (level === LogLevel.INFO) {
      return I18n.t('log.level.info');
    }
    return I18n.t('log.level.debug');
  }
}
