import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DeviceSupport, DeviceSupportLevel, SupportInfo, ToneSpec } from '../../common/constants/AppConstants';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { RatingService } from '../../services/RatingService';
import { AppEnv } from '../../common/utils/AppEnv';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';
import { SpecRow } from '../../components/SpecRow';
import { LogService } from '../../services/LogService';
import { PrivacyLinkService } from '../../services/PrivacyLinkService';
import { ThemeMode, ThemeService } from '../../services/ThemeService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';
import { SettingsService } from '../../services/SettingsService';
import { WriteSpec } from '../../services/write/WriteSpec';

const MODULE: string = 'ProfilePage';
const ABOUT_HEADER_HEIGHT: number = 64;

@Component
export struct ProfilePage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State versionName: string = '1.0.0';
  /** 连点版本号 3 次进入评分测试，普通用户碰不到 */
  @State versionTapCount: number = 0;
  @State versionCode: number = 0;
  @State toneCount: number = 0;
  @State toneBytes: number = 0;
  @State logCount: number = 0;
  @State logBytes: number = 0;
  @State showAbout: boolean = false;
  /** 捐赠收款码弹窗 */
  private donateDialog: CustomDialogController = new CustomDialogController({
    builder: DonateQrDialog(),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Center,
    width: '88%'
  });
  private changeHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    // 同意前统计读到的是 0（业务服务未初始化）；放行时再刷一次真实数据
    this.refresh();
    this.readVersion();
    this.changeHandler = (): void => {
      this.refresh();
    };
    EventBus.on(AppEvent.TONE_CHANGED, this.changeHandler);
    EventBus.on(AppEvent.PRIVACY_CLEARED, this.changeHandler);
  }

  aboutToDisappear(): void {
    if (this.changeHandler !== undefined) {
      EventBus.off(AppEvent.TONE_CHANGED, this.changeHandler);
      EventBus.off(AppEvent.PRIVACY_CLEARED, this.changeHandler);
      this.changeHandler = undefined;
    }
  }

  /**
   * 连点版本号 3 次进入评分测试。
   *
   * 评分的四个前置条件（写入 2 次、使用 3 天、近 7 天无失败、冷却间隔）在本地没法自然凑齐，
   * 这里把条件模拟成「刚好满足」后走完整正式判断，验证系统弹窗本身是否正常。
   */
  private onVersionTap(): void {
    // 正式版完全不响应：连点也什么都不发生，避免测试入口漏到线上
    if (!AppEnv.isDebug()) {
      return;
    }
    this.versionTapCount++;
    if (this.versionTapCount < 3) {
      return;
    }
    this.versionTapCount = 0;
    this.showDebugMenu();
  }

  /**
   * 调试菜单（只在 debug 包出现）：评分测试，以及写后间隔测试。
   * 间隔改动立即生效并保存，重启后仍保留；日志里每次写入都会打 GAP_TEST，便于和结局对照。
   */
  private showDebugMenu(): void {
    const current: number = WriteSpec.postFlashGapMs();
    const pick: (ms: number) => void = (ms: number): void => {
      WriteSpec.gapOverrideMs = ms === WriteSpec.POST_FLASH_GAP_MS ? 0 : ms;
      SettingsService.setDebugFlashGapMs(WriteSpec.gapOverrideMs);
      Logger.info(MODULE, `调试：写后间隔改为 ${WriteSpec.postFlashGapMs()}ms`);
      this.toast(`写后间隔：${Math.round(WriteSpec.postFlashGapMs() / 1000)} 秒`);
    };
    const gaps: number[] = [25000, 20000, 15000, 10000];
    const sheets: SheetInfo[] = [{
      title: I18n.t('profile.ratingTestTitle'),
      action: (): void => {
        this.showRatingTest();
      }
    }];
    for (let i = 0; i < gaps.length; i++) {
      const ms: number = gaps[i];
      sheets.push({
        title: `写后间隔 ${ms / 1000} 秒${ms === WriteSpec.POST_FLASH_GAP_MS ? '（默认）' : ''}${ms === current ? ' ✓' : ''}`,
        action: (): void => {
          pick(ms);
        }
      });
    }
    this.getUIContext().showActionSheet({
      title: '调试',
      message: `当前写后间隔 ${Math.round(current / 1000)} 秒`,
      sheets: sheets
    });
  }

  private showRatingTest(): void {
    this.getUIContext().showAlertDialog({
      title: I18n.t('profile.ratingTestTitle'),
      message: I18n.t('profile.ratingTestBody'),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('profile.ratingTestGo'),
        action: (): void => {
          RatingService.simulateSatisfied(
            this.getUIContext().getHostContext() as common.UIAbilityContext);
        }
      }
    });
  }

  private refresh(): void {
    this.toneCount = ToneRepositoryService.count();
    this.toneBytes = ToneRepositoryService.totalBytes();
    this.logCount = LogService.getInstance().getEntryCount();
    this.logBytes = LogService.getInstance().getLogFileSize();
  }

  private readVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
      this.versionCode = info.versionCode;
    } catch (error) {
      Logger.exception(MODULE, '读取版本号失败', error as BusinessError);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildAppCard()
        this.buildStats()
        this.buildAppearance()
        this.buildBackupEntry()
        this.buildSupportEntry()
        this.buildActions()
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
    // 半模态用系统 bindSheet：blurStyle 是官方背景模糊，页面会透过磨砂玻璃，
    // 配合半透明 backgroundColor（取主背景色系）让弹层与页面同色；maskColor 轻微压暗，避免整屏发黑
    .bindSheet($$this.showAbout, this.buildAboutSheet(), {
      height: '64%',
      dragBar: false,
      showClose: false,
      maskColor: Palette.SHEET_MASK,
      backgroundColor: Palette.SHEET_TINT,
      blurStyle: BlurStyle.COMPONENT_THICK
    })
  }

  @Builder
  buildHeader() {
    Column({ space: 6 }) {
      Text(I18n.t('profile.title'))
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(I18n.t('profile.subtitle'))
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
          Text(I18n.t('app.name'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
          Text(I18n.f('profile.appTagline', [this.versionName]))
            .fontSize(11)
            .fontColor(Palette.TEXT_TERTIARY)
            .onClick((): void => {
              this.onVersionTap();
            })
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
      StatCell({
        cellLabel: I18n.t('profile.statTone'),
        cellValue: `${this.toneCount}`,
        cellUnit: I18n.t('profile.unitItems')
      })
      StatCell({ cellLabel: I18n.t('profile.statStorage'), cellValue: FormatUtils.bytes(this.toneBytes), cellUnit: '' })
      StatCell({
        cellLabel: I18n.t('profile.statLog'),
        cellValue: `${this.logCount}`,
        cellUnit: I18n.t('profile.unitLogs')
      })
    }
    .width('100%')
  }

  @Builder
  buildActions() {
    SectionTitle({ sectionText: I18n.t('profile.diagnostics') })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: I18n.t('profile.logCenter'),
        rowDesc: I18n.f('profile.logDesc', [`${this.logCount}`, FormatUtils.bytes(this.logBytes)]),
        rowIcon: $r('app.media.ic_log'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_LOG, 1);
        }
      })
      Divider()
        .color(Palette.FILL_FAINT)
        .margin({ left: 16, right: 16 })
      ActionRow({
        rowTitle: I18n.t('profile.feedback'),
        rowDesc: SupportInfo.FEEDBACK_ONLINE_ENABLED
          ? I18n.t('profile.feedbackDescOnline')
          : I18n.t('profile.feedbackDescOffline'),
        rowIcon: $r('app.media.ic_feedback'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_FEEDBACK, 1);
        }
      })
    }
  }

  @Builder
  buildBackupEntry() {
    SectionTitle({ sectionText: I18n.t('profile.data') })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: I18n.t('profile.backup'),
        rowDesc: I18n.t('profile.backupDesc'),
        rowIcon: $r('app.media.ic_upload'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_BACKUP, 1);
        }
      })
    }
  }

  @Builder
  buildAppearance() {
    SectionTitle({ sectionText: I18n.t('profile.appearance') })

    GlassCard({ cardPadding: 10 }) {
      Row({ space: 8 }) {
        ThemeChip({ chipLabel: I18n.t('profile.dark'), chipMode: ThemeMode.DARK })
        ThemeChip({ chipLabel: I18n.t('profile.light'), chipMode: ThemeMode.LIGHT })
        ThemeChip({ chipLabel: I18n.t('profile.system'), chipMode: ThemeMode.SYSTEM })
      }
      .width('100%')
    }
  }

  /** 支持机型入口摘要："支持开盒提示音机型待实测"为 0 时省略这一段 */
  private supportSummary(): string {
    const official: number = DeviceSupport.countOf(DeviceSupportLevel.OFFICIAL);
    const officialPart: string = official > 0 ? I18n.f('profile.supportSummaryOfficial', [`${official}`]) : '';
    return I18n.f('profile.supportSummary',
      [`${DeviceSupport.countOf(DeviceSupportLevel.VERIFIED)}`, officialPart]);
  }

  @Builder
  buildSupportEntry() {
    SectionTitle({ sectionText: I18n.t('profile.supportCompat') })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: I18n.t('profile.supportedModels'),
        rowDesc: this.supportSummary(),
        rowIcon: $r('app.media.ic_check'),
        onTap: (): void => {
          EventBus.emit(AppEvent.OPEN_DEVICE_SUPPORT, 1);
        }
      })
    }
  }

  @Builder
  buildLegal() {
    SectionTitle({ sectionText: I18n.t('profile.legal') })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: I18n.t('profile.about'),
        rowDesc: I18n.f('profile.aboutDesc', [this.versionName]),
        rowIcon: $r('app.media.ic_sparkle'),
        onTap: (): void => {
          this.showAbout = true;
        }
      })
    }
  }

  @Builder
  buildAboutSheet() {
    Stack({ alignContent: Alignment.Top }) {
      List({ space: 16 }) {
      // 与参考图一致：版本信息行压在磨砂标题栏下沿，静止时被糊成雾状光晕
      ListItem() {
        Row({ space: 6 }) {
          Image($r('app.media.ic_info'))
            .width(13)
            .height(13)
            .fillColor(Palette.TEXT_TERTIARY)
          Text(I18n.t('profile.version'))
            .fontSize(14)
            .fontColor(Palette.TEXT_TERTIARY)
          Text(I18n.f('profile.versionBuild', [this.versionName, `${this.versionCode}`]))
            .fontSize(14)
            .fontColor(Palette.TEXT_TERTIARY)
        }
        .width('100%')
        .height(ABOUT_HEADER_HEIGHT)
        .justifyContent(FlexAlign.Center)
      }

      ListItem() {
        Row({ space: 14 }) {
          Image($r('app.media.app_icon'))
            .width(56)
            .height(56)
            .borderRadius(15)
          Column({ space: 4 }) {
            Text(I18n.t('app.name'))
              .fontSize(19)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_PRIMARY)
            Text(I18n.f('profile.versionBuildLong', [this.versionName, `${this.versionCode}`]))
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      }

      ListItem() {
        Text(I18n.t('profile.aboutBody'))
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(19)
      }

      ListItem() {
        GlassCard({ cardPadding: 16 }) {
          SpecRow({
            specLabel: I18n.t('profile.modelCount'),
            specValue: I18n.f('profile.modelCountValue', [`${DeviceSupport.SUPPORTED.length}`]),
            showDivider: true
          })
          SpecRow({ specLabel: I18n.t('profile.feedbackEmail'), specValue: SupportInfo.EMAIL })
        }
      }

      // 参考设计：图标 + 标题在左，强调文字 + 箭头在右
      ListItem() {
        GlassCard({ cardPadding: 8 }) {
          AboutLinkRow({
            rowTitle: I18n.t('profile.changelog'),
            rowAction: I18n.t('profile.view'),
            rowIcon: $r('app.media.ic_log'),
            onTap: (): void => {
              this.showAbout = false;
              EventBus.emit(AppEvent.OPEN_CHANGELOG, 1);
            }
          })
          Divider()
            .color(Palette.FILL_FAINT)
            .margin({ left: 8, right: 8 })
          AboutLinkRow({
            rowTitle: I18n.t('profile.rate'),
            rowAction: I18n.t('profile.rateAction'),
            rowIcon: $r('app.media.ic_sparkle'),
            onTap: (): void => {
              this.openAppGallery();
            }
          })
          Divider()
            .color(Palette.FILL_FAINT)
            .margin({ left: 8, right: 8 })
          AboutLinkRow({
            rowTitle: I18n.t('profile.donate'),
            rowAction: I18n.t('profile.donateAction'),
            rowIcon: $r('app.media.ic_feedback'),
            onTap: (): void => {
              this.donateDialog.open();
            }
          })
          Divider()
            .color(Palette.FILL_FAINT)
            .margin({ left: 8, right: 8 })
          AboutLinkRow({
            rowTitle: I18n.t('profile.privacy'),
            rowAction: I18n.t('profile.view'),
            rowIcon: $r('app.media.ic_info'),
            onTap: (): void => {
              this.openPrivacy();
            }
          })
        }
      }

      ListItem() {
        SectionTitle({ sectionText: I18n.t('profile.encoding') })
      }

      ListItem() {
        GlassCard({ cardPadding: 16 }) {
          SpecRow({
            specLabel: I18n.t('profile.sampleRate'),
            specValue: `${ToneSpec.SAMPLE_RATE} Hz`,
            showDivider: true
          })
          SpecRow({
            specLabel: I18n.t('profile.bitDepth'),
            specValue: I18n.t('profile.bitDepthValue'),
            showDivider: true
          })
          SpecRow({
            specLabel: I18n.t('profile.channels'),
            specValue: I18n.t('profile.channelsValue'),
            showDivider: true
          })
          SpecRow({
            specLabel: I18n.t('profile.header'),
            specValue: I18n.t('profile.headerValue'),
            showDivider: true
          })
          SpecRow({
            specLabel: I18n.t('profile.secondSize'),
            specValue: I18n.f('tone.byteCount', [`${ToneSpec.BYTES_PER_SECOND}`]),
            showDivider: true
          })
          SpecRow({
            specLabel: I18n.t('profile.durationLimit'),
            specValue: I18n.f('profile.durationLimitValue',
              [`${ToneSpec.MAX_SECONDS}`, `${ToneSpec.MAX_BYTES}`])
          })

          Column({ space: 8 }) {
            Text(I18n.t('profile.why16700'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.ACCENT_TEXT)
            Text(I18n.t('profile.why16700Body'))
              .fontSize(11)
              .fontColor(Palette.TEXT_SECONDARY)
              .lineHeight(18)
            Text(I18n.t('profile.sizeRuleBody'))
              .fontSize(11)
              .fontColor(Palette.TEXT_SECONDARY)
              .lineHeight(18)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 14 })
        }
      }

      ListItem() {
        Text(I18n.t('profile.disclaimer'))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .lineHeight(17)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

        ListItem() {
          Row()
            .width('100%')
            .height(24)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 磨砂标题栏：只保留实时背景模糊（超厚材质），不加底色。
      // 参考图的顶栏没有可见色带，磨砂感只来自内容滚过时的模糊光晕
      Row() {
        Text(I18n.t('profile.aboutTitle'))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        Stack() {
          Image($r('app.media.ic_close'))
            .width(16)
            .height(16)
            .fillColor(Palette.TEXT_PRIMARY)
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Palette.GLASS_BTN)
        .onClick(() => {
          this.showAbout = false;
        })
      }
      .width('100%')
      .height(ABOUT_HEADER_HEIGHT)
      .padding({ left: 24, right: 20 })
      .backdropBlur(BlurStyle.COMPONENT_ULTRA_THICK)
    }
    .width('100%')
    .height('100%')
  }

  /** 跳转应用市场详情页；链接未配置时给出提示 */
  private openAppGallery(): void {
    const url: string = SupportInfo.APP_GALLERY_URL;
    if (url.length === 0) {
      this.toast(I18n.t('profile.galleryMissing'));
      return;
    }
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(url).catch((error: BusinessError) => {
      Logger.warn(MODULE, `打开应用市场失败 code=${error.code}`);
      this.toast(I18n.t('profile.galleryFailed'));
    });
  }

  private openPrivacy(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean) => {
      if (!opened) {
        this.toast(I18n.t('profile.privacyUnavailable'));
      }
    });
  }

  @Builder
  buildAbout() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_info'))
          .width(9)
          .height(9)
          .fillColor(Palette.TEXT_TERTIARY)
        Text(I18n.t('profile.writeInfo'))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .lineHeight(16)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(I18n.t('profile.disclaimer'))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .lineHeight(17)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 8 })
  }
}

