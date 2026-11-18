import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';
import { AppEvent, EventBus, SimpleHandler, TextHandler } from '../common/utils/EventBus';
import { Logger } from '../common/utils/Logger';
import { AppBackdrop } from '../components/AppBackdrop';
import { GhostButton } from '../components/GhostButton';
import { PrimaryButton } from '../components/PrimaryButton';
import { BluetoothService } from '../services/BluetoothService';
import { AppBootstrap } from '../services/AppBootstrap';
import { PrivacyConsentService } from '../services/PrivacyConsentService';
import { PrivacyLinkService } from '../services/PrivacyLinkService';
import { DevicePage } from './main/DevicePage';
import { LibraryPage } from './main/LibraryPage';
import { TonePage } from './main/TonePage';
import { FeedbackPage } from './settings/FeedbackPage';
import { LogPage } from './settings/LogPage';
import { ProfilePage } from './settings/ProfilePage';
import { SupportedDevicesPage } from './settings/SupportedDevicesPage';
import { ChangelogPage } from './settings/ChangelogPage';

const MODULE: string = 'Index';

/**
 * 主框架
 *
 * 底部导航使用官方 HdsTabs 的沉浸光感悬浮底栏（HDS 6.1.0 / API 23 起提供）：
 * barOverlap(true) 让页签栏悬浮于内容之上，
 * 背景用 barBackgroundColor + barBackgroundEffect 自行指定深色玻璃，
 * 避免 systemMaterialEffect 的 ADAPTIVE 材质跟随系统浅色策略把胶囊刷白。
 *
 * 参考：沉浸光感悬浮底栏（bpta-spatiality-immersive）
 */
