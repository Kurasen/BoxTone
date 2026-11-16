import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DeviceSupport, SupportInfo, ToneSpec, VerifiedDevice } from '../../common/constants/AppConstants';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';
import { SpecRow } from '../../components/SpecRow';
import { LogService } from '../../services/LogService';
import { PrivacyLinkService } from '../../services/PrivacyLinkService';
import { SettingsService } from '../../services/SettingsService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'ProfilePage';

@Component
export struct ProfilePage {
  @State versionName: string = '1.0.0';
  @State toneCount: number = 0;
  @State toneBytes: number = 0;
  @State logCount: number = 0;
  @State logBytes: number = 0;
  @State autoNormalize: boolean = true;
  @State privacyUrl: string = '';
  private changeHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    this.refresh();
    this.readVersion();
    this.privacyUrl = PrivacyLinkService.statementUrl();
    this.changeHandler = (): void => {
      this.refresh();
    };
    EventBus.on(AppEvent.TONE_CHANGED, this.changeHandler);
  }

  aboutToDisappear(): void {
    if (this.changeHandler !== undefined) {
      EventBus.off(AppEvent.TONE_CHANGED);
      this.changeHandler = undefined;
    }
  }

  private refresh(): void {
    this.toneCount = ToneRepositoryService.count();
    this.toneBytes = ToneRepositoryService.totalBytes();
    this.logCount = LogService.getInstance().getEntryCount();
    this.logBytes = LogService.getInstance().getLogFileSize();
    this.autoNormalize = SettingsService.get().autoNormalize;
  }

  private readVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (error) {
      Logger.exception(MODULE, '读取版本号失败', error as BusinessError);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private async exportLog(): Promise<void> {
    try {
      const fileName: string = await LogService.getInstance().exportToFile();
      if (fileName.length > 0) {
        this.toast(`日志已导出 ${fileName}`);
        this.refresh();
      }
    } catch (error) {
      this.toast('导出失败，请查看日志');
    }
  }

  private confirmClearLog(): void {
    this.getUIContext().showAlertDialog({
      title: '清空日志',
      message: '将删除本机全部诊断日志，删除后无法恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Palette.DANGER,
        action: (): void => {
          LogService.getInstance().clear();
          this.refresh();
          this.toast('日志已清空');
        }
      }
    });
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildAppCard()
        this.buildStats()
        this.buildActions()
        this.buildPrefs()
        this.buildDevices()
        this.buildSpecCard()
        this.buildLegal()
        this.buildAbout()
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
      Text('我的')
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('规格说明、诊断日志与偏好设置')
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 4 })
  }

  @Builder
  buildAppCard() {
    GlassCard({ cardPadding: 18 }) {
      Row({ space: 14 }) {
        Image($r('app.media.app_icon'))
          .width(52)
          .height(52)
          .borderRadius(14)

        Column({ space: 5 }) {
          Text('盒音工坊')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
          Text(`v${this.versionName} · 为华为充电盒定制提示音`)
            .fontSize(11)
            .fontColor(Palette.TEXT_TERTIARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
  }

  @Builder
  buildStats() {
    Row({ space: Metric.GAP }) {
      StatCell({ cellLabel: '音效', cellValue: `${this.toneCount}`, cellUnit: '个' })
      StatCell({ cellLabel: '存储', cellValue: FormatUtils.bytes(this.toneBytes), cellUnit: '' })
      StatCell({ cellLabel: '日志', cellValue: `${this.logCount}`, cellUnit: '条' })
    }
    .width('100%')
  }

  @Builder
  buildActions() {
    SectionTitle({ sectionText: '诊断与日志' })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: '日志中心',
        rowDesc: `${this.logCount} 条记录 · ${FormatUtils.bytes(this.logBytes)}`,
        rowIcon: $r('app.media.ic_log'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_LOG, 1);
        }
      })
      Divider()
        .color('rgba(255, 255, 255, 0.05)')
        .margin({ left: 16, right: 16 })
      ActionRow({
        rowTitle: '反馈与建议',
        rowDesc: SupportInfo.FEEDBACK_ONLINE_ENABLED
          ? '提交问题或建议，自动附带诊断日志'
          : '在线反馈暂未开放，可通过邮箱联系',
        rowIcon: $r('app.media.ic_feedback'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_FEEDBACK, 1);
        }
      })
      Divider()
        .color('rgba(255, 255, 255, 0.05)')
        .margin({ left: 16, right: 16 })
      ActionRow({
        rowTitle: '导出错误日志',
        rowDesc: '生成 txt 诊断报告，便于反馈问题',
        rowIcon: $r('app.media.ic_upload'),
        onTap: (): void => {
          this.exportLog();
        }
      })
      Divider()
        .color('rgba(255, 255, 255, 0.05)')
        .margin({ left: 16, right: 16 })
      ActionRow({
        rowTitle: '清空日志',
        rowDesc: '删除本机全部诊断记录',
        rowIcon: $r('app.media.ic_trash'),
        onTap: (): void => {
          this.confirmClearLog();
        }
      })
    }
  }

  @Builder
  buildPrefs() {
    SectionTitle({ sectionText: '偏好设置' })

    GlassCard({ cardPadding: 4 }) {
      Row({ space: 12 }) {
        Image($r('app.media.ic_sparkle'))
          .width(18)
          .height(18)
          .fillColor(Palette.TEXT_SECONDARY)
          .margin({ left: 12 })
        Column({ space: 3 }) {
          Text('生成时峰值归一化')
            .fontSize(14)
            .fontColor(Palette.TEXT_PRIMARY)
          Text('自动把音量拉满到 -0.2dBFS，避免写入后声音偏小')
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.autoNormalize })
          .selectedColor(Palette.ACCENT)
          .margin({ right: 12 })
          .onChange((isOn: boolean) => {
            this.autoNormalize = isOn;
            SettingsService.setAutoNormalize(isOn);
            this.toast(isOn ? '已开启自动归一化' : '已关闭自动归一化');
          })
      }
      .width('100%')
      .height(62)
    }
  }

  @Builder
  buildDevices() {
    SectionTitle({
      sectionText: '已验证支持设备',
      sectionHint: `${DeviceSupport.VERIFIED.length} 款`
    })

    GlassCard({ cardPadding: 16 }) {
      ForEach(DeviceSupport.VERIFIED, (device: VerifiedDevice, index: number) => {
        if (index > 0) {
          Divider()
            .color('rgba(255, 255, 255, 0.05)')
            .margin({ top: 10, bottom: 10 })
        }
        Row({ space: 10 }) {
          Stack() {
            Image($r('app.media.ic_check'))
              .width(10)
              .height(10)
              .fillColor(Palette.SUCCESS)
          }
          .width(18)
          .height(18)
          .borderRadius(9)
          .backgroundColor(Palette.SUCCESS_SOFT)

          Column({ space: 3 }) {
            Text(device.name)
              .fontSize(14)
              .fontColor(Palette.TEXT_PRIMARY)
            Text(device.detail)
              .fontSize(10)
              .fontColor(Palette.TEXT_TERTIARY)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('已验证')
            .fontSize(10)
            .fontColor(Palette.SUCCESS)
        }
        .width('100%')
      }, (device: VerifiedDevice) => device.name)

      Text('其他机型尚未实测：不兼容时会被盒子拒绝写入，不会损坏设备。')
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .lineHeight(16)
        .margin({ top: 12 })
    }
  }

  @Builder
  buildSpecCard() {
    SectionTitle({ sectionText: '盒端播放规格' })

    GlassCard({ cardPadding: 18 }) {
      SpecRow({ specLabel: '采样率', specValue: `${ToneSpec.SAMPLE_RATE} Hz`, showDivider: true })
      SpecRow({ specLabel: '位深', specValue: '16 bit 有符号', showDivider: true })
      SpecRow({ specLabel: '声道', specValue: '单声道 Mono', showDivider: true })
      SpecRow({ specLabel: '文件头', specValue: '无（RAW）', showDivider: true })
      SpecRow({ specLabel: '单秒大小', specValue: `${ToneSpec.BYTES_PER_SECOND} 字节`, showDivider: true })
      SpecRow({
        specLabel: '时长上限',
        specValue: `${ToneSpec.MAX_SECONDS} 秒 / ${ToneSpec.MAX_BYTES} 字节`
      })

      Column({ space: 8 }) {
        Text('为什么是 16700Hz')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.ACCENT)
        Text('充电盒的音频解码器未使用标准 16000Hz，而是标定在约 16700Hz。' +
          '若直接放入 16000Hz 素材，播放时音调会整体升高；按 16700Hz 导出可保持原本听感。')
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(18)
        Text('文件大小 = 声道数 × 位深 × 采样率 × 时长 ÷ 8，1 秒固定为 33400 字节。' +
          '因无文件头，时长与体积严格成正比，超长文件无法写入充电盒。')
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(18)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 14 })
    }
  }

  @Builder
  buildLegal() {
    // 托管链接由 AGC 下发；本地调试或非市场安装时取不到，直接隐藏入口
    if (this.privacyUrl.length > 0) {
      SectionTitle({ sectionText: '隐私与协议' })

      GlassCard({ cardPadding: 4 }) {
        ActionRow({
          rowTitle: '隐私政策',
          rowDesc: '查看我们如何处理你的信息',
          rowIcon: $r('app.media.ic_info'),
          onTap: (): void => {
            this.openPrivacy();
          }
        })
      }
    }
  }

  private openPrivacy(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean) => {
      if (!opened) {
        this.toast('隐私政策链接暂不可用，请稍后重试');
      }
    });
  }

  @Builder
  buildAbout() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_info'))
          .width(13)
          .height(13)
          .fillColor(Palette.TEXT_TERTIARY)
        Text('开盒音通过蓝牙串口（SPP）直接写入充电盒，无需导出文件。' +
          '写入时请把双耳放入盒内并打开盒盖，过程中会临时断开音频通道。')
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .lineHeight(16)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text('本应用与华为无关，音效素材请确保拥有合法使用权')
        .fontSize(9)
        .fontColor('rgba(255, 255, 255, 0.22)')
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4 })
  }
}

