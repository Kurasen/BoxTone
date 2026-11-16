import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Palette } from '../constants/ThemeConstants';
import { BluetoothService } from '../../services/BluetoothService';
import { Logger } from './Logger';

const MODULE: string = 'NearLinkAlert';

/** 星闪连接统一弹窗：写入被拦截与连接检测提醒共用同一套文案与操作 */
export class NearLinkAlert {
  static show(uiContext: UIContext, message: string): void {
    uiContext.showAlertDialog({
      title: '星闪连接暂不支持写入',
      message: message,
      primaryButton: {
        value: '知道了',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '打开系统设置',
        fontColor: Palette.ACCENT,
        action: (): void => {
          BluetoothService.openSystemBluetoothSettings().catch((error: BusinessError) => {
            Logger.warn(MODULE, `打开系统蓝牙设置失败 code=${error.code}`);
            uiContext.getPromptAction().showToast({ message: '无法打开系统设置', duration: 2000 });
          });
        }
      }
    });
  }
}