@Entry
@Component
struct Index {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State activeIndex: number = 0;
  @State topInset: number = 0;
  @State naviIndicatorHeight: number = 0;
  @State showLog: boolean = false;
  @State showFeedback: boolean = false;
  @State showDeviceSupport: boolean = false;
  @State showChangelog: boolean = false;
  @State feedbackStep: number = 0;
  @State busyText: string = '';
  @State privacyReady: boolean = false;
  private tabsController: HdsTabsController = new HdsTabsController();
  private logHandler: SimpleHandler | undefined = undefined;
  private feedbackHandler: SimpleHandler | undefined = undefined;
  private supportHandler: SimpleHandler | undefined = undefined;
  private changelogHandler: SimpleHandler | undefined = undefined;
  private busyHandler: TextHandler | undefined = undefined;
  private privacyHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    this.measureInsets();
    this.privacyReady = AppBootstrap.isInitialized();
    this.logHandler = (): void => {
      this.animateOverlay((): void => {
        this.showLog = true;
      });
    };
    EventBus.on(AppEvent.OPEN_LOG, this.logHandler);
    this.feedbackHandler = (): void => {
      this.animateOverlay((): void => {
        this.feedbackStep = 0;
        this.showFeedback = true;
      });
    };
    EventBus.on(AppEvent.OPEN_FEEDBACK, this.feedbackHandler);
    this.supportHandler = (): void => {
      this.animateOverlay((): void => {
        this.showDeviceSupport = true;
      });
    };
    EventBus.on(AppEvent.OPEN_DEVICE_SUPPORT, this.supportHandler);
    this.changelogHandler = (): void => {
      this.animateOverlay((): void => {
        this.showChangelog = true;
      });
    };
    EventBus.on(AppEvent.OPEN_CHANGELOG, this.changelogHandler);
    this.busyHandler = (text: string): void => {
      this.busyText = text;
    };
    EventBus.onText(AppEvent.BUSY_CHANGED, this.busyHandler);
    // 托管弹窗可能在页面构建之后才被同意
    this.privacyHandler = (): void => {
      this.privacyReady = true;
    };
    EventBus.on(AppEvent.PRIVACY_READY, this.privacyHandler);
  }

  aboutToDisappear(): void {
    if (this.logHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_LOG);
      this.logHandler = undefined;
    }
    if (this.feedbackHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_FEEDBACK);
      this.feedbackHandler = undefined;
    }
    if (this.supportHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_DEVICE_SUPPORT);
      this.supportHandler = undefined;
    }
    if (this.changelogHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_CHANGELOG);
      this.changelogHandler = undefined;
    }
    if (this.busyHandler !== undefined) {
      EventBus.off(AppEvent.BUSY_CHANGED);
      this.busyHandler = undefined;
    }
    if (this.privacyHandler !== undefined) {
      EventBus.off(AppEvent.PRIVACY_READY);
      this.privacyHandler = undefined;
    }
  }

  /** 显式动画上下文：条件渲染的 transition 只有在 animateTo 里改状态才会播放位移 */
  private animateOverlay(update: () => void): void {
    this.getUIContext().animateTo({ duration: 280, curve: Curve.Friction }, update);
  }

  /** 侧滑返回：日志/反馈都是 Stack 里的浮层，没有路由可退，先关浮层而不是退出应用 */
  onBackPress(): boolean {
    // 未同意隐私声明时没有业务页面可退，直接允许系统退出
    if (!this.privacyReady) {
      return false;
    }
    // 全屏遮罩期间手势也吃掉，避免把正在进行的工作连同应用一起退掉
    if (this.busyText.length > 0) {
      return true;
    }
    if (this.showChangelog) {
      this.animateOverlay((): void => {
        this.showChangelog = false;
      });
      return true;
    }
    if (this.showFeedback) {
      if (this.feedbackStep !== 0) {
        this.feedbackStep = 0;
      } else {
        this.animateOverlay((): void => {
          this.showFeedback = false;
        });
      }
      return true;
    }
    if (this.showLog) {
      this.animateOverlay((): void => {
        this.showLog = false;
      });
      return true;
    }
    if (this.showDeviceSupport) {
      this.animateOverlay((): void => {
        this.showDeviceSupport = false;
      });
      return true;
    }
    return false;
  }

  /** 读取状态栏与底部导航条高度，避免内容被遮挡 */
  private async measureInsets(): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow: window.Window = await window.getLastWindow(context);
      const systemArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = this.getUIContext().px2vp(systemArea.topRect.height);
      this.naviIndicatorHeight = this.getUIContext().px2vp(systemArea.bottomRect.height);
      Logger.info(MODULE, `安全区 top=${this.topInset} navIndicator=${this.naviIndicatorHeight}`);
    } catch (error) {
      Logger.exception(MODULE, '读取安全区失败', error as BusinessError);
      this.topInset = 38;
      this.naviIndicatorHeight = 0;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackdrop()

      if (this.privacyReady) {
        Column() {
          HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            DevicePage()
          }
          .tabBar(this.tabItem(0, I18n.t('tab.device'), $r('app.media.ic_tab_device')))

          TabContent() {
            TonePage()
          }
          .tabBar(this.tabItem(1, I18n.t('tab.tone'), $r('app.media.ic_tab_tone')))

          TabContent() {
            LibraryPage()
          }
          .tabBar(this.tabItem(2, I18n.t('tab.library'), $r('app.media.ic_tab_library')))

          TabContent() {
            ProfilePage()
          }
          .tabBar(this.tabItem(3, I18n.t('tab.profile'), $r('app.media.ic_tab_mine')))
        }
        .scrollable(false)
        .barOverlap(true)
        .vertical(false)
        .barPosition(BarPosition.End)
        .onSelected((index: number) => {
          // onSelected 在切换动画开始时回调；onChange 要等动画结束，
          // 只挂 onChange 会让图标亮起比点击慢半拍
          this.activeIndex = index;
        })
        .onChange((index: number) => {
          this.activeIndex = index;
          // 切回设备页时补拉一次：星闪连接变化没有系统回调
          if (index === 0) {
            BluetoothService.refresh();
          }
        })
        .animationDuration(220)
        .onAttach(() => {
          try {
            this.tabsController.preloadItems([0, 1, 2, 3]);
          } catch (error) {
            Logger.exception(MODULE, '预加载页签失败', error as BusinessError);
          }
        })
        .barFloatingStyle({
          // 与设计稿一致：胶囊浮起、宽度约为屏宽八成、贴着手势条上沿留出一段呼吸距离
          barWidth: { smallWidth: 288, mediumWidth: 320, largeWidth: 360 },
          barBottomMargin: this.naviIndicatorHeight + 30,
          adaptToHandedness: true,
          // 底部渐隐遮罩改为全透明：默认遮罩在浅色策略下是白色，会形成一层泛白光雾
          gradientMask: { maskColor: 'rgba(7, 10, 16, 0.0)' },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .barHeight(58)
        .width('100%')
        .height('100%')
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.topInset })
      } else {
        this.buildPrivacyGate()
      }

      if (this.showLog) {
        LogPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.showLog = false;
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.showFeedback) {
        FeedbackPage({
          topInset: this.topInset,
          step: $feedbackStep,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.showFeedback = false;
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.showDeviceSupport) {
        SupportedDevicesPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.showDeviceSupport = false;
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.showChangelog) {
        ChangelogPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.showChangelog = false;
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      // 全屏遮罩放在所有页面与浮层之后，才能连状态栏一起压暗；
      // 只盖页面内容的话，系统选择器弹出时状态栏会留一条亮边
      if (this.busyText.length > 0) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color(Palette.ACCENT)
          Text(this.busyText)
            .fontSize(12)
            .fontColor(Palette.TEXT_SECONDARY)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(5, 8, 14, 0.62)')
        .onClick(() => {
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG_TOP)
  }

  @Builder
  buildPrivacyGate() {
    Column({ space: 16 }) {
      Image($r('app.media.app_icon'))
        .width(76)
        .height(76)
        .borderRadius(20)

      Column({ space: 8 }) {
        Text(I18n.t('app.name'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.t('privacy.gateBody'))
          .fontSize(13)
          .fontColor(Palette.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
      }
      .width('100%')

      Text(I18n.t('privacy.viewStatement'))
        .fontSize(12)
        .fontColor(Palette.ACCENT_TEXT)
        .onClick(() => {
          this.openPrivacyStatement();
        })

      PrimaryButton({
        btnLabel: I18n.t('privacy.consent'),
        btnEnabled: true,
        btnLoading: false,
        onTap: (): void => {
          this.requestPrivacyConsent();
        }
      })
        .width('100%')
        .margin({ top: 6 })

      GhostButton({
        ghostLabel: I18n.t('privacy.exit'),
        onTap: (): void => {
          this.exitApp();
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: 32,
      right: 32,
      top: this.topInset,
      bottom: this.naviIndicatorHeight + 24
    })
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private openPrivacyStatement(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean) => {
      if (!opened) {
        this.toast(I18n.t('profile.privacyUnavailable'));
      }
    });
  }

  private async requestPrivacyConsent(): Promise<void> {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const agreed: boolean = await PrivacyConsentService.requestConsent(context);
      if (!agreed) {
        this.toast(I18n.t('privacy.consentRequired'));
      }
    } catch (error) {
      Logger.exception(MODULE, '拉起系统隐私弹窗失败', error as BusinessError);
      this.toast(I18n.t('privacy.consentFailed'));
    }
  }

  private exitApp(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.terminateSelf().catch((error: BusinessError) => {
      Logger.warn(MODULE, `退出应用失败 code=${error.code}`);
    });
  }

  @Builder
  tabItem(index: number, tabLabel: string, tabIcon: Resource) {
    Column({ space: 3 }) {
      Image(tabIcon)
        .width(20)
        .height(20)
        .fillColor(this.activeIndex === index ? Palette.ACCENT_TEXT : Palette.TEXT_TERTIARY)
        .scale({
          x: this.activeIndex === index ? 1.08 : 1.0,
          y: this.activeIndex === index ? 1.08 : 1.0
        })
        .animation({ duration: 120, curve: Curve.EaseOut })

      Text(tabLabel)
        .fontSize(10)
        .fontWeight(this.activeIndex === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeIndex === index ? Palette.ACCENT_TEXT : Palette.TEXT_TERTIARY)
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
  }
}