/** 统计卡片：用 @Prop 保证数值变化时刷新 */
@Component
struct StatCell {
  @Prop cellLabel: string = '';
  @Prop cellValue: string = '';
  @Prop cellUnit: string = '';

  build() {
    Column({ space: 6 }) {
      Row({ space: 2 }) {
        Text(this.cellValue)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        if (this.cellUnit.length > 0) {
          Text(this.cellUnit)
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
            .margin({ bottom: 2 })
        }
      }
      Text(this.cellLabel)
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(18)
    .backgroundColor(Palette.BG_CARD)
    .border({ width: 1, color: Palette.STROKE_SOFT })
  }
}

/** 设置行：@Prop 保证描述文案（含实时统计）变化时刷新 */
@Component
struct ActionRow {
  @Prop rowTitle: string = '';
  @Prop rowDesc: string = '';
  rowIcon: Resource = $r('app.media.ic_log');
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Image(this.rowIcon)
        .width(18)
        .height(18)
        .fillColor(Palette.TEXT_SECONDARY)
        .margin({ left: 12 })

      Column({ space: 3 }) {
        Text(this.rowTitle)
          .fontSize(14)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(this.rowDesc)
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Image($r('app.media.ic_chevron_right'))
        .width(13)
        .height(13)
        .fillColor(Palette.TEXT_TERTIARY)
        .margin({ right: 12 })
    }
    .width('100%')
    .height(58)
    .onClick(() => {
      this.onTap();
    })
  }
}
