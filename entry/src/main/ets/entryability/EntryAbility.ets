import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';
import { LogService } from '../services/LogService';
import { BluetoothService } from '../services/BluetoothService';
import { LanguageService } from '../services/LanguageService';
import { PrivacyConsentService } from '../services/PrivacyConsentService';
import { ThemeService } from '../services/ThemeService';

const MODULE: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用语言：按设备地区自动选择简体中文 / English（每次启动判定，幂等）
    LanguageService.apply();
    // 应用外观：默认深色，可在「我的 → 外观设置」切换深色/浅色/跟随系统；
    // setColorMode 同时决定系统弹窗、半模态与 HDS 底栏材质的深浅
    ThemeService.init(this.context);
    // 隐私声明由 AGC 隐私托管，系统在首次启动时统一弹窗；
    // 同意后再初始化业务服务
    PrivacyConsentService.start(this.context);
  }

  /** 仅"跟随系统"模式会收到该回调；手动指定深浅色时系统不派发 */
  onConfigurationUpdate(newConfig: Configuration): void {
    ThemeService.onSystemColorChanged(newConfig);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error: BusinessError) => {
      if (error.code) {
        Logger.exception(MODULE, '加载首页失败', error);
        return;
      }
      Logger.info(MODULE, '首页加载完成');
    });

    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      // 全屏布局，让背景渐变延伸到状态栏下方
      return mainWindow.setWindowLayoutFullScreen(true).then(() => {
        // 状态栏图标颜色跟随外观：深色背景用白色图标，浅色背景用黑色
        const lightIcons: boolean = !ThemeService.isDark();
        const barProps: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          statusBarContentColor: lightIcons ? '#000000' : '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: lightIcons ? '#000000' : '#FFFFFF'
        };
        return mainWindow.setWindowSystemBarProperties(barProps);
      });
    }).catch((error: BusinessError) => {
      Logger.exception(MODULE, '设置沉浸式布局失败', error);
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(MODULE, '窗口销毁');
  }

  onDestroy(): void {
    PrivacyConsentService.stop();
    LogService.getInstance().flush();
    Logger.info(MODULE, '应用退出');
  }

  onBackground(): void {
    LogService.getInstance().flush();
  }

  onForeground(): void {
    // 后台期间蓝牙/星闪状态可能变化且没有事件补发：回前台立即拉一次
    BluetoothService.refresh();
  }
}
