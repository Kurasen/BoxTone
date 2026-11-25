import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKey } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'Settings';

/**
 * 外观模式默认值：2 = 跟随系统。
 * 与 ThemeService.ThemeMode.SYSTEM 对应，这里写数字是为了避免 ThemeService ↔ SettingsService 循环依赖。
 */
const THEME_MODE_DEFAULT: number = 2;

export interface AppSettings {
  /** 新建音效的默认时长（毫秒） */
  defaultDurationMs: number;
  /** 默认增益 dB */
  defaultGainDb: number;
  /** 是否默认归一化 */
  autoNormalize: boolean;
}

/** 评分相关计数的快照：测试入口改完这些值之后要原样还回去 */
export interface RatingState {
  writeCount: number;
  firstUseAt: number;
  lastFailAt: number;
  askedAt: number;
}

/**
 * 轻量设置存储（Preferences）
 */
export class SettingsService {
  private static store: preferences.Preferences | undefined = undefined;
  private static current: AppSettings = { defaultDurationMs: 2000, defaultGainDb: 0, autoNormalize: true };

  /** 在 EntryAbility.onCreate 最早调用（早于 ThemeService）；本地 Preferences，不涉及个人信息，可在隐私同意前加载 */
  public static init(context: common.UIAbilityContext): void {
    if (SettingsService.store !== undefined) {
      return;
    }
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

  /**
   * 外观模式：0 深色 / 1 浅色 / 2 跟随系统。
   * 默认跟随系统：首次打开时按用户设备的深浅色显示，不做强制深色。
   */
  public static getThemeMode(): number {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return THEME_MODE_DEFAULT;
    }
    return store.getSync(AppStorageKey.KEY_THEME_MODE, THEME_MODE_DEFAULT) as number;
  }

  public static setThemeMode(mode: number): void {
    SettingsService.put(AppStorageKey.KEY_THEME_MODE, mode);
  }

  /**
   * 盒内当前音效。
   *
   * 协议没有读取「槽位里是哪条音效」的接口，只能记住本应用最近一次确认写入成功的那条。
   * 恢复默认、切换内置音效、写入失败时都会清空，避免界面标着一条其实已经不在盒里的音效。
   */
  public static getLastWrittenTone(): string {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return '';
    }
    const value: string = store.getSync(AppStorageKey.KEY_LAST_WRITTEN_TONE, '') as string;
    return value !== undefined && value !== null ? value : '';
  }

  public static setLastWrittenTone(toneId: string): void {
    SettingsService.put(AppStorageKey.KEY_LAST_WRITTEN_TONE, toneId);
  }

  /** 设置存储是否已就绪：依赖「只做一次」判断的功能（如评分）必须等它 */
  public static isReady(): boolean {
    return SettingsService.store !== undefined;
  }

  // ---- 应用评分的判断依据 ----

  /** 成功写入一次：累加计数，首次成功时记下「开始使用」的时间 */
  public static recordWriteSuccess(): void {
    const count: number = SettingsService.getNumber(AppStorageKey.KEY_WRITE_SUCCESS_COUNT, 0) + 1;
    SettingsService.put(AppStorageKey.KEY_WRITE_SUCCESS_COUNT, count);
    if (SettingsService.getNumber(AppStorageKey.KEY_FIRST_USE_AT, 0) === 0) {
      SettingsService.put(AppStorageKey.KEY_FIRST_USE_AT, Date.now());
    }
  }

  /** 写入失败：记下时间，七天内不再请求评分 */
  public static recordWriteFailure(): void {
    SettingsService.put(AppStorageKey.KEY_LAST_WRITE_FAIL_AT, Date.now());
  }

  public static getWriteSuccessCount(): number {
    return SettingsService.getNumber(AppStorageKey.KEY_WRITE_SUCCESS_COUNT, 0);
  }

  public static getFirstUseAt(): number {
    return SettingsService.getNumber(AppStorageKey.KEY_FIRST_USE_AT, 0);
  }

  public static getLastWriteFailureAt(): number {
    return SettingsService.getNumber(AppStorageKey.KEY_LAST_WRITE_FAIL_AT, 0);
  }

  /** 「下次最早可再问」的时间戳：0 表示从未请求过 */
  public static getRatingAskedAt(): number {
    return SettingsService.getNumber(AppStorageKey.KEY_RATING_ASKED_AT, 0);
  }

  /**
   * 记下「下次最早可再问」的时间戳。
   * 传绝对时间戳则按它记（由上次弹窗结果决定冷却时长）；不传则记当前时间。
   */
  public static markRatingAsked(at?: number): void {
    SettingsService.put(AppStorageKey.KEY_RATING_ASKED_AT, at !== undefined ? at : Date.now());
  }

  public static snapshotRating(): RatingState {
    const state: RatingState = {
      writeCount: SettingsService.getWriteSuccessCount(),
      firstUseAt: SettingsService.getFirstUseAt(),
      lastFailAt: SettingsService.getLastWriteFailureAt(),
      askedAt: SettingsService.getRatingAskedAt()
    };
    return state;
  }

  public static restoreRating(state: RatingState): void {
    SettingsService.put(AppStorageKey.KEY_WRITE_SUCCESS_COUNT, state.writeCount);
    SettingsService.put(AppStorageKey.KEY_FIRST_USE_AT, state.firstUseAt);
    SettingsService.put(AppStorageKey.KEY_LAST_WRITE_FAIL_AT, state.lastFailAt);
    SettingsService.put(AppStorageKey.KEY_RATING_ASKED_AT, state.askedAt);
  }

  /**
   * 仅供测试：把评分的前置条件一次性置为「刚好满足」。
   * 写入 2 次、三天前开始使用、没有失败记录、从未请求过。
   */
  public static seedRatingSatisfied(): void {
    const threeDaysAgo: number = Date.now() - 3 * 24 * 60 * 60 * 1000;
    SettingsService.put(AppStorageKey.KEY_WRITE_SUCCESS_COUNT, 2);
    SettingsService.put(AppStorageKey.KEY_FIRST_USE_AT, threeDaysAgo);
    SettingsService.put(AppStorageKey.KEY_LAST_WRITE_FAIL_AT, 0);
    SettingsService.put(AppStorageKey.KEY_RATING_ASKED_AT, 0);
  }

  private static getNumber(key: string, fallback: number): number {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return fallback;
    }
    return store.getSync(key, fallback) as number;
  }

  private static put(key: string, value: number | boolean | string): void {
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
