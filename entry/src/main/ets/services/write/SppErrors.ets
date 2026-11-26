import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { isToneError, ToneError, ToneErrorReason } from '../bluetooth/ToneTypes';

/**
 * 系统蓝牙错误码 → 面向用户的 ToneError。
 * 这些码都是真机上会稳定出现的失败原因，文案沿用旧实现。
 */
export class SppErrors {
  /** 串口已死：重试只会白耗时间 */
  static readonly IO_ERROR: number = 2901054;
  static readonly NOT_ACCEPTED: number = 2900099;
  static readonly SERVICE_NOT_READY: number = 2900001;
  static readonly BT_OFF: number = 2900003;
  static readonly NO_SPP: number = 2900004;

  static codeOf(error: Object | null | undefined): number {
    if (error === null || error === undefined) {
      return 0;
    }
    const businessError: BusinessError = error as BusinessError;
    return businessError.code !== undefined ? businessError.code : 0;
  }

  static messageOf(error: Object | null | undefined): string {
    if (error === null || error === undefined) {
      return '';
    }
    const businessError: BusinessError = error as BusinessError;
    return businessError.message !== undefined ? businessError.message : '';
  }

  /** 是否是「写不出去」这一类致命错误：链路已经没了 */
  static isFatalWrite(code: number): boolean {
    return code === SppErrors.IO_ERROR || code === SppErrors.BT_OFF || code === SppErrors.SERVICE_NOT_READY;
  }

  static linkLost(): ToneError {
    const error: ToneError = new ToneError(I18n.t('toneErr.linkLost'), SppErrors.IO_ERROR);
    error.reason = ToneErrorReason.LINK;
    return error;
  }

  static describe(error: Object | null | undefined, neutral: boolean = false): ToneError {
    if (isToneError(error)) {
      return error as ToneError;
    }
    const code: number = SppErrors.codeOf(error);
    if (code === 201) {
      return new ToneError(I18n.t('toneErr.perm'), code);
    }
    if (code === 801) {
      return new ToneError(I18n.t('toneErr.unsupportedBt'), code);
    }
    if (code === SppErrors.SERVICE_NOT_READY) {
      return new ToneError(I18n.t('toneErr.serviceNotReady'), code);
    }
    if (code === SppErrors.BT_OFF) {
      return new ToneError(I18n.t('toneErr.btOff'), code);
    }
    if (code === SppErrors.NO_SPP) {
      return new ToneError(I18n.t('toneErr.noSpp'), code);
    }
    if (code === SppErrors.NOT_ACCEPTED) {
      return new ToneError(neutral ? I18n.t('toneErr.notAcceptedNeutral') : I18n.t('toneErr.notAccepted'), code);
    }
    if (code === SppErrors.IO_ERROR) {
      const lost: ToneError = new ToneError(I18n.t('toneErr.linkLost'), code);
      lost.reason = ToneErrorReason.LINK;
      return lost;
    }
    if (code === -1) {
      return new ToneError(neutral ? I18n.t('toneErr.rejectedNeutral') : I18n.t('toneErr.rejected'), code);
    }
    if (code === 401) {
      return new ToneError(I18n.t('toneErr.badAddress'), code);
    }
    const text: string = SppErrors.messageOf(error);
    return new ToneError(text.length > 0 ?
      I18n.f('toneErr.serialFailedWith', [text]) : I18n.t('toneErr.serialFailed'), code);
  }
}
