import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';
import { LogService } from '../services/LogService';
import { PrivacyConsentService } from '../services/PrivacyConsentService';

const MODULE: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 全应用固定深色：系统材质、弹窗、底栏光感都会跟随此配置，避免浅色策略下把深色底栏刷白
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (error) {
      Logger.exception(MODULE, '设置深色模式失败', error as BusinessError);
    }
    // 隐私声明由 AGC 隐私托管，系统在首次启动时统一弹窗；
    // 同意后再初始化业务服务
    PrivacyConsentService.start(this.context);
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
        // 深色背景需要浅色状态栏内容，否则时间/信号图标在深色底上几乎不可见
        const barProps: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF'
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
}
