import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKey } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'Demo';

/**
 * 演示模式
 *
 * 为没有耳机的场景（应用市场审核、新用户试用）模拟一台已连接的演示耳机：
 * 不申请蓝牙权限、不访问真实设备，音效制作/试听/导出仍走真实流程。
 * 写入耳机属于真实设备操作，演示模式下直接拒绝。
 */
export class DemoService {
  private static store: preferences.Preferences | undefined = undefined;
  private static active: boolean = false;
  private static guideSeen: boolean = false;
  private static loaded: boolean = false;

  public static init(context: common.UIAbilityContext): void {
    if (DemoService.loaded) {
      return;
    }
    DemoService.loaded = true;
    try {
      const options: preferences.Options = { name: AppStorageKey.PREFS_NAME };
      DemoService.store = preferences.getPreferencesSync(context, options);
      DemoService.active = DemoService.store.getSync(AppStorageKey.KEY_DEMO_MODE, false) as boolean;
      DemoService.guideSeen = DemoService.store.getSync(AppStorageKey.KEY_DEMO_GUIDE_SEEN, false) as boolean;
      Logger.info(MODULE, `演示模式=${DemoService.active} 引导已看过=${DemoService.guideSeen}`);
    } catch (error) {
      Logger.exception(MODULE, '读取演示模式状态失败', error as BusinessError);
    }
  }

  public static isActive(): boolean {
    return DemoService.active;
  }

  public static setActive(value: boolean): void {
    DemoService.active = value;
    DemoService.put(AppStorageKey.KEY_DEMO_MODE, value);
    Logger.info(MODULE, `演示模式${value ? '已开启' : '已退出'}`);
  }

  /** 首次启动是否展示演示引导 */
  public static shouldShowGuide(): boolean {
    return !DemoService.guideSeen;
  }

  public static markGuideSeen(): void {
    DemoService.guideSeen = true;
    DemoService.put(AppStorageKey.KEY_DEMO_GUIDE_SEEN, true);
  }

  private static put(key: string, value: boolean): void {
    const store: preferences.Preferences | undefined = DemoService.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      Logger.exception(MODULE, `写入演示模式 ${key} 失败`, error as BusinessError);
    }
  }
}
