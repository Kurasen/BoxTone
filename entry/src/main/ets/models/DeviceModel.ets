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
    statusText: '蓝牙未开启'
  };
  return snapshot;
}

export function createEmptyDevice(): BtDevice {
  const device: BtDevice = {
    deviceId: '',
    name: '',
    paired: false,
    audio: false,
    connected: false
  };
  return device;
}
