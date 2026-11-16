import {
  abilityAccessCtrl,
  bundleManager,
  common,
  PermissionRequestResult,
  Permissions
} from '@kit.AbilityKit';
import { manager, nearlinkConstant, remoteDevice } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'NearLink';
const PERMISSION_NEARLINK: Permissions = 'ohos.permission.ACCESS_NEARLINK';
/** SDK 类型声明的 syscap 是 Base，线上文档写的是 Core，两种都认 */
const CAP_NEARLINK_BASE: string = 'SystemCapability.Communication.NearLink.Base';
const CAP_NEARLINK_CORE: string = 'SystemCapability.Communication.NearLink.Core';

/** 星闪侧检测结果：只暴露"有没有音频类设备在连"这一层，写入仍走经典蓝牙 */
export interface NearLinkSnapshot {
  /** 系统与芯片是否支持星闪 */
  supported: boolean;
  /** 星闪开关是否打开 */
  enabled: boolean;
  /** 是否已授予星闪权限 */
  authorized: boolean;
  /** 当前通过星闪连接的音频设备名，空串表示没有 */
  connectedName: string;
}

function emptySnapshot(): NearLinkSnapshot {
  const snapshot: NearLinkSnapshot = {
    supported: false,
    enabled: false,
    authorized: false,
    connectedName: ''
  };
  return snapshot;
}

/**
 * 星闪连接检测
 *
 * 仅做"识别"：系统音频走星闪时 A2DP 不再报告连接，蓝牙侧会误判成未连接。
 * 这里通过星闪配对表 + 远端设备连接状态补上真实连接状态。
 * 盒音数据通道没有公开的星闪服务，写入仍使用经典蓝牙 SPP。
 */
export class NearLinkService {
  private static context?: common.UIAbilityContext;
  private static snapshot: NearLinkSnapshot = emptySnapshot();
  private static listened: boolean = false;
  private static supportLogged: boolean = false;
  private static lastConnectedName: string = '';
  private static lastWarnAt: number = 0;
  private static onChanged: (() => void) | undefined = undefined;

  public static init(context: common.UIAbilityContext, onChange: () => void): void {
    NearLinkService.context = context;
    NearLinkService.onChanged = onChange;
    NearLinkService.registerListener();
  }

  /** 系统能力探测：旧系统 / 无星闪芯片设备直接返回 false；结果只记一次日志 */
  public static isSupported(): boolean {
    let capability: boolean = false;
    try {
      capability = canIUse(CAP_NEARLINK_BASE) || canIUse(CAP_NEARLINK_CORE);
    } catch (error) {
      capability = false;
    }
    if (!capability) {
      NearLinkService.logSupport(false, 'syscap 不可用');
      return false;
    }
    try {
      const supported: boolean = manager.isNearLinkSupported();
      NearLinkService.logSupport(supported, 'isNearLinkSupported');
      return supported;
    } catch (error) {
      NearLinkService.logSupport(false, `调用异常 code=${(error as BusinessError).code}`);
      return false;
    }
  }

  private static logSupport(supported: boolean, detail: string): void {
    if (NearLinkService.supportLogged) {
      return;
    }
    NearLinkService.supportLogged = true;
    Logger.info(MODULE, `星闪能力检测 supported=${supported}（${detail}）`);
  }

  /** 轮询会反复触发同一问题，告警最多每分钟记一次，避免刷爆日志 */
  private static warnThrottled(message: string): void {
    const now: number = Date.now();
    if (now - NearLinkService.lastWarnAt < 60000) {
      return;
    }
    NearLinkService.lastWarnAt = now;
    Logger.warn(MODULE, message);
  }

  public static hasPermission(): boolean {
    try {
      const tokenId: number = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus =
        abilityAccessCtrl.createAtManager().checkAccessTokenSync(tokenId, PERMISSION_NEARLINK);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return false;
    }
  }

  /** 申请星闪权限；不支持星闪的设备直接返回 false，不弹窗 */
  public static async ensurePermission(): Promise<boolean> {
    if (!NearLinkService.isSupported()) {
      return false;
    }
    if (NearLinkService.hasPermission()) {
      return true;
    }
    const context: common.UIAbilityContext | undefined = NearLinkService.context;
    if (context === undefined) {
      return false;
    }
    try {
      const result: PermissionRequestResult =
        await abilityAccessCtrl.createAtManager()
          .requestPermissionsFromUser(context, [PERMISSION_NEARLINK]);
      const granted: boolean = result.authResults.length > 0 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      Logger.info(MODULE, granted ? '星闪权限已授予' : '星闪权限被拒绝');
      return granted;
    } catch (error) {
      Logger.warn(MODULE, `申请星闪权限失败 code=${(error as BusinessError).code}`);
      return false;
    }
  }

