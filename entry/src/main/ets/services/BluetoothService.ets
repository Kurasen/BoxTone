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
import { I18n } from '../common/i18n/I18n';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { NearLinkService, NearLinkSnapshot } from './NearLinkService';

const MODULE: string = 'Bluetooth';
const PERMISSION_BLUETOOTH: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

const SCAN_TIMEOUT_MS: number = 15000;
/**
 * A2DP 状态回调同一状态常连发 3~5 次（如断开时 state=0 ×4）。这段时间内完全相同的回调只计数，
 * 下一条不同的回调带上 dup=N。只影响日志，刷新照常触发。
 */
const A2DP_LOG_DEDUP_MS: number = 1500;

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
  /** 按地址缓存耳机自报型号：SPP 会话里查到一次后供界面与前置检查复用 */
  private static modelCache: Map<string, string> = new Map<string, string>();
  // 未授权时订阅事件会抛 201，因此每个监听单独记录状态，授权后补注册
  private static listenedState: boolean = false;
  private static listenedFind: boolean = false;
  private static listenedBond: boolean = false;
  private static listenedConn: boolean = false;
  /** A2DP 日志去重：上一条打印的「地址|状态|原因」、时刻，以及之后被合并的条数 */
  private static a2dpLogKey: string = '';
  private static a2dpLogAt: number = 0;
  private static a2dpLogDup: number = 0;
  /** 事件回调去抖计时器：系统事件经常成组到达，合并成一次刷新 */
  private static refreshTimer: number = -1;
  /**
   * 写完音效后的保存窗口。耳机这时在刷闪存，实际已经用不了，
   * 但系统 A2DP 可能短暂报「已连接」、也可能不发任何事件，只靠事件刷新会一直停在旧状态。
   * 窗口内界面统一显示「保存中」，窗口结束时主动刷新一次，拿到真实状态。
   */
  private static settlingId: string = '';
  private static settlingUntil: number = 0;
  private static settleTimer: number = -1;

  public static init(context: common.UIAbilityContext): void {
    if (BluetoothService.initialized) {
      return;
    }
    BluetoothService.context = context;
    BluetoothService.initialized = true;
    BluetoothService.registerListeners();
    // 星闪开关变化也要刷新快照：星闪连着耳机时它才是连接状态的唯一来源
    NearLinkService.init(context, (): void => {
      BluetoothService.refreshDebounced();
    });
  }

  private static registerListeners(): void {
    if (!BluetoothService.listenedState) {
      try {
        access.on('stateChange', (state: access.BluetoothState) => {
          Logger.info(MODULE, `蓝牙开关状态变化：${state}`);
          BluetoothService.refreshDebounced();
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
          BluetoothService.refreshDebounced(900);
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
          BluetoothService.logA2dpState(data);
          BluetoothService.refreshDebounced();
        });
        BluetoothService.listenedConn = true;
      } catch (error) {
        Logger.warn(MODULE, `订阅 A2DP 连接状态失败 code=${(error as BusinessError).code}`);
      }
    }
  }

  /**
   * 记下 cause（baseProfile.DisconnectCause，API 12 起），看音频掉线/连回各是什么原因；
   * 0=USER_DISCONNECT、1~3=需由键盘/鼠标/车机侧发起、4=TOO_MANY_CONNECTED_DEVICES、5=CONNECT_FAIL_INTERNAL（SDK baseProfile.d.ts），
   * 用于排查「握手期间被连回 / 收尾期间耳机自己掉音频」，见 docs/write-engine.md 第 12 节。
   */
  private static logA2dpState(data: baseProfile.StateChangeParam): void {
    const now: number = Date.now();
    const key: string = `${data.deviceId}|${data.state}|${data.cause}`;
    if (key === BluetoothService.a2dpLogKey && now - BluetoothService.a2dpLogAt < A2DP_LOG_DEDUP_MS) {
      BluetoothService.a2dpLogDup++;
      return;
    }
    const dup: string = BluetoothService.a2dpLogDup > 0 ? ` (前一条另有 dup=${BluetoothService.a2dpLogDup})` : '';
    BluetoothService.a2dpLogKey = key;
    BluetoothService.a2dpLogAt = now;
    BluetoothService.a2dpLogDup = 0;
    Logger.info(MODULE, `A2DP 连接状态变化 ${FormatUtils.maskAddress(data.deviceId)} state=${data.state} ` +
      `cause=${data.cause}${dup}`);
  }

  public static getSnapshot(): BtSnapshot {
    return BluetoothService.snapshot;
  }

  /** 设备显示名：当前输出设备名优先，取不到（音频已断开）就用配对表里同一地址的名字；都没有返回空串 */
  public static nameOf(deviceId: string): string {
    const snapshot: BtSnapshot = BluetoothService.snapshot;
    if (snapshot.activeName.length > 0) {
      return snapshot.activeName;
    }
    for (let i = 0; i < snapshot.pairedDevices.length; i++) {
      if (BluetoothService.sameAddress(snapshot.pairedDevices[i].deviceId, deviceId)) {
        return snapshot.pairedDevices[i].name;
      }
    }
    return '';
  }

  /** 记录耳机自报型号：写入链路查到后供后续前置检查与日志复用 */
  public static noteDeviceModel(deviceId: string, model: string): void {
    if (deviceId.length === 0 || model.length === 0) {
      return;
    }
    BluetoothService.modelCache.set(deviceId.toUpperCase(), model);
  }

  /** 读取缓存的耳机自报型号，未识别时为空串 */
  public static deviceModelOf(deviceId: string): string {
    if (deviceId.length === 0) {
      return '';
    }
    const model: string | undefined = BluetoothService.modelCache.get(deviceId.toUpperCase());
    return model !== undefined ? model : '';
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
    const context: common.UIAbilityContext | undefined = BluetoothService.context;
    if (context === undefined) {
      // 2026-11-26：init 漏存 context 时这里静默返回，界面只显示「需要蓝牙权限」，日志里什么都没有
      Logger.warn(MODULE, '申请蓝牙权限：缺少 context（蓝牙服务未初始化），未弹授权框');
      return false;
    }
    if (BluetoothService.hasPermission()) {
      BluetoothService.snapshot.authorized = true;
      BluetoothService.registerListeners();
      return true;
    }
    try {
      // 蓝牙与星闪属于同一“设备发现和连接”权限组，系统会合并授权；
      // 这里只申请蓝牙，避免同组权限被当成批量申请。
      const permissions: Permissions[] = [PERMISSION_BLUETOOTH];
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, permissions);
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

  /** 用户首次拒绝后，再次申请必须拉起权限设置页（系统不会再弹标准授权框） */
  public static async ensurePermissionOnSetting(): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = BluetoothService.context;
    if (context === undefined) {
      Logger.warn(MODULE, '拉起权限设置：缺少 context（蓝牙服务未初始化）');
      return false;
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const statuses: Array<abilityAccessCtrl.GrantStatus> =
        await manager.requestPermissionOnSetting(context, [PERMISSION_BLUETOOTH]);
      const granted: boolean = statuses.length > 0 &&
        statuses[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      if (granted) {
        BluetoothService.snapshot.authorized = true;
        BluetoothService.registerListeners();
      }
      Logger.info(MODULE, granted ? '蓝牙权限已在设置中开启' : '蓝牙权限仍未开启');
      return granted;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      // 12100012：权限列表里包含「用户尚未拒绝过」的权限。
      // 说明刚才的拒绝是系统因隐私未同意而做的静默拒绝（授权框根本没弹），
      // 这种权限不能跳设置页；回退到标准授权框，等隐私同意后它会正常弹出。
      if (err.code === 12100012) {
        Logger.warn(MODULE, '权限尚未被用户拒绝（隐私未同意导致的静默拒绝），回退标准授权框');
        return BluetoothService.ensurePermission();
      }
      Logger.exception(MODULE, '拉起权限设置失败', err);
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

  /**
   * 已配对但音频未连接时的兜底目标：仅在只有一个音频类已配对设备时返回。
   * 用于系统拒绝断开 A2DP 时，让用户先在系统蓝牙中断开音频再写入。
   */
  public static pairedAudioId(): string {
    const paired: BtDevice[] = BluetoothService.snapshot.pairedDevices;
    let found: string = '';
    let count: number = 0;
    for (let i = 0; i < paired.length; i++) {
      if (!paired[i].audio) {
        continue;
      }
      found = paired[i].deviceId;
      count++;
    }
    return count === 1 ? found : '';
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
    // 没授权时 A2DP 接口必然抛 201（权限校验失败），这不是异常：
    // 首页/音效库在用户点「允许」之前就会来问一次当前输出设备，
    // 提前返回空数组，既不刷警告也不会误判成"读取失败"。
    if (!BluetoothService.hasPermission()) {
      return merged;
    }
    try {
      const profile: a2dp.A2dpSourceProfile = a2dp.createA2dpSrcProfile();
      const ids: string[] = profile.getConnectedDevices();
      for (let i = 0; i < ids.length; i++) {
        BluetoothService.pushAddress(merged, ids[i]);
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.warn(MODULE, `读取 A2DP 已连接设备失败 code=${businessError.code} ${businessError.message}`);
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

  /**
   * 事件驱动的刷新入口：短时间内多次状态变化只跑最后一次。
   * 用户操作（页签切换、写入前后）仍走 refresh()，保证能拿到最新快照。
   */
  public static refreshDebounced(delayMs: number = 250): void {
    if (BluetoothService.refreshTimer >= 0) {
      clearTimeout(BluetoothService.refreshTimer);
    }
    BluetoothService.refreshTimer = setTimeout(() => {
      BluetoothService.refreshTimer = -1;
      BluetoothService.refresh();
    }, delayMs);
  }

  /**
   * 进入保存窗口：立即刷新一次，窗口结束时再刷新一次（窗口只由这里的定时器结束）。
   * 写入收完整包后由 WriteEngine 按沉降期剩余时长调用，与写入弹窗的等待倒计时同一个时钟；
   * 命令类操作（恢复默认 / 切内置音 / 回滚）不写闪存，沿用固定的音频恢复延迟。
   */
  public static markCaseSettling(deviceId: string, durationMs: number): void {
    if (deviceId.length === 0) {
      return;
    }
    BluetoothService.settlingId = deviceId;
    BluetoothService.settlingUntil = Date.now() + durationMs;
    Logger.info(MODULE, `CASE_SETTLING ms=${durationMs}`);
    if (BluetoothService.settleTimer >= 0) {
      clearTimeout(BluetoothService.settleTimer);
    }
    BluetoothService.settleTimer = setTimeout(() => {
      BluetoothService.settleTimer = -1;
      BluetoothService.endCaseSettling();
    }, durationMs);
    BluetoothService.refresh();
  }

  /** 结束保存窗口并按真实状态刷新：音频恢复流程开始时也会调用 */
  public static endCaseSettling(): void {
    if (BluetoothService.settleTimer >= 0) {
      clearTimeout(BluetoothService.settleTimer);
      BluetoothService.settleTimer = -1;
    }
    if (BluetoothService.settlingId.length === 0) {
      return;
    }
    BluetoothService.settlingId = '';
    BluetoothService.settlingUntil = 0;
    BluetoothService.refresh();
  }

  /** 保存窗口剩余时长（毫秒）；不在窗口内返回 0 */
  public static caseSettlingLeftMs(): number {
    if (BluetoothService.settlingId.length === 0) {
      return 0;
    }
    return Math.max(0, BluetoothService.settlingUntil - Date.now());
  }

  /** 保存窗口内的设备在配对列表里的位置；不在窗口内返回 -1 */
  private static settlingIndex(paired: BtDevice[]): number {
    if (BluetoothService.settlingId.length === 0 || Date.now() >= BluetoothService.settlingUntil) {
      return -1;
    }
    for (let i = 0; i < paired.length; i++) {
      if (BluetoothService.sameAddress(paired[i].deviceId, BluetoothService.settlingId)) {
        return i;
      }
    }
    return -1;
  }

  /** 刷新蓝牙状态与设备列表 */
  public static async refresh(): Promise<BtSnapshot> {
    const snapshot: BtSnapshot = createEmptySnapshot();
    snapshot.supported = true;
    try {
      snapshot.authorized = BluetoothService.hasPermission();
      if (!snapshot.authorized) {
        snapshot.statusText = I18n.t('bt.needPermission');
        BluetoothService.commit(snapshot);
        return snapshot;
      }
      // 权限可能在启动后才授予，这里补注册事件监听
      BluetoothService.registerListeners();

      const state: access.BluetoothState = access.getState();
      snapshot.enabled = state === access.BluetoothState.STATE_ON;
      if (!snapshot.enabled) {
        snapshot.statusText = I18n.t('bt.off');
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

      // 星闪补位：音频走星闪时 A2DP 不报告连接，用星闪配对表 + 连接状态还原真实情况。
      // 名称匹配只用于把星闪设备对应回经典蓝牙地址（写入仍走经典 SPP），匹配不上就只展示状态
      let viaNearLink: boolean = false;
      try {
        const near: NearLinkSnapshot = await NearLinkService.refresh();
        snapshot.nearLinkSupported = near.supported;
        snapshot.nearLinkEnabled = near.enabled;
        snapshot.nearLinkName = near.connectedName;
        if (near.connectedName.length > 0) {
          const nameLower: string = near.connectedName.toLowerCase();
          let matched: number = -1;
          for (let i = 0; i < paired.length; i++) {
            if (paired[i].audio && paired[i].name.toLowerCase() === nameLower) {
              matched = i;
              break;
            }
          }
          if (matched >= 0) {
            paired[matched].nearLink = true;
            snapshot.nearLinkBtId = paired[matched].deviceId;
            if (activeIndex < 0) {
              paired[matched].connected = true;
              snapshot.activeName = paired[matched].name;
              snapshot.activeId = paired[matched].deviceId;
              viaNearLink = true;
            }
          } else if (activeIndex < 0) {
            snapshot.activeName = near.connectedName;
            snapshot.activeId = '';
            viaNearLink = true;
          }
        }
      } catch (error) {
        Logger.warn(MODULE, `融合星闪状态失败 code=${(error as BusinessError).code}`);
      }

      snapshot.pairedDevices = paired;
      if (activeIndex >= 0) {
        snapshot.statusText = viaNearLink ? I18n.t('bt.nearLinkConnected') : I18n.t('bt.audioConnected');
      } else if (viaNearLink) {
        snapshot.statusText = snapshot.nearLinkBtId.length > 0 ?
          I18n.t('bt.nearLinkConnected') : I18n.t('bt.nearLinkConnectedNoBt');
      } else if (connectedIds.length > 0) {
        // 连上了但归不到配对列表里的地址（系统虚拟化地址）：仍要把名字显示出来，
        // 否则会出现「状态卡说未连接、却又标记已连接音频设备」的自相矛盾
        snapshot.activeId = connectedIds[0];
        snapshot.activeName = BluetoothService.displayNameOf(connectedIds[0]);
        snapshot.statusText = I18n.t('bt.audioConnected');
      } else if (paired.length > 0) {
        snapshot.statusText = I18n.t('bt.pairedNotConnected');
      } else {
        snapshot.statusText = I18n.t('bt.notPaired');
      }

      // 保存窗口：不管系统这时报连没连，都按「保存中」展示，等窗口结束再按真实状态刷新
      const settlingAt: number = BluetoothService.settlingIndex(paired);
      if (settlingAt >= 0) {
        paired[settlingAt].connected = false;
        snapshot.settling = true;
        snapshot.settlingId = paired[settlingAt].deviceId;
        snapshot.activeName = paired[settlingAt].name;
        snapshot.statusText = I18n.t('bt.caseSettling');
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
        snapshot.statusText = I18n.t('bt.needPermission');
      } else if (businessError.code === 801) {
        snapshot.supported = false;
        snapshot.statusText = I18n.t('bt.unsupported');
      } else if (businessError.code === 2900003) {
        snapshot.statusText = I18n.t('bt.off');
      } else {
        snapshot.statusText = I18n.f('bt.readFailed', [`${businessError.code}`]);
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
      connected: false,
      nearLink: false
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
