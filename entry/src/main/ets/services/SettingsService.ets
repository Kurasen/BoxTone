import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKey } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'Settings';

export interface AppSettings {
  /** 新建音效的默认时长（毫秒） */
  defaultDurationMs: number;
  /** 默认增益 dB */
  defaultGainDb: number;
  /** 是否默认归一化 */
  autoNormalize: boolean;
}

/**
 * 轻量设置存储（Preferences）
 */
export class SettingsService {
  private static store: preferences.Preferences | undefined = undefined;
  private static current: AppSettings = { defaultDurationMs: 2000, defaultGainDb: 0, autoNormalize: true };

  public static init(context: common.UIAbilityContext): void {
    const options: preferences.Options = { name: AppStorageKey.PREFS_NAME };
    try {
      SettingsService.store = preferences.getPreferencesSync(context, options);
      SettingsService.current = SettingsService.read();
      Logger.info(MODULE, `设置已加载 时长=${SettingsService.current.defaultDurationMs}ms`);
    } catch (error) {
      Logger.exception(MODULE, '读取设置失败', error as BusinessError);
    }
  }

  private static read(): AppSettings {
    const store: preferences.Preferences | undefined = SettingsService.store;
    const settings: AppSettings = { defaultDurationMs: 2000, defaultGainDb: 0, autoNormalize: true };
    if (store === undefined) {
      return settings;
    }
    settings.defaultDurationMs = store.getSync(AppStorageKey.KEY_DEFAULT_DURATION, 2000) as number;
    settings.defaultGainDb = store.getSync(AppStorageKey.KEY_DEFAULT_GAIN, 0) as number;
    settings.autoNormalize = store.getSync(AppStorageKey.KEY_AUTO_NORMALIZE, true) as boolean;
    return settings;
  }

  public static get(): AppSettings {
    return SettingsService.current;
  }

  public static setDefaultDuration(ms: number): void {
    SettingsService.current.defaultDurationMs = ms;
    SettingsService.put(AppStorageKey.KEY_DEFAULT_DURATION, ms);
  }

  public static setDefaultGain(db: number): void {
    SettingsService.current.defaultGainDb = db;
    SettingsService.put(AppStorageKey.KEY_DEFAULT_GAIN, db);
  }

  public static setAutoNormalize(enabled: boolean): void {
    SettingsService.current.autoNormalize = enabled;
    SettingsService.put(AppStorageKey.KEY_AUTO_NORMALIZE, enabled);
  }

  /** 外观模式：0 深色 / 1 浅色 / 2 跟随系统（默认深色，保持原有视觉） */
  public static getThemeMode(): number {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return 0;
    }
    return store.getSync(AppStorageKey.KEY_THEME_MODE, 0) as number;
  }

  public static setThemeMode(mode: number): void {
    SettingsService.put(AppStorageKey.KEY_THEME_MODE, mode);
  }

  private static put(key: string, value: number | boolean): void {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      Logger.exception(MODULE, `写入设置 ${key} 失败`, error as BusinessError);
    }
  }
}
