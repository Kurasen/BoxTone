import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKey } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';
import { SettingsService } from './SettingsService';

const MODULE: string = 'Theme';

/** 外观模式：深色 / 浅色 / 跟随系统 */
export enum ThemeMode {
  DARK = 0,
  LIGHT = 1,
  SYSTEM = 2
}

/**
 * 全局外观管理
 *
 * 官方机制：ApplicationContext.setColorMode 控制应用级深浅色（系统弹窗、半模态、
 * HDS 底栏材质等都会跟随）；应用内配色由 Palette 依据 isDark() 返回两套值。
 * 切换后自增 AppStorage 里的主题纪元，组件通过 @StorageProp('themeEpoch') 触发重绘。
 */
export class ThemeService {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static mode: ThemeMode = ThemeMode.DARK;
  private static dark: boolean = true;
  /** 系统当前深浅色缓存：启动时读取，跟随系统模式下由配置回调更新 */
  private static systemDark: boolean = true;

  public static init(context: common.UIAbilityContext): void {
    ThemeService.context = context;
    ThemeService.systemDark = ThemeService.readSystemDark(context);
    const stored: number = SettingsService.getThemeMode();
    ThemeService.mode = stored === ThemeMode.LIGHT ? ThemeMode.LIGHT :
      (stored === ThemeMode.SYSTEM ? ThemeMode.SYSTEM : ThemeMode.DARK);
    // 此时窗口还没创建，系统栏属性由 EntryAbility.onWindowStageCreate 设置
    ThemeService.apply(false);
    Logger.info(MODULE, `外观初始化 mode=${ThemeService.mode} dark=${ThemeService.dark}`);
  }

  private static readSystemDark(context: common.UIAbilityContext): boolean {
    try {
      return context.resourceManager.getConfigurationSync().colorMode !== resourceManager.ColorMode.LIGHT;
    } catch (error) {
      Logger.warn(MODULE, `读取系统深浅色失败 code=${(error as BusinessError).code}`);
      return true;
    }
  }

  public static getMode(): ThemeMode {
    return ThemeService.mode;
  }

  public static isDark(): boolean {
    return ThemeService.dark;
  }

  public static setMode(mode: ThemeMode): void {
    if (ThemeService.mode === mode) {
      return;
    }
    ThemeService.mode = mode;
    SettingsService.setThemeMode(mode);
    ThemeService.apply();
    Logger.info(MODULE, `外观切换 mode=${ThemeService.mode} dark=${ThemeService.dark}`);
  }

  /** 跟随系统时系统深浅色变化会走这里；手动指定模式不会收到该回调 */
  public static onSystemColorChanged(config: Configuration): void {
    if (ThemeService.mode !== ThemeMode.SYSTEM) {
      return;
    }
    const nextDark: boolean = config.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    Logger.info(MODULE, `跟随系统外观变化 colorMode=${config.colorMode} dark=${nextDark}`);
    if (nextDark === ThemeService.dark) {
      return;
    }
    // 这里只重算配色并重绘，绝不能再调 setColorMode：
    // 否则会再次触发配置派发，形成 回调 → setColorMode → 回调 的死循环导致闪退
    ThemeService.systemDark = nextDark;
    ThemeService.dark = nextDark;
    ThemeService.updateSystemBars();
    ThemeService.refreshUI();
  }

  private static apply(updateBars: boolean = true): void {
    const context: common.UIAbilityContext | undefined = ThemeService.context;
    if (context === undefined) {
      return;
    }
    try {
      const appContext: common.ApplicationContext = context.getApplicationContext();
      let target: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (ThemeService.mode === ThemeMode.DARK) {
        target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      } else if (ThemeService.mode === ThemeMode.LIGHT) {
        target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      }
      appContext.setColorMode(target);
      if (ThemeService.mode === ThemeMode.DARK) {
        ThemeService.dark = true;
      } else if (ThemeService.mode === ThemeMode.LIGHT) {
        ThemeService.dark = false;
      } else {
        // 用启动时缓存的系统深浅色，避免在 setColorMode 生效瞬间读配置的竞态
        ThemeService.dark = ThemeService.systemDark;
      }
    } catch (error) {
      Logger.exception(MODULE, '设置应用外观失败', error as BusinessError);
    }
    if (updateBars) {
      ThemeService.updateSystemBars();
    }
    ThemeService.refreshUI();
  }

  /** 自增主题纪元：驱动所有 @StorageProp('themeEpoch') 组件重绘 */
  private static refreshUI(): void {
    const stored: number | undefined = AppStorage.get<number>(AppStorageKey.THEME_EPOCH);
    AppStorage.setOrCreate<number>(AppStorageKey.THEME_EPOCH, (stored === undefined ? 0 : stored) + 1);
  }

  /** 状态栏/导航栏图标颜色跟随外观：深色背景用白色图标，浅色背景用黑色 */
  private static updateSystemBars(): void {
    const context: common.UIAbilityContext | undefined = ThemeService.context;
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window) => {
      const bars: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: ThemeService.dark ? '#FFFFFF' : '#000000',
        navigationBarColor: '#00000000',
        navigationBarContentColor: ThemeService.dark ? '#FFFFFF' : '#000000'
      };
      return win.setWindowSystemBarProperties(bars);
    }).catch((error: BusinessError) => {
      Logger.warn(MODULE, `更新系统栏颜色失败 code=${error.code}`);
    });
  }
}
