import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { Logger } from '../../common/utils/Logger';
import { NearLinkAlert } from '../../common/utils/NearLinkAlert';
import { DeviceRow } from '../../components/DeviceRow';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';
import { StatPill } from '../../components/StatPill';
import { BtDevice, BtSnapshot, createEmptySnapshot } from '../../models/DeviceModel';
import { BluetoothService, BtChangeListener } from '../../services/BluetoothService';
import { PrivacyConsentService } from '../../services/PrivacyConsentService';
import { WriteCompatibility } from '../../services/WriteCompatibility';
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
  /** 隐私放行事件的监听：同意前不读设备，放行后再拉状态 */
  private privacyHandler: SimpleHandler | undefined = undefined;
  /** 已提醒过的星闪设备名：断开后清空，重新连上时再提醒一次 */
  private nearLinkNotified: string = '';

  aboutToAppear(): void {
    const handler: BtChangeListener = (next: BtSnapshot): void => {
      this.snapshot = next;
      this.warnNearLinkOnce();
    };
    this.listener = handler;
    // 只是挂监听，不读任何设备数据
    BluetoothService.onChange(handler);
    if (PrivacyConsentService.isCleared()) {
      this.startLiveRefresh();
      this.bootstrap();
      return;
    }
    // 同意前先渲染空态（未连接 / 0 台），放行后再拉真实状态
    this.privacyHandler = (): void => {
      this.startLiveRefresh();
      this.bootstrap();
    };
    EventBus.on(AppEvent.PRIVACY_CLEARED, this.privacyHandler);
  }

  /**
   * 星闪连接没有可订阅的系统事件：页面存活期间高频轻量轮询。
   * 只查星闪状态（约几十毫秒），连接状态变化时才做一次完整刷新，
   * 把「合盖断开 / 再次连上」的界面延迟压到 1.5 秒级。
   */
  private startLiveRefresh(): void {
    // 未放行前不轮询：pollNearLink 会读已配对设备
    if (!PrivacyConsentService.isCleared()) {
      return;
    }
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

  /** 首次进入只读取状态，不主动弹权限；用户点“去授权”时再申请 */
  private async bootstrap(): Promise<void> {
    await this.load();
  }

  aboutToDisappear(): void {
    this.stopLiveRefresh();
    if (this.listener !== undefined) {
      BluetoothService.offChange(this.listener);
      this.listener = undefined;
    }
    if (this.privacyHandler !== undefined) {
      EventBus.off(AppEvent.PRIVACY_CLEARED, this.privacyHandler);
      this.privacyHandler = undefined;
    }
  }

  private async load(): Promise<void> {
    // 同意前不读设备：refresh 会取已配对设备与设备名
    if (!PrivacyConsentService.isCleared()) {
      return;
    }
    try {
      this.snapshot = await BluetoothService.refresh();
      this.warnNearLinkOnce();
    } catch (error) {
      Logger.exception(MODULE, '刷新失败', error as BusinessError);
    }
  }

  /** 检测到音频走星闪时提醒一次：每次（重新）连上只弹一次，断开后复位 */
  private warnNearLinkOnce(): void {
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
    NearLinkAlert.show(this.getUIContext(), WriteCompatibility.nearLinkHint(name));
  }

  private statusActionLabel(): string {
    return this.snapshot.enabled ? I18n.t('device.openSettings') : I18n.t('device.enableBt');
  }

  /** 状态卡的“开启蓝牙”：未授权时先授权，授权后若仍未开再拉起系统开启框 */
  private async requestPermissionAndEnable(): Promise<void> {
    const granted: boolean = await BluetoothService.ensurePermission();
    if (!granted) {
      this.showPermissionDenied();
      return;
    }
    await this.load();
    if (!this.snapshot.enabled) {
      await this.enableBluetooth();
    }
  }

  private async requestPermission(): Promise<void> {
    const granted: boolean = await BluetoothService.ensurePermission();
    if (granted) {
      await this.load();
      this.toast(I18n.t('device.permGranted'));
      return;
    }
    this.showPermissionDenied();
  }

  /** 首次拒绝后系统不再弹标准授权框，引导到权限设置页 */
  private showPermissionDenied(): void {
    this.getUIContext().showAlertDialog({
      title: I18n.t('device.needPermission'),
      message: I18n.t('device.permissionSettingsDesc'),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('device.goSettings'),
        fontColor: Palette.ACCENT_TEXT,
        action: (): void => {
          this.openPermissionSettings();
        }
      }
    });
  }

  private async openPermissionSettings(): Promise<void> {
    const granted: boolean = await BluetoothService.ensurePermissionOnSetting();
    if (granted) {
      await this.load();
      this.toast(I18n.t('device.permGranted'));
    } else {
      this.toast(I18n.t('device.permDenied'));
    }
  }

  private async openSettings(): Promise<void> {
    try {
      await BluetoothService.openSystemBluetoothSettings();
    } catch (error) {
      this.toast(I18n.t('device.openSettingsFailed'));
    }
  }

  private async enableBluetooth(): Promise<void> {
    try {
      await BluetoothService.requestEnable();
    } catch (error) {
      this.toast(I18n.t('device.enableManual'));
    }
  }

  private async connectDevice(device: BtDevice): Promise<void> {
    this.busy = true;
    try {
      await BluetoothService.connect(device.deviceId);
      this.toast(I18n.f('device.connecting', [device.name]));
    } catch (error) {
      this.toast(I18n.t('device.connectFailed'));
    } finally {
      this.busy = false;
    }
  }

  private async disconnectDevice(device: BtDevice): Promise<void> {
    this.busy = true;
    try {
      await BluetoothService.disconnect(device.deviceId);
      this.toast(I18n.f('device.disconnected', [device.name]));
    } catch (error) {
      this.toast(I18n.t('device.disconnectFailed'));
    } finally {
      this.busy = false;
    }
  }

  private async pairDevice(device: BtDevice): Promise<void> {
    this.busy = true;
    try {
      await BluetoothService.pair(device.deviceId);
      this.toast(I18n.f('device.pairing', [device.name]));
    } catch (error) {
      this.toast(I18n.t('device.pairFailed'));
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
    // 切到别的页签时停掉星闪轮询：TabContent 不会销毁子页，不显式停就会在后台每 2 秒空跑一次。
    // 若某些版本不回调，aboutToAppear 里已经启动过，行为与改动前一致，不会退化
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      if (isVisible && currentRatio > 0) {
        this.startLiveRefresh();
        return;
      }
      this.stopLiveRefresh();
    })
  }

  @Builder
  buildHeader() {
    Column({ space: 6 }) {
      Text(I18n.t('device.title'))
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(I18n.t('device.subtitle'))
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
          Text(this.snapshot.activeName.length > 0 ? this.snapshot.activeName : I18n.t('device.notConnected'))
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
          cellLabel: I18n.t('device.channel'),
          cellValue: this.snapshot.nearLinkName.length > 0 ? I18n.t('device.nearLink') :
            (this.snapshot.activeName.length > 0 ? I18n.t('device.connected') : I18n.t('device.disconnectedShort')),
          cellColor: this.snapshot.nearLinkName.length > 0 ? Palette.ACCENT :
            (this.snapshot.activeName.length > 0 ? Palette.SUCCESS : Palette.TEXT_SECONDARY)
        })
        MetricCell({
          cellLabel: I18n.t('device.paired'),
          cellValue: I18n.f('device.pairedCount', [`${this.snapshot.pairedDevices.length}`]),
          cellColor: Palette.TEXT_PRIMARY
        })
        MetricCell({
          cellLabel: I18n.t('device.writeMode'),
          cellValue: I18n.t('device.btDirect'),
          cellColor: Palette.TEXT_PRIMARY
        })
      }
      .width('100%')

      GhostButton({
        ghostLabel: this.statusActionLabel(),
        onTap: (): void => {
          if (!this.snapshot.authorized) {
            this.requestPermissionAndEnable();
          } else if (this.snapshot.enabled) {
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
    GlassCard({ cardBg: Palette.ACCENT_SOFT, cardStroke: Palette.ACCENT_LINE }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_alert'))
          .width(18)
          .height(18)
          .fillColor(Palette.ACCENT_TEXT)
        Column({ space: 4 }) {
          Text(I18n.t('device.needPermission'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
          Text(I18n.t('device.permissionDesc'))
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Text(I18n.t('device.grant'))
        .fontSize(13)
        .fontColor('#05080E')
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(38)
        .borderRadius(12)
        .backgroundColor(Palette.ACCENT)
        .margin({ top: 12 })
        .onClick(() => {
          this.requestPermission();
        })
    }
  }

  @Builder
  buildPairedSection() {
    SectionTitle({
      sectionText: I18n.t('device.pairedDevices'),
      sectionHint: this.snapshot.scanning ? I18n.t('device.scanning') :
        I18n.f('device.pairedCount', [`${this.snapshot.pairedDevices.length}`])
    })

    GlassCard({ cardPadding: 8 }) {
      if (this.snapshot.pairedDevices.length === 0) {
        EmptyView({
          emptyTitle: I18n.t('device.noPaired'),
          emptyDesc: I18n.t('device.noPairedDesc')
        })
      } else {
        ForEach(this.snapshot.pairedDevices, (device: BtDevice, index: number) => {
          Column() {
            DeviceRow({
              // 连接状态只认快照里的 activeId，避免行数据自身残留旧值
              device: this.rowDevice(device),
              actionLabel: this.busy ? I18n.t('device.busy') :
                (this.isConnected(device) ? I18n.t('device.disconnect') : I18n.t('device.connect')),
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
      Text(I18n.t('device.nearby'))
        .fontSize(Metric.SECTION_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TEXT_PRIMARY)
        .layoutWeight(1)
      Text(this.snapshot.scanning ? I18n.t('device.stopScan') : I18n.t('device.scan'))
        .fontSize(12)
        .fontColor(this.snapshot.scanning ? Palette.DANGER : Palette.ACCENT)
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .borderRadius(999)
        .backgroundColor(this.snapshot.scanning ? Palette.DANGER_SOFT : Palette.ACCENT_SOFT)
        .onClick(() => {
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
          emptyTitle: this.snapshot.scanning ? I18n.t('device.searching') : I18n.t('device.notScanned'),
          emptyDesc: this.snapshot.scanning ? I18n.t('device.keepLidOpen') : I18n.t('device.tapScan')
        })
      } else {
        ForEach(this.snapshot.nearbyDevices, (device: BtDevice, index: number) => {
          Column() {
            DeviceRow({
              device: device,
              actionLabel: this.busy ? I18n.t('device.busy') : I18n.t('device.pair'),
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
    SectionTitle({ sectionText: I18n.t('device.flow') })

    GlassCard({ cardPadding: 16 }) {
      this.stepItem('1', I18n.t('device.step1Title'), I18n.t('device.step1Desc'))
      this.stepItem('2', I18n.t('device.step2Title'), I18n.t('device.step2Desc'))
      this.stepItem('3', I18n.t('device.step3Title'), I18n.t('device.step3Desc'))
    }
  }

  @Builder
  stepItem(order: string, title: string, desc: string) {
    Row({ space: 12 }) {
      Text(order)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.ACCENT_TEXT)
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
