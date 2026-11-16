import {
  abilityAccessCtrl,
  bundleManager,
  common,
  PermissionRequestResult,
  Permissions,
  Want
} from '@kit.AbilityKit';
import { a2dp, access, baseProfile, connection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BtDevice, BtSnapshot, createEmptySnapshot } from '../models/DeviceModel';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { DemoService } from './DemoService';

const MODULE: string = 'Bluetooth';
const PERMISSION_BLUETOOTH: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';
/** 扫描自动停止时间 */
const SCAN_TIMEOUT_MS: number = 15000;

export type BtChangeListener = (snapshot: BtSnapshot) => void;

/**
 * 蓝牙耳机连接管理
 *
 * 说明：配对与 profile 连接均由本应用发起（connection.pairDevice / connectAllowedProfiles），
 * 取消配对等系统级操作仍需跳转系统蓝牙设置。
 */
export class BluetoothService {
  private static snapshot: BtSnapshot = createEmptySnapshot();
  private static listeners: BtChangeListener[] = [];
  private static context?: common.UIAbilityContext;
  private static initialized: boolean = false;
  private static hiddenDevices: string[] = [];
  // 未授权时订阅事件会抛 201，因此每个监听单独记录状态，授权后补注册
  private static listenedState: boolean = false;
  private static listenedFind: boolean = false;
  private static listenedBond: boolean = false;
  private static listenedConn: boolean = false;

  public static init(context: common.UIAbilityContext): void {
    if (BluetoothService.initialized) {
      return;
    }
    BluetoothService.context = context;
    BluetoothService.initialized = true;
    BluetoothService.registerListeners();
  }

  private static registerListeners(): void {
    if (!BluetoothService.listenedState) {
      try {
        access.on('stateChange', (state: access.BluetoothState) => {
          Logger.info(MODULE, `蓝牙开关状态变化：${state}`);
          BluetoothService.refresh();
        });
        BluetoothService.listenedState = true;
      } catch (error) {
        Logger.warn(MODULE, `订阅蓝牙开关状态失败 code=${(error as BusinessError).code}`);
      }
    }
    if (!BluetoothService.listenedFind) {
      try {
        connection.on('bluetoothDeviceFind', (deviceIds: Array<string>) => {
          for (let i = 0; i < deviceIds.length; i++) {
            BluetoothService.onDeviceFound(deviceIds[i]);
          }
        });
        BluetoothService.listenedFind = true;
      } catch (error) {
        Logger.warn(MODULE, `订阅设备发现事件失败 code=${(error as BusinessError).code}`);
      }
    }
    if (!BluetoothService.listenedBond) {
      try {
        // 配对成功后系统只会显示"已配对"，需主动连接对端支持的 profile 才会显示"已连接"
        connection.on('bondStateChange', (data: connection.BondStateParam) => {
          Logger.info(MODULE, `配对状态变化 ${FormatUtils.maskAddress(data.deviceId)} state=${data.state}`);
          if (data.state === connection.BondState.BOND_STATE_BONDED) {
            BluetoothService.connectQuietly(data.deviceId);
          }
          setTimeout(() => {
            BluetoothService.refresh();
          }, 900);
        });
        BluetoothService.listenedBond = true;
      } catch (error) {
        Logger.warn(MODULE, `订阅配对状态失败 code=${(error as BusinessError).code}`);
      }
    }
    if (!BluetoothService.listenedConn) {
      try {
        // 耳机在系统里被连上/断开时同步刷新，否则页面会一直停在打开时的状态
        const profile: a2dp.A2dpSourceProfile = a2dp.createA2dpSrcProfile();
        profile.on('connectionStateChange', (data: baseProfile.StateChangeParam) => {
          Logger.info(MODULE,
            `A2DP 连接状态变化 ${FormatUtils.maskAddress(data.deviceId)} state=${data.state}`);
          BluetoothService.refresh();
        });
        BluetoothService.listenedConn = true;
      } catch (error) {
        Logger.warn(MODULE, `订阅 A2DP 连接状态失败 code=${(error as BusinessError).code}`);
      }
    }
  }

  public static getSnapshot(): BtSnapshot {
    if (DemoService.isActive()) {
      return BluetoothService.demoSnapshot();
    }
    return BluetoothService.snapshot;
  }