/** 统计卡片：用 @Prop 保证数值变化时刷新 */
@Component
struct StatCell {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
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
  @StorageProp('themeEpoch') themeEpoch: number = 0;
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

/** 外观选项：深色 / 浅色 / 跟随系统 */
@Component
struct ThemeChip {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop chipLabel: string = '';
  @Prop chipMode: ThemeMode = ThemeMode.DARK;

  build() {
    // 选项胶囊：选中实心强调色，与排序、筛选、内置音效一致
    Row() {
      Text(this.chipLabel)
        .fontSize(12)
        .fontWeight(ThemeService.getMode() === this.chipMode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(ThemeService.getMode() === this.chipMode ? Palette.ON_ACCENT : Palette.TEXT_SECONDARY)
    }
    .layoutWeight(1)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .borderRadius(19)
    .backgroundColor(ThemeService.getMode() === this.chipMode ? Palette.ACCENT : Palette.CHIP_IDLE)
    .border({
      width: 1,
      color: ThemeService.getMode() === this.chipMode ? Palette.ACCENT : Palette.CHIP_IDLE_STROKE
    })
    .onClick(() => {
      ThemeService.setMode(this.chipMode);
    })
  }
}

/** 关于页动作行：左图标 + 标题，右侧强调文字 + 箭头 */
@Component
struct AboutLinkRow {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop rowTitle: string = '';
  @Prop rowAction: string = '';
  rowIcon: Resource = $r('app.media.ic_info');
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      Image(this.rowIcon)
        .width(17)
        .height(17)
        .fillColor(Palette.TEXT_SECONDARY)
      Text(this.rowTitle)
        .fontSize(14)
        .fontColor(Palette.TEXT_PRIMARY)
        .layoutWeight(1)
      Text(this.rowAction)
        .fontSize(12)
        .fontColor(Palette.ACCENT_TEXT)
      Image($r('app.media.ic_chevron_right'))
        .width(12)
        .height(12)
        .fillColor(Palette.ACCENT_TEXT)
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 捐赠收款码弹窗：展示微信 / 支付宝二维码，纯自愿支持 */
@CustomDialog
struct DonateQrDialog {
  controller?: CustomDialogController;

  build() {
    Column({ space: 14 }) {
      Image($r('app.media.donate_qr'))
        .width('100%')
        .objectFit(ImageFit.Contain)
        .borderRadius(16)
      Text(I18n.t('profile.donateHint'))
        .fontSize(13)
        .fontColor(Palette.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
        .width('100%')
      Button(I18n.t('common.close'))
        .fontSize(14)
        .fontColor(Palette.TEXT_PRIMARY)
        .backgroundColor(Palette.FILL_SOFT)
        .borderRadius(12)
        .width('100%')
        .height(42)
        .onClick(() => {
          this.controller?.close();
        })
    }
    .width('100%')
    .padding(16)
    // 弹窗必须用不透明底色：卡片色是 8% 白的玻璃拟态，放在这里会让背后的列表透出来
    .backgroundColor(Palette.BG_END)
    .border({ width: 1, color: Palette.STROKE })
    .borderRadius(22)
  }
}
