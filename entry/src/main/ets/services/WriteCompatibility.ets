import { DeviceSupport, DeviceSupportLevel, DeviceVerdict } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { BluetoothService } from './BluetoothService';

/**
 * 机型兼容性判定与星闪提示。
 *
 * 从 CaseWriteService 抽出来：这些是只读判断，被 DevicePage 与写入流程共用，
 * 和「写入编排」没有关系。放在一起只会把 738 行的服务撑得更难读。
 */
export class WriteCompatibility {
  /** 未收录机型用中性串口提示，避免把非华为耳机误判成智慧音频占用 */
  static isKnownHuawei(deviceId: string, activeName: string): boolean {
    return DeviceSupport.judge(BluetoothService.deviceModelOf(deviceId), [activeName]).level !==
      DeviceSupportLevel.UNKNOWN;
  }

  /** 型号优先、蓝牙名兜底的兼容性提醒；只提醒，不拦截 */
  static compatWarn(deviceId: string, activeName: string): string {
    const hwModel: string = BluetoothService.deviceModelOf(deviceId);
    const verdict: DeviceVerdict = DeviceSupport.judge(hwModel, [activeName]);
    if (verdict.level === DeviceSupportLevel.VERIFIED) {
      return '';
    }
    if (verdict.level === DeviceSupportLevel.OFFICIAL) {
      return I18n.f('write.compatOfficial', [verdict.name, verdict.detail]);
    }
    const label: string = hwModel.length > 0
      ? I18n.f('write.compatHwModel', [hwModel]) :
      (activeName.length > 0 ? I18n.f('write.compatName', [activeName]) : I18n.t('write.compatGeneric'));
    return I18n.f('write.compatWarn', [label]);
  }

  /** 星闪连接的统一提示：盒音通道只支持经典蓝牙，给出可执行的切换指引 */
  static nearLinkHint(name: string): string {
    const label: string = name.length > 0 ? name : I18n.t('write.nearLinkFallbackName');
    return I18n.f('write.nearLinkHint', [label]);
  }

  /** 星闪开关未关闭的提示：写入前必须关闭开关，避免耳机在写入期间切回星闪 */
  static nearLinkSwitchHint(name: string): string {
    const label: string = name.length > 0 ? name : I18n.t('write.nearLinkFallbackName');
    return I18n.f('write.nearLinkSwitchHint', [label]);
  }
}