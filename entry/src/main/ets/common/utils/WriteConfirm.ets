import { UIContext } from '@kit.ArkUI';
import { I18n } from '../i18n/I18n';
import { Palette } from '../constants/ThemeConstants';

/**
 * 「写入注意」确认框：音效库「写入」和音效页「生成并写入」共用（文案参考 feat/write-flow-v2）。
 * 点「开始写入」后由调用方交给 WriteTask，进度和结局都在写入弹窗里显示。
 */
export class WriteConfirm {
  /**
   * @param warn 未验证机型的兼容性提醒：只提醒、不拦截，放在正文前面
   */
  static tone(uiContext: UIContext, toneName: string, warn: string, onStart: () => void,
    onCancel?: () => void): void {
    const body: string = I18n.f('confirm.message', [toneName]);
    // 对话框关闭有动画，快速连点可能触发两次回调：开始 / 取消只认第一次
    let settled: boolean = false;
    const cancelled: () => void = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (onCancel !== undefined) {
        onCancel();
      }
    };
    const started: () => void = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      onStart();
    };
    uiContext.showAlertDialog({
      title: I18n.t('confirm.title'),
      message: warn.length > 0 ? `${warn}\n\n${body}` : body,
      cancel: cancelled,
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: cancelled
      },
      secondaryButton: {
        value: I18n.t('confirm.start'),
        fontColor: Palette.ACCENT,
        action: started
      }
    });
  }
}
