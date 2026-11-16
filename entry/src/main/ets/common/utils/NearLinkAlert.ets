import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../i18n/I18n';
import { Palette } from '../constants/ThemeConstants';
import { BluetoothService } from '../../services/BluetoothService';
import { Logger } from './Logger';

const MODULE: string = 'NearLinkAlert';

/** 星闪连接统一弹窗：写入被拦截与连接检测提醒共用同一套文案与操作 */
export class NearLinkAlert {
  static show(uiContext: UIContext, message: string): void {
    uiContext.showAlertDialog({
      title: I18n.t('nearlink.title'),
      message: message,
      primaryButton: {
        value: I18n.t('common.ok'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('nearlink.openSettings'),
        fontColor: Palette.ACCENT,
        action: (): void => {
          BluetoothService.openSystemBluetoothSettings().catch((error: BusinessError) => {
            Logger.warn(MODULE, `打开系统蓝牙设置失败 code=${error.code}`);
            uiContext.getPromptAction().showToast({ message: I18n.t('nearlink.openFailed'), duration: 2000 });
          });
        }
      }
    });
  }
}
