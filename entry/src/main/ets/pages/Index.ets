import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { Palette } from '../common/constants/ThemeConstants';
import { AppEvent, EventBus, SimpleHandler, TextHandler } from '../common/utils/EventBus';
import { Logger } from '../common/utils/Logger';
import { AppBackdrop } from '../components/AppBackdrop';
import { GhostButton } from '../components/GhostButton';
import { PrimaryButton } from '../components/PrimaryButton';
import { BluetoothService } from '../services/BluetoothService';
import { DemoService } from '../services/DemoService';
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
  @State demoActive: boolean = false;
  @State showDemoGuide: boolean = false;
  private tabsController: HdsTabsController = new HdsTabsController();
  private logHandler: SimpleHandler | undefined = undefined;
  private feedbackHandler: SimpleHandler | undefined = undefined;
  private supportHandler: SimpleHandler | undefined = undefined;
  private changelogHandler: SimpleHandler | undefined = undefined;
  private busyHandler: TextHandler | undefined = undefined;
  private privacyHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    this.measureInsets();
    this.demoActive = DemoService.isActive();
    this.showDemoGuide = DemoService.shouldShowGuide();
    this.logHandler = (): void => {
      this.showLog = true;
    };
    EventBus.on(AppEvent.OPEN_LOG, this.logHandler);
    this.feedbackHandler = (): void => {
      this.feedbackStep = 0;
      this.showFeedback = true;
    };
    EventBus.on(AppEvent.OPEN_FEEDBACK, this.feedbackHandler);
    this.supportHandler = (): void => {
      this.showDeviceSupport = true;
    };
    EventBus.on(AppEvent.OPEN_DEVICE_SUPPORT, this.supportHandler);
    this.changelogHandler = (): void => {
      this.showChangelog = true;
    };
    EventBus.on(AppEvent.OPEN_CHANGELOG, this.changelogHandler);
    this.busyHandler = (text: string): void => {
      this.busyText = text;
    };
    EventBus.onText(AppEvent.BUSY_CHANGED, this.busyHandler);
    // 托管弹窗可能在页面构建之后才被同意，届时补读演示状态
    this.privacyHandler = (): void => {
      this.demoActive = DemoService.isActive();
      this.showDemoGuide = DemoService.shouldShowGuide();
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

  /** 侧滑返回：日志/反馈都是 Stack 里的浮层，没有路由可退，先关浮层而不是退出应用 */
  onBackPress(): boolean {
    // 首次引导必须明确选择，避免误触侧滑跳过
    if (this.showDemoGuide) {
      return true;
    }
    // 全屏遮罩期间手势也吃掉，避免把正在进行的工作连同应用一起退掉
    if (this.busyText.length > 0) {
      return true;
    }
    if (this.showChangelog) {
      this.showChangelog = false;
      return true;
    }
    if (this.showFeedback) {
      if (this.feedbackStep !== 0) {
        this.feedbackStep = 0;
      } else {
        this.showFeedback = false;
      }
      return true;
    }
    if (this.showLog) {
      this.showLog = false;
      return true;
    }
    if (this.showDeviceSupport) {
      this.showDeviceSupport = false;
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

      Column() {
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            DevicePage()
          }
          .tabBar(this.tabItem(0, '设备', $r('app.media.ic_tab_device')))

          TabContent() {
            TonePage()
          }
          .tabBar(this.tabItem(1, '音效', $r('app.media.ic_tab_tone')))

          TabContent() {
            LibraryPage()
          }
          .tabBar(this.tabItem(2, '音效库', $r('app.media.ic_tab_library')))

          TabContent() {
            ProfilePage()
          }
          .tabBar(this.tabItem(3, '我的', $r('app.media.ic_tab_mine')))
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

      if (this.showLog) {
        LogPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.showLog = false;
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
            this.showFeedback = false;
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
            this.showDeviceSupport = false;
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
            this.showChangelog = false;
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

      if (this.demoActive) {
        this.buildDemoBadge()
      }

      if (this.showDemoGuide) {
        this.buildDemoGuide()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG_TOP)
  }

  private startDemo(): void {
    DemoService.markGuideSeen();
    DemoService.setActive(true);
    this.demoActive = true;
    this.showDemoGuide = false;
    BluetoothService.refresh().catch((error: BusinessError) => {
      Logger.warn(MODULE, '刷新演示设备状态失败');
    });
  }

  private skipDemoGuide(): void {
    DemoService.markGuideSeen();
    this.showDemoGuide = false;
  }

  private confirmExitDemo(): void {
    this.getUIContext().showAlertDialog({
      title: '退出演示模式',
      message: '退出后将恢复真实蓝牙设备状态，模拟耳机会消失。',
      primaryButton: {
        value: '继续演示',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Palette.DANGER,
        action: (): void => {
          DemoService.setActive(false);
          this.demoActive = false;
          BluetoothService.refresh().catch((error: BusinessError) => {
            Logger.warn(MODULE, '刷新设备状态失败');
          });
        }
      }
    });
  }

  /** 演示模式常驻小标：让审核员和用户始终清楚当前是模拟设备 */
  @Builder
  buildDemoBadge() {
    Column() {
      Row({ space: 8 }) {
        Text('演示模式 · 模拟耳机')
          .fontSize(11)
          .fontColor(Palette.ACCENT)
        Text('退出')
          .fontSize(11)
          .fontColor(Palette.TEXT_SECONDARY)
      }
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(999)
      .backgroundColor('rgba(78, 216, 255, 0.14)')
      .border({ width: 1, color: 'rgba(78, 216, 255, 0.3)' })
      .onClick(() => {
        this.confirmExitDemo();
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.End)
    .padding({ bottom: this.naviIndicatorHeight + 100 })
    .hitTestBehavior(HitTestMode.Transparent)
    .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
  }

  @Builder
  buildDemoGuide() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(5, 8, 14, 0.86)')
        .onClick(() => {
        })

      Column({ space: 14 }) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_sparkle'))
            .width(18)
            .height(18)
            .fillColor(Palette.ACCENT)
          Text('没有耳机也能先体验')
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT_PRIMARY)
        }
        .width('100%')

        Text('开启演示模式后会显示一台模拟的演示耳机：音效制作、试听、生成和导出都能照常使用，' +
          '不会申请蓝牙权限，也不会写入真实设备。随时可以在页面底部退出演示。')
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(19)
          .width('100%')

        Row({ space: 10 }) {
          GhostButton({
            ghostLabel: '直接使用',
            onTap: (): void => {
              this.skipDemoGuide();
            }
          })
            .layoutWeight(1)
          PrimaryButton({
            btnLabel: '开始演示',
            onTap: (): void => {
              this.startDemo();
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 28 })
      .borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor(Palette.BG_END)
      .border({ width: 1, color: Palette.STROKE })
    }
    .width('100%')
    .height('100%')
  }


  @Builder
  tabItem(index: number, tabLabel: string, tabIcon: Resource) {
    Column({ space: 3 }) {
      Image(tabIcon)
        .width(20)
        .height(20)
        .fillColor(this.activeIndex === index ? Palette.ACCENT : Palette.TEXT_TERTIARY)
        .scale({
          x: this.activeIndex === index ? 1.08 : 1.0,
          y: this.activeIndex === index ? 1.08 : 1.0
        })
        .animation({ duration: 120, curve: Curve.EaseOut })

      Text(tabLabel)
        .fontSize(10)
        .fontWeight(this.activeIndex === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeIndex === index ? Palette.ACCENT : Palette.TEXT_TERTIARY)
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
  }
}
