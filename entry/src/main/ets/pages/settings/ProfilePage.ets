import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DeviceSupport, DeviceSupportLevel, SupportInfo, ToneSpec } from '../../common/constants/AppConstants';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';
import { SpecRow } from '../../components/SpecRow';
import { LogService } from '../../services/LogService';
import { PrivacyLinkService } from '../../services/PrivacyLinkService';
import { ThemeMode, ThemeService } from '../../services/ThemeService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'ProfilePage';
const ABOUT_HEADER_HEIGHT: number = 64;

@Component
export struct ProfilePage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State versionName: string = '1.0.0';
  @State versionCode: number = 0;
  @State toneCount: number = 0;
  @State toneBytes: number = 0;
  @State logCount: number = 0;
  @State logBytes: number = 0;
  @State privacyUrl: string = '';
  @State showAbout: boolean = false;
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
      Text('我的')
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('应用信息、支持机型与诊断工具')
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
        .color(Palette.FILL_FAINT)
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
    }
  }

  @Builder
  buildAppearance() {
    SectionTitle({ sectionText: '外观设置' })

    GlassCard({ cardPadding: 10 }) {
      Row({ space: 8 }) {
        ThemeChip({ chipLabel: '深色', chipMode: ThemeMode.DARK })
        ThemeChip({ chipLabel: '浅色', chipMode: ThemeMode.LIGHT })
        ThemeChip({ chipLabel: '跟随系统', chipMode: ThemeMode.SYSTEM })
      }
      .width('100%')
    }
  }

  /** 支持机型入口摘要："官方支持待实测"为 0 时省略这一段 */
  private supportSummary(): string {
    const official: number = DeviceSupport.countOf(DeviceSupportLevel.OFFICIAL);
    const officialPart: string = official > 0 ? ` · ${official} 款官方支持待实测` : '';
    return `${DeviceSupport.countOf(DeviceSupportLevel.VERIFIED)} 款实测${officialPart} · 查看列表`;
  }

  @Builder
  buildSupportEntry() {
    SectionTitle({ sectionText: '支持与兼容' })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: '支持机型',
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
    SectionTitle({ sectionText: '关于与协议' })

    GlassCard({ cardPadding: 4 }) {
      ActionRow({
        rowTitle: '关于盒音工坊',
        rowDesc: `v${this.versionName} · 产品介绍与版本信息`,
        rowIcon: $r('app.media.ic_sparkle'),
        onTap: (): void => {
          this.showAbout = true;
        }
      })
      // 托管链接由 AGC 下发；本地调试或非市场安装时取不到，直接隐藏入口
      if (this.privacyUrl.length > 0) {
        Divider()
          .color(Palette.FILL_FAINT)
          .margin({ left: 16, right: 16 })
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
          Text('版本')
            .fontSize(14)
            .fontColor(Palette.TEXT_TERTIARY)
          Text(`v${this.versionName}（Build ${this.versionCode}）`)
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
            Text('盒音工坊')
              .fontSize(19)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_PRIMARY)
            Text(`版本 v${this.versionName}（Build ${this.versionCode}）`)
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      }

      ListItem() {
        Text('把喜欢的旋律做成华为耳机充电盒的开盒提示音。音效在本机生成并直接写入充电盒，不上传任何音频。')
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(19)
      }

      ListItem() {
        GlassCard({ cardPadding: 16 }) {
          SpecRow({
            specLabel: '收录机型',
            specValue: `${DeviceSupport.SUPPORTED.length} 款 · 持续增加`,
            showDivider: true
          })
          SpecRow({ specLabel: '反馈邮箱', specValue: SupportInfo.EMAIL })
        }
      }

      // 参考设计：图标 + 标题在左，强调文字 + 箭头在右
      ListItem() {
        GlassCard({ cardPadding: 8 }) {
          AboutLinkRow({
            rowTitle: '更新日志',
            rowAction: '查看',
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
            rowTitle: '五星好评',
            rowAction: '点击鼓励',
            rowIcon: $r('app.media.ic_sparkle'),
            onTap: (): void => {
              this.openAppGallery();
            }
          })
          Divider()
            .color(Palette.FILL_FAINT)
            .margin({ left: 8, right: 8 })
          AboutLinkRow({
            rowTitle: '捐赠支持',
            rowAction: '点击投喂',
            rowIcon: $r('app.media.ic_feedback'),
            onTap: (): void => {
              // 捐赠图片暂未提供：入口先保持无响应，后续在同一点击事件里打开图片
            }
          })
        }
      }

      ListItem() {
        SectionTitle({ sectionText: '编码规则' })
      }

      ListItem() {
        GlassCard({ cardPadding: 16 }) {
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

      ListItem() {
        Column({ space: 10 }) {
          Text('本应用为个人开发作品，与华为无关；华为、FreeBuds、FreeClip 等商标归华为技术有限公司所有。')
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
            .lineHeight(16)
          if (this.privacyUrl.length > 0) {
            Text('查看隐私政策')
              .fontSize(12)
              .fontColor(Palette.ACCENT)
              .onClick(() => {
                this.openPrivacy();
              })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
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
        Text('关于')
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
      this.toast('应用市场链接暂未配置');
      return;
    }
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(url).catch((error: BusinessError) => {
      Logger.warn(MODULE, `打开应用市场失败 code=${error.code}`);
      this.toast('无法打开应用市场');
    });
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
        .fontColor(Palette.TEXT_FAINT)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4 })
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
    Row({ space: 5 }) {
      if (ThemeService.getMode() === this.chipMode) {
        Circle()
          .width(5)
          .height(5)
          .fill(Palette.ACCENT)
      }
      Text(this.chipLabel)
        .fontSize(12)
        .fontWeight(ThemeService.getMode() === this.chipMode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(ThemeService.getMode() === this.chipMode ? Palette.ACCENT : Palette.TEXT_SECONDARY)
    }
    .layoutWeight(1)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(ThemeService.getMode() === this.chipMode ? Palette.ACCENT_SOFT : Palette.BG_INPUT)
    .border({
      width: 1,
      color: ThemeService.getMode() === this.chipMode ? Palette.ACCENT_LINE : Palette.STROKE_SOFT
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
        .fontColor(Palette.ACCENT)
      Image($r('app.media.ic_chevron_right'))
        .width(12)
        .height(12)
        .fillColor(Palette.ACCENT)
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      this.onTap();
    })
  }
}