  /** 演示模式下的模拟设备：状态卡、写入前置检查都读这里的一致性快照 */
  private static demoSnapshot(): BtSnapshot {
    const device: BtDevice = {
      deviceId: 'AA:BB:CC:DD:EE:FF',
      name: '演示耳机 BoxTone',
      paired: true,
      audio: true,
      connected: true
    };
    const snapshot: BtSnapshot = {
      supported: true,
      enabled: true,
      authorized: true,
      pairedDevices: [device],
      nearbyDevices: [],
      scanning: false,
      activeName: device.name,
      activeId: device.deviceId,
      statusText: '演示模式：模拟耳机已连接'
    };
    return snapshot;
  }

  public static onChange(listener: BtChangeListener): void {
    BluetoothService.listeners.push(listener);
  }

  public static offChange(listener: BtChangeListener): void {
    const index: number = BluetoothService.listeners.indexOf(listener);
    if (index >= 0) {
      BluetoothService.listeners.splice(index, 1);
    }
  }

  private static notify(): void {
    for (let i = 0; i < BluetoothService.listeners.length; i++) {
      BluetoothService.listeners[i](BluetoothService.snapshot);
    }
  }

  /** 申请蓝牙权限，已授权时直接返回 true */
  public static async ensurePermission(): Promise<boolean> {
    if (DemoService.isActive()) {
      return true;
    }
    const context: common.UIAbilityContext | undefined = BluetoothService.context;
    if (context === undefined) {
      return false;
    }
    if (BluetoothService.hasPermission()) {
      BluetoothService.snapshot.authorized = true;
      BluetoothService.registerListeners();
      return true;
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, [PERMISSION_BLUETOOTH]);
      const granted: boolean = result.authResults.length > 0 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      BluetoothService.snapshot.authorized = granted;
      if (granted) {
        BluetoothService.registerListeners();
      }
      Logger.info(MODULE, granted ? '蓝牙权限已授予' : '蓝牙权限被拒绝');
      return granted;
    } catch (error) {
      Logger.exception(MODULE, '申请蓝牙权限失败', error as BusinessError);
      return false;
    }
  }

  /** 检查蓝牙权限是否已授予（不弹窗） */
  public static hasPermission(): boolean {
    try {
      const tokenId: number = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus =
        abilityAccessCtrl.createAtManager().checkAccessTokenSync(tokenId, PERMISSION_BLUETOOTH);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      Logger.exception(MODULE, '检查蓝牙权限失败', error as BusinessError);
      return false;
    }
  }

  /** 打开蓝牙开关，系统会弹出确认框 */
  public static async requestEnable(): Promise<void> {
    try {
      if (access.getState() === access.BluetoothState.STATE_ON) {
        return;
      }
      access.enableBluetooth();
      Logger.info(MODULE, '已请求开启蓝牙');
    } catch (error) {
      Logger.exception(MODULE, '开启蓝牙失败', error as BusinessError);
      throw error as Error;
    }
  }

  /** 当前已连接的音频设备地址，未连接返回空串 */
  public static activeAudioId(): string {
    const ids: string[] = BluetoothService.connectedAudioDevices();
    if (ids.length > 0) {
      return ids[0];
    }
    const snapshotId: string = BluetoothService.snapshot.activeId;
    return snapshotId;
  }

  /** 指定设备的音频通道（A2DP）是否已连上：用于避免重复 connect 触发系统连接横幅 */
  public static isAudioConnected(deviceId: string): boolean {
    const ids: string[] = BluetoothService.connectedAudioDevices();
    for (let i = 0; i < ids.length; i++) {
      if (BluetoothService.sameAddress(ids[i], deviceId)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 读取 A2DP 已连接的设备地址
   *
   * 只用 A2DP 作为"音频通道"的判据：
   * 全局的 getProfileConnectionState() 在断开后仍可能回缓存值（还会被 HFP 通话链路的残留状态带偏），
   * 造成"已经断开却显示已连接"的假状态。
   */
  private static connectedAudioDevices(): string[] {
    const merged: string[] = [];
    try {
      const profile: a2dp.A2dpSourceProfile = a2dp.createA2dpSrcProfile();
      const ids: string[] = profile.getConnectedDevices();
      for (let i = 0; i < ids.length; i++) {
        BluetoothService.pushAddress(merged, ids[i]);
      }
    } catch (error) {
      Logger.warn(MODULE, `读取 A2DP 已连接设备失败 code=${(error as BusinessError).code}`);
    }
    return merged;
  }

  /** 地址统一成大写去重，系统在不同接口里返回的大小写可能不一致 */
  private static pushAddress(target: string[], address: string): void {
    if (address === undefined || address.length === 0) {
      return;
    }
    const normalized: string = address.toUpperCase();
    if (target.indexOf(normalized) < 0) {
      target.push(normalized);
    }
  }

  private static sameAddress(left: string, right: string): boolean {
    if (left.length === 0 || right.length === 0) {
      return false;
    }
    return left.toUpperCase() === right.toUpperCase();
  }

  /** 取设备显示名，取不到时退回打码地址 */
  private static displayNameOf(deviceId: string): string {
    try {
      const name: string = connection.getRemoteDeviceName(deviceId);
      if (name !== undefined && name.length > 0) {
        return name;
      }
    } catch (error) {
      Logger.warn(MODULE, `读取设备名失败 code=${(error as BusinessError).code}`);
    }
    return FormatUtils.maskAddress(deviceId);
  }

  /** 刷新蓝牙状态与设备列表 */
  public static async refresh(): Promise<BtSnapshot> {
    if (DemoService.isActive()) {
      const demo: BtSnapshot = BluetoothService.demoSnapshot();
      BluetoothService.commit(demo);
      return demo;
    }
    const snapshot: BtSnapshot = createEmptySnapshot();
    snapshot.supported = true;
    try {
      snapshot.authorized = BluetoothService.hasPermission();
      if (!snapshot.authorized) {
        snapshot.statusText = '需要蓝牙权限';
        BluetoothService.commit(snapshot);
        return snapshot;
      }
      // 权限可能在启动后才授予，这里补注册事件监听
      BluetoothService.registerListeners();

      const state: access.BluetoothState = access.getState();
      snapshot.enabled = state === access.BluetoothState.STATE_ON;
      if (!snapshot.enabled) {
        snapshot.statusText = '蓝牙未开启';
        BluetoothService.commit(snapshot);
        return snapshot;
      }

      const paired: BtDevice[] = BluetoothService.collectPairedDevices();
      const connectedIds: string[] = BluetoothService.connectedAudioDevices();

      // 唯一状态源：先定位"哪一台是当前输出设备"，再据此标记 connected。
      // 之前先给设备打 connected、再单独算 activeName，两条路径可能不一致，
      // 于是出现「列表说已连接、状态卡说未连接」的自相矛盾。
      let activeIndex: number = -1;
      for (let i = 0; i < paired.length && activeIndex < 0; i++) {
        for (let k = 0; k < connectedIds.length; k++) {
          if (BluetoothService.sameAddress(paired[i].deviceId, connectedIds[k])) {
            activeIndex = i;
            break;
          }
        }
      }
      // 系统会把地址虚拟化，与配对表对不上时：只有一台音频设备就归属给它
      if (activeIndex < 0 && connectedIds.length > 0) {
        let audioIndex: number = -1;
        let audioCount: number = 0;
        for (let i = 0; i < paired.length; i++) {
          if (paired[i].audio) {
            audioCount++;
            audioIndex = i;
          }
        }
        if (audioCount === 1) {
          activeIndex = audioIndex;
        }
      }

      if (activeIndex >= 0) {
        paired[activeIndex].connected = true;
        snapshot.activeName = paired[activeIndex].name;
        snapshot.activeId = paired[activeIndex].deviceId;
      }

      snapshot.pairedDevices = paired;
      if (activeIndex >= 0) {
        snapshot.statusText = '音频通道已连接';
      } else if (connectedIds.length > 0) {
        // 连上了但归不到配对列表里的地址（系统虚拟化地址）：仍要把名字显示出来，
        // 否则会出现「状态卡说未连接、却又标记已连接音频设备」的自相矛盾
        snapshot.activeId = connectedIds[0];
        snapshot.activeName = BluetoothService.displayNameOf(connectedIds[0]);
        snapshot.statusText = '音频通道已连接';
      } else if (paired.length > 0) {
        snapshot.statusText = '已配对，未连接';
      } else {
        snapshot.statusText = '尚未配对耳机';
      }

      snapshot.nearbyDevices = BluetoothService.snapshot.nearbyDevices;
      snapshot.scanning = BluetoothService.snapshot.scanning;
      BluetoothService.commit(snapshot);
      return snapshot;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE, '刷新蓝牙状态失败', businessError);
      if (businessError.code === 201) {
        // 201：缺少 ohos.permission.ACCESS_BLUETOOTH
        snapshot.authorized = false;
        snapshot.statusText = '需要蓝牙权限';
      } else if (businessError.code === 801) {
        snapshot.supported = false;
        snapshot.statusText = '当前设备不支持蓝牙接口';
      } else if (businessError.code === 2900003) {
        snapshot.statusText = '蓝牙未开启';
      } else {
        snapshot.statusText = `蓝牙状态读取失败（${businessError.code}）`;
      }
      BluetoothService.commit(snapshot);
      return snapshot;
    }
  }

  private static commit(snapshot: BtSnapshot): void {
    BluetoothService.snapshot = snapshot;
    BluetoothService.notify();
  }

  private static collectPairedDevices(): BtDevice[] {
    const result: BtDevice[] = [];
    try {
      const ids: string[] = connection.getPairedDevices();
      for (let i = 0; i < ids.length; i++) {
        result.push(BluetoothService.describeDevice(ids[i], true));
      }
    } catch (error) {
      Logger.exception(MODULE, '读取已配对设备失败', error as BusinessError);
    }
    result.sort((a: BtDevice, b: BtDevice): number => {
      if (a.audio === b.audio) {
        return a.name.localeCompare(b.name);
      }
      return a.audio ? -1 : 1;
    });
    return result;
  }

  private static describeDevice(deviceId: string, paired: boolean): BtDevice {
    let name: string = '';
    let isAudio: boolean = false;
    try {
      name = connection.getRemoteDeviceName(deviceId);
    } catch (error) {
      name = '';
    }
    try {
      const deviceClass: connection.DeviceClass = connection.getRemoteDeviceClass(deviceId);
      isAudio = deviceClass.majorClass === constant.MajorClass.MAJOR_AUDIO_VIDEO;
    } catch (error) {
      isAudio = false;
    }
    if (name.length === 0) {
      name = FormatUtils.maskAddress(deviceId);
    }
    const device: BtDevice = {
      deviceId: deviceId,
      name: name,
      paired: paired,
      audio: isAudio,
      connected: false
    };
    return device;
  }

  private static onDeviceFound(deviceId: string): void {
    const nearby: BtDevice[] = BluetoothService.snapshot.nearbyDevices;
    for (let i = 0; i < nearby.length; i++) {
      if (nearby[i].deviceId === deviceId) {
        return;
      }
    }
    if (BluetoothService.hiddenDevices.indexOf(deviceId) >= 0) {
      return;
    }
    nearby.push(BluetoothService.describeDevice(deviceId, false));
    BluetoothService.snapshot.nearbyDevices = nearby;
    BluetoothService.notify();
  }

  /** 开始扫描附近设备 */
  public static startScan(): void {
    if (BluetoothService.snapshot.scanning) {
      return;
    }
    BluetoothService.snapshot.nearbyDevices = [];
    BluetoothService.snapshot.scanning = true;
    BluetoothService.notify();
    try {
      connection.startBluetoothDiscovery();
      Logger.info(MODULE, '开始扫描附近设备');
      setTimeout(() => {
        BluetoothService.stopScan();
      }, SCAN_TIMEOUT_MS);
    } catch (error) {
      BluetoothService.snapshot.scanning = false;
      BluetoothService.notify();
      Logger.exception(MODULE, '启动扫描失败', error as BusinessError);
    }
  }

  public static stopScan(): void {
    if (!BluetoothService.snapshot.scanning) {
      return;
    }
    BluetoothService.snapshot.scanning = false;
    try {
      connection.stopBluetoothDiscovery();
      Logger.info(MODULE, '停止扫描');
    } catch (error) {
      Logger.exception(MODULE, '停止扫描失败', error as BusinessError);
    }
    BluetoothService.notify();
  }

  /** 配对设备 */
  public static async pair(deviceId: string): Promise<void> {
    try {
      await connection.pairDevice(deviceId);
      Logger.info(MODULE, `发起配对 ${FormatUtils.maskAddress(deviceId)}`);
      setTimeout(() => {
        BluetoothService.refresh();
      }, 2500);
    } catch (error) {
      Logger.exception(MODULE, '配对失败', error as BusinessError);
      throw error as Error;
    }
  }

  /**
   * 连接已配对设备的 profile（A2DP / HFP / HID）
   * 系统蓝牙界面需要应用主动连接 profile 才会显示"已连接"，
   * 且该接口仅允许在发起配对后 30s 内调用一次。
   */
  public static async connect(deviceId: string): Promise<void> {
    try {
      await connection.connectAllowedProfiles(deviceId);
      Logger.info(MODULE, `已发起连接 ${FormatUtils.maskAddress(deviceId)}`);
      BluetoothService.scheduleRefresh();
    } catch (error) {
      Logger.exception(MODULE, '连接设备失败', error as BusinessError);
      throw error as Error;
    }
  }

  /**
   * 连接状态是异步收敛的，单次刷新容易读到中间态。
   * 连续刷新几次，让界面自己追平真实状态。
   */
  private static scheduleRefresh(): void {
    const delays: number[] = [400, 1000, 2200];
    for (let i = 0; i < delays.length; i++) {
      setTimeout(() => {
        BluetoothService.refresh();
      }, delays[i]);
    }
  }

  /** 静默连接：配对回调里自动调用，失败只记录日志 */
  private static connectQuietly(deviceId: string): void {
    connection.connectAllowedProfiles(deviceId).then(() => {
      Logger.info(MODULE, `配对后已自动连接 ${FormatUtils.maskAddress(deviceId)}`);
    }).catch((error: BusinessError) => {
      Logger.warn(MODULE, `配对后自动连接失败 code=${error.code}`);
    });
  }

  /** 断开已配对设备的 profile 连接（API 26 起支持） */
  public static async disconnect(deviceId: string): Promise<void> {
    try {
      await connection.disconnectAllowedProfiles(deviceId);
      Logger.info(MODULE, `已断开 ${FormatUtils.maskAddress(deviceId)}`);
      BluetoothService.scheduleRefresh();
    } catch (error) {
      Logger.exception(MODULE, '断开设备失败', error as BusinessError);
      throw error as Error;
    }
  }

  /**
   * 取消配对
   *
   * 说明：API 26 起不再对外开放 cancelPairedDevice，系统仅允许在蓝牙设置中解除配对，
   * 因此这里直接跳转系统蓝牙设置页，由用户完成操作。
   */
  public static async unpair(deviceId: string): Promise<void> {
    Logger.info(MODULE, `取消配对需在系统设置中完成：${FormatUtils.maskAddress(deviceId)}`);
    await BluetoothService.openSystemBluetoothSettings();
  }

  /** 跳转系统蓝牙设置：音频通道的实际连接在此完成 */
  public static async openSystemBluetoothSettings(): Promise<void> {
    const context: common.UIAbilityContext | undefined = BluetoothService.context;
    if (context === undefined) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        // 蓝牙二级页面的 uri 为 bluetooth_entry（写成 bluetooth 会打开空白页）
        uri: 'bluetooth_entry'
      };
      await context.startAbility(want);
      Logger.info(MODULE, '已跳转系统蓝牙设置');
    } catch (error) {
      Logger.exception(MODULE, '跳转设置失败，尝试 action 方式', error as BusinessError);
      try {
        const fallback: Want = {
          bundleName: 'com.huawei.hmos.settings',
          abilityName: 'com.huawei.hmos.settings.MainAbility',
          uri: 'bluetooth_entry',
          action: 'ohos.settings.bluetooth'
        };
        await context.startAbility(fallback);
      } catch (inner) {
        Logger.exception(MODULE, '无法打开蓝牙设置', inner as BusinessError);
        throw inner as Error;
      }
    }
  }
}
