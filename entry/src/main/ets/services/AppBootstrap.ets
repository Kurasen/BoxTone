import { common } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';
import { BluetoothService } from './BluetoothService';
import { FeedbackService } from './FeedbackService';
import { LogService } from './LogService';
import { SettingsService } from './SettingsService';
import { ToneRepositoryService } from './ToneRepositoryService';

const MODULE: string = 'Bootstrap';

/**
 * 服务启动入口
 * 由 PrivacyConsentService 在托管隐私弹窗同意后调用
 */
export class AppBootstrap {
  private static initialized: boolean = false;

  public static isInitialized(): boolean {
    return AppBootstrap.initialized;
  }

  public static init(context: common.UIAbilityContext): void {
    if (AppBootstrap.initialized) {
      return;
    }
    AppBootstrap.initialized = true;
    // 日志中心最先初始化，后续所有失败都能被记录
    LogService.getInstance().init(context);
    Logger.info(MODULE, '应用启动');
    SettingsService.init(context);
    ToneRepositoryService.init(context);
    BluetoothService.init(context);
    FeedbackService.init(context);
  }
}
