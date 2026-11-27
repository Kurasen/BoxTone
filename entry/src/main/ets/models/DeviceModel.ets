import { I18n } from '../common/i18n/I18n';

/**
 * 蓝牙设备模型
 */

export interface BtDevice {
  /** MAC 地址，HarmonyOS 中作为设备唯一标识 */
  deviceId: string;
  /** 设备名，未获取到时为空串 */
  name: string;
  /** 是否已配对 */
  paired: boolean;
  /** 是否属于音频类设备（耳机/音箱） */
  audio: boolean;
  /** 是否处于连接状态 */
  connected: boolean;
  /** 当前音频是否走星闪连接（系统层面，A2DP 不再报告） */
  nearLink: boolean;
}

/** 蓝牙面板快照，供 UI 一次性渲染 */
export interface BtSnapshot {
  /** 系统是否提供蓝牙能力 */
  supported: boolean;
  /** 蓝牙开关是否打开 */
  enabled: boolean;
  /** 是否已获取蓝牙权限 */
  authorized: boolean;
  /** 已配对设备 */
  pairedDevices: BtDevice[];
  /** 扫描到的附近设备 */
  nearbyDevices: BtDevice[];
  /** 是否正在扫描 */
  scanning: boolean;
  /** 当前 A2DP 输出设备名，空串表示未连接耳机 */
  activeName: string;
  /** 当前 A2DP 输出设备地址 */
  activeId: string;
  /** 状态提示文案 */
  statusText: string;
  /** 系统与芯片是否支持星闪 */
  nearLinkSupported: boolean;
  /** 星闪开关是否打开 */
  nearLinkEnabled: boolean;
  /** 通过星闪连接的音频设备名，空串表示没有 */
  nearLinkName: string;
  /** 星闪连接设备对应的经典蓝牙地址：只有名称能匹配上已配对设备时才有值 */
  nearLinkBtId: string;
  /** 刚写完音效、耳机正在刷闪存：这段时间系统报的连接状态不可信，界面显示「保存中」 */
  settling: boolean;
  /** 处于保存中的设备地址 */
  settlingId: string;
}

export function createEmptySnapshot(): BtSnapshot {
  const snapshot: BtSnapshot = {
    supported: true,
    enabled: false,
    authorized: false,
    pairedDevices: [],
    nearbyDevices: [],
    scanning: false,
    activeName: '',
    activeId: '',
    statusText: I18n.t('bt.off'),
    nearLinkSupported: false,
    nearLinkEnabled: false,
    nearLinkName: '',
    nearLinkBtId: '',
    settling: false,
    settlingId: ''
  };
  return snapshot;
}

/**
 * 浅拷贝一份快照（设备数组也换成新数组，设备对象本身共用）。
 * 快照会被页面直接赋给 @State：原地改字段再把同一个引用推过去，框架既可能检测不到变化，
 * 也会让页面状态和服务内部状态共用同一个对象。凡是要改快照再通知页面的地方，都先拷贝一份。
 */
export function cloneSnapshot(source: BtSnapshot): BtSnapshot {
  const snapshot: BtSnapshot = {
    supported: source.supported,
    enabled: source.enabled,
    authorized: source.authorized,
    pairedDevices: source.pairedDevices.slice(),
    nearbyDevices: source.nearbyDevices.slice(),
    scanning: source.scanning,
    activeName: source.activeName,
    activeId: source.activeId,
    statusText: source.statusText,
    nearLinkSupported: source.nearLinkSupported,
    nearLinkEnabled: source.nearLinkEnabled,
    nearLinkName: source.nearLinkName,
    nearLinkBtId: source.nearLinkBtId,
    settling: source.settling,
    settlingId: source.settlingId
  };
  return snapshot;
}

export function createEmptyDevice(): BtDevice {
  const device: BtDevice = {
    deviceId: '',
    name: '',
    paired: false,
    audio: false,
    connected: false,
    nearLink: false
  };
  return device;
}
