import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { Logger } from '../../common/utils/Logger';
import { NearLinkAlert } from '../../common/utils/NearLinkAlert';
import { DeviceRow } from '../../components/DeviceRow';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';
import { StatPill } from '../../components/StatPill';
import { BtDevice, BtSnapshot, createEmptySnapshot } from '../../models/DeviceModel';
import { BtChangeListener, BluetoothService } from '../../services/BluetoothService';
import { CaseWriteService } from '../../services/CaseWriteService';
import { DemoService } from '../../services/DemoService';
import { NearLinkService, NearLinkSnapshot } from '../../services/NearLinkService';

const MODULE: string = 'DevicePage';

@Component
export struct DevicePage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State snapshot: BtSnapshot = createEmptySnapshot();
  @State busy: boolean = false;
  private listener: BtChangeListener | undefined = undefined;
  private liveTimer: number = -1;
  private pollingLive: boolean = false;
  /** 已提醒过的星闪设备名：断开后清空，重新连上时再提醒一次 */
  private nearLinkNotified: string = '';

  aboutToAppear(): void {
    const handler: BtChangeListener = (next: BtSnapshot): void => {
      this.snapshot = next;
      this.warnNearLinkOnce();
    };
    this.listener = handler;
    BluetoothService.onChange(handler);
    this.startLiveRefresh();
    this.bootstrap();
  }

  /**
   * 星闪连接没有可订阅的系统事件：页面存活期间高频轻量轮询。
   * 只查星闪状态（约几十毫秒），连接状态变化时才做一次完整刷新，
   * 把「合盖断开 / 再次连上」的界面延迟压到 1.5 秒级。
   */
  private startLiveRefresh(): void {
    if (this.liveTimer >= 0) {
      return;
    }
    this.liveTimer = setInterval(() => {
      if (this.busy) {
        return;
      }
      if (!this.snapshot.nearLinkSupported || !this.snapshot.nearLinkEnabled) {
        return;
      }
      this.pollNearLink();
    }, 2000);
  }

  private stopLiveRefresh(): void {
    if (this.liveTimer >= 0) {
      clearInterval(this.liveTimer);
      this.liveTimer = -1;
    }
  }

  private async pollNearLink(): Promise<void> {
    if (this.pollingLive) {
      return;
    }
    this.pollingLive = true;
    try {
      const near: NearLinkSnapshot = await NearLinkService.refresh();
      if (near.connectedName !== this.snapshot.nearLinkName) {
        await this.load();
      }
    } finally {
      this.pollingLive = false;
    }
  }

  /** 首次进入：未授权则发起一次授权，再拉取状态 */
  private async bootstrap(): Promise<void> {
    if (DemoService.isActive()) {
      this.snapshot = await BluetoothService.refresh();
      return;
    }
    const granted: boolean = await BluetoothService.ensurePermission();
    if (!granted) {
      this.snapshot = await BluetoothService.refresh();
      return;
    }
    await this.load();
  }

  aboutToDisappear(): void {
    this.stopLiveRefresh();
    if (this.listener !== undefined) {
      BluetoothService.offChange(this.listener);
      this.listener = undefined;
    }
  }

  private async load(): Promise<void> {
    try {
      this.snapshot = await BluetoothService.refresh();
      this.warnNearLinkOnce();
    } catch (error) {
      Logger.exception(MODULE, '刷新失败', error as BusinessError);
    }
  }

  /** 检测到音频走星闪时提醒一次：每次（重新）连上只弹一次，断开后复位 */
  private warnNearLinkOnce(): void {
    if (DemoService.isActive()) {
      return;
    }
    const name: string = this.snapshot.nearLinkName;
    if (name.length === 0) {
      this.nearLinkNotified = '';
      return;
    }
    if (this.nearLinkNotified === name) {
      return;
    }
    this.nearLinkNotified = name;
    Logger.info(MODULE, `检测到星闪连接「${name}」，弹出写入限制提醒`);
    NearLinkAlert.show(this.getUIContext(), CaseWriteService.nearLinkHint(name));
  }

  /** 演示模式只是模拟设备，任何真实蓝牙操作都拦在这里 */
  private guardDemo(): boolean {
    if (!DemoService.isActive()) {
      return false;
    }
    this.toast('演示模式不操作真实蓝牙');
    return true;
  }

  private statusActionLabel(): string {
    if (DemoService.isActive()) {
      return '演示模式（不操作真实蓝牙）';
    }
    return this.snapshot.enabled ? '打开系统蓝牙设置' : '开启蓝牙';
  }

  private async requestPermission(): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    const granted: boolean = await BluetoothService.ensurePermission();
    if (granted) {
      await this.load();
      this.toast('蓝牙权限已开启');
    } else {
      this.toast('未授予蓝牙权限，无法搜索耳机');
    }
  }

  private async openSettings(): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    try {
      await BluetoothService.openSystemBluetoothSettings();
    } catch (error) {
      this.toast('无法打开系统蓝牙设置');
    }
  }

  private async enableBluetooth(): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    try {
      await BluetoothService.requestEnable();
    } catch (error) {
      this.toast('请手动在系统设置中开启蓝牙');
    }
  }

  private async connectDevice(device: BtDevice): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    this.busy = true;
    try {
      await BluetoothService.connect(device.deviceId);
      this.toast(`正在连接 ${device.name}`);
    } catch (error) {
      this.toast('连接失败，请在系统蓝牙设置中操作');
    } finally {
      this.busy = false;
    }
  }

  private async disconnectDevice(device: BtDevice): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    this.busy = true;
    try {
      await BluetoothService.disconnect(device.deviceId);
      this.toast(`已断开 ${device.name}`);
    } catch (error) {
      this.toast('断开失败，请在系统蓝牙设置中操作');
    } finally {
      this.busy = false;
    }
  }

  private async pairDevice(device: BtDevice): Promise<void> {
    if (this.guardDemo()) {
      return;
    }
    this.busy = true;
    try {
      await BluetoothService.pair(device.deviceId);
      this.toast(`正在配对 ${device.name}`);
    } catch (error) {
      this.toast('配对失败，请在系统设置中操作');
    } finally {
      this.busy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** 当前输出设备判定：与状态卡共用 snapshot.activeId，保证两边不会互相矛盾 */
  private isConnected(device: BtDevice): boolean {
    const activeId: string = this.snapshot.activeId;
    if (activeId.length === 0 || device.deviceId.length === 0) {
      return false;
    }
    return activeId.toUpperCase() === device.deviceId.toUpperCase();
  }

  private rowDevice(device: BtDevice): BtDevice {
    const row: BtDevice = {
      deviceId: device.deviceId,
      name: device.name,
      paired: device.paired,
      audio: device.audio,
      connected: this.isConnected(device),
      nearLink: device.nearLink
    };
    return row;
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildStatusCard()

        if (!this.snapshot.authorized) {
          this.buildPermissionCard()
        }

        this.buildPairedSection()
        this.buildNearbySection()
        this.buildGuideCard()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Metric.PAGE_PADDING,
        right: Metric.PAGE_PADDING,
        top: 8,
        bottom: Metric.CONTENT_BOTTOM_INSET
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  buildHeader() {
    Column({ space: 6 }) {
      Text('设备')
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('连接你的华为耳机，准备写入开盖音效')
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 4 })
  }

  @Builder
  buildStatusCard() {
    GlassCard({ cardPadding: 16 }) {
      Row({ space: 12 }) {
        Stack() {
          Circle()
            .width(44)
            .height(44)
            .fill(this.snapshot.activeName.length > 0 ? Palette.ACCENT_SOFT : Palette.FILL_FAINT)
          Image($r('app.media.ic_tab_device'))
            .width(20)
            .height(20)
            .fillColor(this.snapshot.activeName.length > 0 ? Palette.ACCENT : Palette.TEXT_TERTIARY)
        }

        Column({ space: 7 }) {
          Text(this.snapshot.activeName.length > 0 ? this.snapshot.activeName : '未连接耳机')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          StatPill({
            pillText: this.snapshot.statusText,
            pillTone: this.snapshot.activeName.length > 0 ? 'success' : 'muted'
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider()
        .color(Palette.FILL_SOFT)
        .margin({ top: 16, bottom: 14 })

      Row() {
        MetricCell({
          cellLabel: '音频通道',
          cellValue: this.snapshot.nearLinkName.length > 0 ? '星闪' :
            (this.snapshot.activeName.length > 0 ? '已连接' : '未连接'),
          cellColor: this.snapshot.nearLinkName.length > 0 ? Palette.ACCENT :
            (this.snapshot.activeName.length > 0 ? Palette.SUCCESS : Palette.TEXT_SECONDARY)
        })
        MetricCell({
          cellLabel: '已配对',
          cellValue: `${this.snapshot.pairedDevices.length} 台`,
          cellColor: Palette.TEXT_PRIMARY
        })
        MetricCell({ cellLabel: '写入方式', cellValue: '文件替换', cellColor: Palette.TEXT_PRIMARY })
      }
      .width('100%')

      GhostButton({
        ghostLabel: this.statusActionLabel(),
        onTap: (): void => {
          if (this.snapshot.enabled) {
            this.openSettings();
          } else {
            this.enableBluetooth();
          }
        }
      })
        .margin({ top: 16 })
    }
  }

  @Builder
  buildPermissionCard() {
    GlassCard({ cardBg: Palette.WARNING_SOFT, cardStroke: 'rgba(255, 184, 77, 0.28)' }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_alert'))
          .width(18)
          .height(18)
          .fillColor(Palette.WARNING)
        Column({ space: 4 }) {
          Text('需要蓝牙权限')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('用于搜索、配对耳机并读取连接状态，仅在本机使用')
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Text('去授权')
        .fontSize(13)
        .fontColor('#10151F')
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(38)
        .borderRadius(12)
        .backgroundColor(Palette.WARNING)
        .margin({ top: 12 })
        .onClick(() => {
          this.requestPermission();
        })
    }
  }

  @Builder
  buildPairedSection() {
    SectionTitle({
      sectionText: '已配对设备',
      sectionHint: this.snapshot.scanning ? '正在扫描…' : `${this.snapshot.pairedDevices.length} 台`
    })

    GlassCard({ cardPadding: 8 }) {
      if (this.snapshot.pairedDevices.length === 0) {
        EmptyView({
          emptyTitle: '还没有配对设备',
          emptyDesc: '打开充电盒盖，在系统蓝牙设置中完成首次配对后回到这里'
        })
      } else {
        ForEach(this.snapshot.pairedDevices, (device: BtDevice, index: number) => {
          Column() {
            DeviceRow({
              // 连接状态只认快照里的 activeId，避免行数据自身残留旧值
              device: this.rowDevice(device),
              actionLabel: this.busy ? '处理中' : (this.isConnected(device) ? '断开' : '去连接'),
              onAction: (): void => {
                if (this.isConnected(device)) {
                  this.disconnectDevice(device);
                } else {
                  this.connectDevice(device);
                }
              }
            })
            if (index < this.snapshot.pairedDevices.length - 1) {
              Divider()
                .color(Palette.FILL_FAINT)
                .margin({ left: 50 })
            }
          }
          .width('100%')
        }, (device: BtDevice) =>
          `${device.deviceId}-${device.name}-${this.isConnected(device) ? 'on' : 'off'}`)
      }
    }
  }

  @Builder
  buildNearbySection() {
    Row() {
      Text('附近设备')
        .fontSize(Metric.SECTION_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TEXT_PRIMARY)
        .layoutWeight(1)
      Text(this.snapshot.scanning ? '停止' : '扫描')
        .fontSize(12)
        .fontColor(this.snapshot.scanning ? Palette.DANGER : Palette.ACCENT)
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .borderRadius(999)
        .backgroundColor(this.snapshot.scanning ? Palette.DANGER_SOFT : Palette.ACCENT_SOFT)
        .onClick(() => {
          if (this.guardDemo()) {
            return;
          }
          if (this.snapshot.scanning) {
            BluetoothService.stopScan();
          } else {
            BluetoothService.startScan();
          }
        })
    }
    .width('100%')
    .margin({ top: 4, bottom: 10 })

    GlassCard({ cardPadding: 8 }) {
      if (this.snapshot.nearbyDevices.length === 0) {
        EmptyView({
          emptyIcon: $r('app.media.ic_add'),
          emptyTitle: this.snapshot.scanning ? '正在搜索附近设备…' : '尚未扫描',
          emptyDesc: this.snapshot.scanning ? '请保持充电盒开盖并靠近手机' : '点击右上角「扫描」发现附近设备'
        })
      } else {
        ForEach(this.snapshot.nearbyDevices, (device: BtDevice, index: number) => {
          Column() {
            DeviceRow({
              device: device,
              actionLabel: this.busy ? '处理中' : '配对',
              showAction: !device.paired,
              onAction: (): void => {
                this.pairDevice(device);
              }
            })
            if (index < this.snapshot.nearbyDevices.length - 1) {
              Divider()
                .color(Palette.FILL_FAINT)
                .margin({ left: 50 })
            }
          }
          .width('100%')
        }, (device: BtDevice) => `${device.deviceId}-${device.name}`)
      }
    }
  }

  @Builder
  buildGuideCard() {
    SectionTitle({ sectionText: '写入流程' })

    GlassCard({ cardPadding: 16 }) {
      this.stepItem('1', '连接与配对', '在本页完成配对，配对成功后会自动连接音频通道')
      this.stepItem('2', '制作音效', '在「音效」页导入素材或使用内置音色，按 16700Hz 规格生成')
      this.stepItem('3', '写入充电盒', '双耳放入盒内、打开盒盖，在「音效库」点写入即可直接下发')
    }
  }

  @Builder
  stepItem(order: string, title: string, desc: string) {
    Row({ space: 12 }) {
      Text(order)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.ACCENT)
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor(Palette.ACCENT_SOFT)

      Column({ space: 3 }) {
        Text(title)
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(desc)
          .fontSize(11)
          .fontColor(Palette.TEXT_TERTIARY)
          .lineHeight(16)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }
}

/**
 * 指标单元
 * 必须用带 @Prop 的独立组件：@Builder 按值传参时参数变化不会触发 UI 刷新
 */
@Component
struct MetricCell {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop cellLabel: string = '';
  @Prop cellValue: string = '';
  /** 留空时按当前外观取默认值 */
  @Prop cellColor: string = '';

  build() {
    Column({ space: 5 }) {
      Text(this.cellValue)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cellColor.length > 0 ? this.cellColor : Palette.TEXT_PRIMARY)
      Text(this.cellLabel)
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