  private static registerListener(): void {
    if (NearLinkService.listened || !NearLinkService.isSupported()) {
      return;
    }
    try {
      manager.onStateChange((state: manager.NearlinkState): void => {
        Logger.info(MODULE, `星闪开关状态变化：${state}`);
        if (NearLinkService.onChanged !== undefined) {
          NearLinkService.onChanged();
        }
      });
      NearLinkService.listened = true;
    } catch (error) {
      Logger.warn(MODULE, `订阅星闪开关状态失败 code=${(error as BusinessError).code}`);
    }
  }

  public static getSnapshot(): NearLinkSnapshot {
    return NearLinkService.snapshot;
  }

  /** 刷新星闪侧状态：配对表里找音频类且处于连接状态的设备 */
  public static async refresh(): Promise<NearLinkSnapshot> {
    const snapshot: NearLinkSnapshot = emptySnapshot();
    if (!NearLinkService.isSupported()) {
      NearLinkService.snapshot = snapshot;
      return snapshot;
    }
    snapshot.supported = true;
    try {
      snapshot.enabled = manager.getState() === manager.NearlinkState.STATE_ON;
      if (!snapshot.enabled) {
        NearLinkService.snapshot = snapshot;
        return snapshot;
      }
      snapshot.authorized = NearLinkService.hasPermission();
      if (!snapshot.authorized) {
        NearLinkService.warnThrottled('缺少 ACCESS_NEARLINK 权限，无法检测星闪连接');
        NearLinkService.snapshot = snapshot;
        return snapshot;
      }
      snapshot.connectedName = NearLinkService.findConnectedAudioName();
      if (snapshot.connectedName !== NearLinkService.lastConnectedName) {
        NearLinkService.lastConnectedName = snapshot.connectedName;
        Logger.info(MODULE, `星闪连接变化 connected=` +
          `${snapshot.connectedName.length > 0 ? snapshot.connectedName : '无'}`);
      }
      NearLinkService.snapshot = snapshot;
      return snapshot;
    } catch (error) {
      NearLinkService.warnThrottled(`刷新星闪状态失败 code=${(error as BusinessError).code}`);
      NearLinkService.snapshot = snapshot;
      return snapshot;
    }
  }

  private static findConnectedAudioName(): string {
    let fallback: string = '';
    let addresses: string[] = [];
    try {
      addresses = manager.getPairedDevices();
    } catch (error) {
      NearLinkService.warnThrottled(`读取星闪配对设备失败 code=${(error as BusinessError).code}`);
      return '';
    }
    for (let i = 0; i < addresses.length; i++) {
      try {
        const device: remoteDevice.RemoteDevice = remoteDevice.createRemoteDevice(addresses[i]);
        const state: nearlinkConstant.ConnectionState = device.getConnectionState();
        if (state !== nearlinkConstant.ConnectionState.STATE_CONNECTED) {
          continue;
        }
        // ACB 是底层逻辑链路：合盖后通常比连接状态更早掉，用它加速断开识别
        let acb: nearlinkConstant.AcbState | undefined = undefined;
        try {
          acb = device.getAcbState();
        } catch (acbError) {
          acb = undefined;
        }
        if (acb !== undefined && acb === nearlinkConstant.AcbState.DISCONNECTED) {
          continue;
        }
        const name: string = device.getDeviceName();
        if (name.length === 0) {
          continue;
        }
        let audio: boolean = false;
        try {
          audio = NearLinkService.isAudioClass(device.getDeviceClass());
        } catch (classError) {
          audio = false;
        }
        if (audio) {
          return name;
        }
        if (fallback.length === 0) {
          fallback = name;
        }
      } catch (error) {
        NearLinkService.warnThrottled(
          `读取星闪设备信息失败 ${(error as BusinessError).code} ${(error as BusinessError).message}`);
      }
    }
    return fallback;
  }

  private static isAudioClass(deviceClass: nearlinkConstant.DeviceClass): boolean {
    if (deviceClass === nearlinkConstant.DeviceClass.DEVICE_WEARABLE_AUDIO ||
      deviceClass === nearlinkConstant.DeviceClass.DEVICE_AUDIO_PLAYBACK) {
      return true;
    }
    return deviceClass === nearlinkConstant.DeviceClass.DEVICE_IN_EAR_EARPHONE ||
      deviceClass === nearlinkConstant.DeviceClass.DEVICE_HEADSET ||
      deviceClass === nearlinkConstant.DeviceClass.DEVICE_OVER_EAR_HEADPHONE ||
      deviceClass === nearlinkConstant.DeviceClass.DEVICE_NECKBAND_EARPHONE ||
      deviceClass === nearlinkConstant.DeviceClass.DEVICE_SMART_SPEAKER;
  }
}
