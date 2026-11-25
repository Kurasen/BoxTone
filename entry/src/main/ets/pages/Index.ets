import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';
import { AppEvent, BusyState, EventBus, SimpleHandler, TextHandler } from '../common/utils/EventBus';
import { Logger } from '../common/utils/Logger';
import { AppBackdrop } from '../components/AppBackdrop';
import { BluetoothService } from '../services/BluetoothService';
import { ImportControl } from '../services/audio/ImportControl';
import { PrivacyConsentService } from '../services/PrivacyConsentService';
import { PrivacyLinkService } from '../services/PrivacyLinkService';
import { ThemeService } from '../services/ThemeService';
import { DevicePage } from './main/DevicePage';
import { LibraryPage } from './main/LibraryPage';
import { TonePage } from './main/TonePage';
import { FeedbackPage } from './settings/FeedbackPage';
import { LogPage } from './settings/LogPage';
import { ProfilePage } from './settings/ProfilePage';
import { SupportedDevicesPage } from './settings/SupportedDevicesPage';
import { ChangelogPage } from './settings/ChangelogPage';
import { BackupPage } from './settings/BackupPage';

const MODULE: string = 'Index';
/**
 * 启动衔接遮罩的三段时长，参照元宝的启动录屏逐帧实测：
 * - 停留：启动页窗口放大完成后，在启动页底色上稳稳停一会儿（元宝约 500ms）。
 *   太短的话换色会和系统的窗口放大动画叠在一起，用户看不出「先浅后深」
 * - 换色：只换底色、图标不动，浅 → 深一气呵成（元宝约 250ms）
 * - 图标退场 → 露出首页：见下方 LAUNCH_VEIL_ICON_MS / LAUNCH_VEIL_FADE_MS
 */
const LAUNCH_VEIL_HOLD_MS: number = 200;
const LAUNCH_VEIL_COLOR_MS: number = 250;
/**
 * 图标退场：换色完成后，图标在深色底上轻微缩小并淡出，背景保持不动。
 * 录屏实测：图标和首页内容在同一段 50ms 里一起切换时，首页正中的亮色卡片会直接
 * 「顶掉」图标，看起来就是图标闪一下。先让图标自己走掉，再露出首页
 */
const LAUNCH_VEIL_ICON_MS: number = 200;
const LAUNCH_VEIL_ICON_END_SCALE: number = 0.92;
/** 露出首页：此时遮罩只剩一片与首页同色的底，淡出不会再有图标残影，可以柔和一点 */
const LAUNCH_VEIL_FADE_MS: number = 140;
/**
 * 系统启动页图标按图片原始像素居中显示（不按 vp 缩放），
 * 遮罩里的图标要同样大小才能和启动页对上；须与 media/startIcon.png 的尺寸一致
 */
const START_ICON_PX: string = '216px';
/** startIcon.png 的圆角半径（边长的 22.5%），描边要沿图标圆角走 */
const START_ICON_RADIUS_PX: string = '49px';
/**
 * 图标是深色圆角方块：底色渐变到纯黑时方块会「融进」背景，只剩中间的亮条，
 * 看起来图标突然缩了一圈。换色时同步给图标描一圈淡边，深色底上也能保住轮廓
 */
const START_ICON_STROKE_DARK: string = 'rgba(255, 255, 255, 0.16)';
const START_ICON_STROKE_NONE: string = 'rgba(255, 255, 255, 0)';

/**
 * 主框架
 *
 * 底部导航使用官方 HdsTabs 的沉浸光感悬浮底栏（HDS 6.1.0 / API 23 起提供）：
 * barOverlap(true) 让页签栏悬浮于内容之上。
 *
 * 沉浸光感材质按官方要求先做能力检测（getSystemMaterialTypes）：
 * materialType 固定 ADAPTIVE 由系统自适应，materialLevel 视设备是否支持
 * IMMERSIVE 在 GENTLE / SMOOTH 之间选择，避免低性能设备硬上重材质导致卡顿/崩溃。
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
  /** 沉浸光感材质等级：启动时按设备能力检测结果动态确定，默认取最保守的 SMOOTH */
  @State tabMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
  /** 当前打开的全屏浮层：'' | log | feedback | support | changelog | backup */
  @State activeOverlay: string = '';
  @State feedbackStep: number = 0;
  @State busyText: string = '';
  @State busyDetail: string = '';
  /** -1 表示不确定进度 */
  @State busyProgress: number = -1;
  @State busyCancellable: boolean = false;
  /**
   * 隐私征询失败（该征询但征询不了）：叠一层重试页，而不是直接退出应用。
   * 正常等待弹窗时不叠任何东西：首页照常渲染在下面，系统弹窗以半屏浮层盖上来。
   */
  @State privacyBlocked: boolean = false;
  /**
   * 启动衔接遮罩：系统启动页按系统深浅色绘制，应用外观与之不一致时（如系统浅色、应用手动选深色），
   * 首帧先铺一层与启动页同色的底再淡出，避免从启动页直接跳色。外观一致时不出现。
   */
  @State launchVeil: boolean = ThemeService.takeLaunchVeil();
  /** 遮罩透明度：首帧必须是 1（不透明），由 animateTo 渐变到 0 后再移除节点 */
  @State launchVeilOpacity: number = 1;
  /** 遮罩图标描边：随底色一起渐变，只有目标外观是深色时才描 */
  @State launchVeilIconStroke: string = START_ICON_STROKE_NONE;
  /** 遮罩图标单独的透明度与缩放：图标先退场，背景后淡出 */
  @State launchVeilIconOpacity: number = 1;
  @State launchVeilIconScale: number = 1;
  @State launchVeilColor: string =
    ThemeService.isSystemDark() ? Palette.START_WINDOW_DARK : Palette.START_WINDOW_LIGHT;
  private tabsController: HdsTabsController = new HdsTabsController();
  private logHandler: SimpleHandler | undefined = undefined;
  private feedbackHandler: SimpleHandler | undefined = undefined;
  private supportHandler: SimpleHandler | undefined = undefined;
  private changelogHandler: SimpleHandler | undefined = undefined;
  private backupHandler: SimpleHandler | undefined = undefined;
  private busyHandler: TextHandler | undefined = undefined;
  private busyProgressHandler: TextHandler | undefined = undefined;

  aboutToAppear(): void {
    this.measureInsets();
    this.resolveTabMaterialLevel();
    this.logHandler = (): void => {
      this.animateOverlay((): void => {
        this.activeOverlay = 'log';
      });
    };
    EventBus.on(AppEvent.OPEN_LOG, this.logHandler);
    this.feedbackHandler = (): void => {
      this.animateOverlay((): void => {
        this.feedbackStep = 0;
        this.activeOverlay = 'feedback';
      });
    };
    EventBus.on(AppEvent.OPEN_FEEDBACK, this.feedbackHandler);
    this.supportHandler = (): void => {
      this.animateOverlay((): void => {
        this.activeOverlay = 'support';
      });
    };
    EventBus.on(AppEvent.OPEN_DEVICE_SUPPORT, this.supportHandler);
    this.changelogHandler = (): void => {
      this.animateOverlay((): void => {
        this.activeOverlay = 'changelog';
      });
    };
    EventBus.on(AppEvent.OPEN_CHANGELOG, this.changelogHandler);
    this.backupHandler = (): void => {
      this.animateOverlay((): void => {
        this.activeOverlay = 'backup';
      });
    };
    EventBus.on(AppEvent.OPEN_BACKUP, this.backupHandler);
    this.busyHandler = (text: string): void => {
      this.busyText = text;
    };
    EventBus.onText(AppEvent.BUSY_CHANGED, this.busyHandler);
    this.busyProgressHandler = (payload: string): void => {
      if (payload.length === 0) {
        this.busyDetail = '';
        this.busyProgress = -1;
        this.busyCancellable = false;
        return;
      }
      try {
        const state: BusyState = JSON.parse(payload) as BusyState;
        this.busyDetail = state.detail;
        this.busyProgress = state.progress;
        this.busyCancellable = state.cancellable;
      } catch (error) {
        this.busyDetail = '';
        this.busyProgress = -1;
        this.busyCancellable = false;
      }
    };
    EventBus.onText(AppEvent.BUSY_PROGRESS, this.busyProgressHandler);
  }

  /**
   * 页面已上屏、窗口就绪后才拉起系统隐私弹窗。
   * 放在 onCreate 会因窗口未准备好而失败，放在 aboutToAppear 又早于首帧，
   * 用户会看到「占位刚出现就被弹窗盖住」。
   */
  onPageShow(): void {
    if (PrivacyConsentService.isCleared()) {
      return;
    }
    PrivacyConsentService.settle().then((ready: boolean): void => {
      if (ready) {
        this.privacyBlocked = false;
        return;
      }
      if (PrivacyConsentService.isBlocked()) {
        // 该征询但征询不了（市场包报未接入 / 系统服务故障）：给重试，不静默放行
        this.privacyBlocked = true;
        return;
      }
      // 用户明确拒绝：退出应用
      this.exitApp();
    });
  }

  private retryPrivacy(): void {
    this.privacyBlocked = false;
    PrivacyConsentService.retry().then((ready: boolean): void => {
      if (ready) {
        this.privacyBlocked = false;
        return;
      }
      this.privacyBlocked = PrivacyConsentService.isBlocked();
      if (!this.privacyBlocked) {
        this.exitApp();
      }
    });
  }

  private exitApp(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 让当前这一帧先落地：在 aboutToAppear 阶段直接调 terminateSelf 会因为窗口还没挂载而失败
    setTimeout((): void => {
      context.terminateSelf().catch((error: BusinessError) => {
        Logger.exception(MODULE, '退出应用失败', error);
      });
    }, 0);
  }

  aboutToDisappear(): void {
    if (this.logHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_LOG, this.logHandler);
      this.logHandler = undefined;
    }
    if (this.feedbackHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_FEEDBACK, this.feedbackHandler);
      this.feedbackHandler = undefined;
    }
    if (this.supportHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_DEVICE_SUPPORT, this.supportHandler);
      this.supportHandler = undefined;
    }
    if (this.changelogHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_CHANGELOG, this.changelogHandler);
      this.changelogHandler = undefined;
    }
    if (this.backupHandler !== undefined) {
      EventBus.off(AppEvent.OPEN_BACKUP, this.backupHandler);
      this.backupHandler = undefined;
    }
    if (this.busyHandler !== undefined) {
      EventBus.off(AppEvent.BUSY_CHANGED, this.busyHandler);
      this.busyHandler = undefined;
    }
    if (this.busyProgressHandler !== undefined) {
      EventBus.off(AppEvent.BUSY_PROGRESS, this.busyProgressHandler);
      this.busyProgressHandler = undefined;
    }
  }

  /**
   * 沉浸光感材质能力检测。
   *
   * 官方要求：自定义沉浸光感前先调 getSystemMaterialTypes() 查询设备支持的材质类型，
   * 支持 IMMERSIVE 才能用较重的等级，不支持则降级到 SMOOTH，避免低性能设备卡顿/发热。
   * materialType 固定 ADAPTIVE，由系统按设备能力自动选最优材质类型（不再硬上最重的 IMMERSIVE）。
   */
  private resolveTabMaterialLevel(): void {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0) {
        this.tabMaterialLevel = hdsMaterial.MaterialLevel.GENTLE;
        Logger.info(MODULE, `沉浸光感：设备支持 IMMERSIVE，材质等级 GENTLE`);
      } else {
        this.tabMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
        Logger.info(MODULE, `沉浸光感：设备不支持 IMMERSIVE，材质等级降级 SMOOTH`);
      }
    } catch (error) {
      // 查询失败（旧系统 / 模拟器镜像）一律按最保守的 SMOOTH 兜底
      this.tabMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      Logger.warn(MODULE, `沉浸光感能力查询失败，材质等级兜底 SMOOTH：${(error as BusinessError).code}`);
    }
  }

  /**
   * 显式动画上下文：条件渲染的 transition 只有在 animateTo 里改状态才会播放位移
   */
  private animateOverlay(update: () => void): void {
    this.getUIContext().animateTo({ duration: 280, curve: Curve.Friction }, update);
  }

  /** 侧滑返回：日志/反馈都是 Stack 里的浮层，没有路由可退，先关浮层而不是退出应用 */
  onBackPress(): boolean {
    // 隐私未放行：页面还在等系统弹窗，没有可退的浮层，交给系统按返回处理
    if (!PrivacyConsentService.isCleared()) {
      return false;
    }
    // 全屏遮罩期间手势也吃掉，避免把正在进行的工作连同应用一起退掉
    if (this.busyText.length > 0) {
      return true;
    }
    if (this.activeOverlay === 'changelog') {
      this.animateOverlay((): void => {
        this.activeOverlay = '';
      });
      return true;
    }
    if (this.activeOverlay === 'feedback') {
      if (this.feedbackStep !== 0) {
        this.feedbackStep = 0;
      } else {
        this.animateOverlay((): void => {
          this.activeOverlay = '';
        });
      }
      return true;
    }
    if (this.activeOverlay === 'log') {
      this.animateOverlay((): void => {
        this.activeOverlay = '';
      });
      return true;
    }
    if (this.activeOverlay === 'support') {
      this.animateOverlay((): void => {
        this.activeOverlay = '';
      });
      return true;
    }
    if (this.activeOverlay === 'backup') {
      this.animateOverlay((): void => {
        this.activeOverlay = '';
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

      // 首帧即渲染首页，不做任何数据读取（各页面自己按 isCleared 判断）；
      // 系统隐私弹窗是半屏浮层，盖上来时底下已经是完整首页，观感与常规应用一致。
      // 只有「该征询却征询不了」时才整屏换成重试页
      if (!this.privacyBlocked) {
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
              materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: this.tabMaterialLevel
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
        // 隐私服务不可用（市场包报未接入 / 系统故障）：整屏换成重试页，不静默放行
        this.privacyGate()
      }

      if (this.activeOverlay === 'log') {
        LogPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.activeOverlay = '';
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.activeOverlay === 'feedback') {
        FeedbackPage({
          topInset: this.topInset,
          step: $feedbackStep,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.activeOverlay = '';
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.activeOverlay === 'support') {
        SupportedDevicesPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.activeOverlay = '';
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.activeOverlay === 'changelog') {
        ChangelogPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.activeOverlay = '';
            });
          }
        })
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.move(TransitionEdge.END)
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 280, curve: Curve.Friction }))
      }

      if (this.activeOverlay === 'backup') {
        BackupPage({
          topInset: this.topInset,
          onClose: (): void => {
            this.animateOverlay((): void => {
              this.activeOverlay = '';
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
            .fontColor(Palette.OVERLAY_TEXT)
          if (this.busyProgress >= 0) {
            Progress({ value: Math.round(this.busyProgress * 100), total: 100, type: ProgressType.Linear })
              .width(180)
              .height(4)
              .color(Palette.ACCENT)
              .backgroundColor(Palette.OVERLAY_CHIP)
          }
          if (this.busyDetail.length > 0) {
            Text(this.busyDetail)
              .fontSize(11)
              .fontColor(Palette.OVERLAY_TEXT_SUB)
          }
          if (this.busyCancellable) {
            Text(I18n.t('common.cancel'))
              .fontSize(12)
              .fontColor(Palette.OVERLAY_TEXT)
              .padding({ left: 22, right: 22, top: 7, bottom: 7 })
              .borderRadius(10)
              .backgroundColor(Palette.OVERLAY_CHIP)
              .margin({ top: 4 })
              .onClick((): void => {
                ImportControl.cancel();
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(5, 8, 14, 0.62)')
        .onClick(() => {
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
      }

      // 启动衔接遮罩放在最上层：首帧与系统启动页同色，随后淡出露出应用外观。
      // 不拦截触摸，淡出期间系统隐私弹窗或用户点击都不受影响
      if (this.launchVeil) {
        // 遮罩复刻系统启动页：同样的底色 + 同样大小、居中的图标。
        // 只有底色没有图标的话，启动页退场时图标会突然消失，看起来就是一片白闪一下
        Column() {
          Image($r('app.media.startIcon'))
            .width(START_ICON_PX)
            .height(START_ICON_PX)
            .objectFit(ImageFit.Contain)
            .borderRadius(START_ICON_RADIUS_PX)
            .border({ width: '2px', color: this.launchVeilIconStroke })
            .opacity(this.launchVeilIconOpacity)
            .scale({ x: this.launchVeilIconScale, y: this.launchVeilIconScale })
            .draggable(false)
        }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.launchVeilColor)
          .opacity(this.launchVeilOpacity)
          .hitTestBehavior(HitTestMode.None)
          // 注意：这里不能用 .transition(TransitionEffect.OPACITY.animation(...))。
          // 带 animation 参数的 transition 在组件首次出现时也会播放「淡入」，
          // 首帧遮罩是透明的，用户会看到 启动页浅色 → 深色首页 → 遮罩淡入变浅 → 再淡出 的闪烁。
          // 改为直接驱动 opacity：首帧即不透明，淡出结束后再移除节点
          .onAppear((): void => {
            Logger.info(MODULE, `启动衔接遮罩上屏 color=${this.launchVeilColor}`);
            // 三段过渡：
            // 1. 底色从启动页色渐变到应用底色（浅 → 深），图标不动
            // 2. 图标在深色底上缩小淡出，背景不动
            // 3. 只剩与首页同色的底，淡出露出首页内容
            setTimeout((): void => {
              this.getUIContext().animateTo({
                duration: LAUNCH_VEIL_COLOR_MS,
                curve: Curve.EaseInOut,
                onFinish: (): void => {
                  this.getUIContext().animateTo({
                    duration: LAUNCH_VEIL_ICON_MS,
                    curve: Curve.EaseIn,
                    onFinish: (): void => {
                      this.getUIContext().animateTo({
                        duration: LAUNCH_VEIL_FADE_MS,
                        curve: Curve.EaseOut,
                        onFinish: (): void => {
                          this.launchVeil = false;
                        }
                      }, (): void => {
                        this.launchVeilOpacity = 0;
                      });
                    }
                  }, (): void => {
                    this.launchVeilIconOpacity = 0;
                    this.launchVeilIconScale = LAUNCH_VEIL_ICON_END_SCALE;
                  });
                }
              }, (): void => {
                this.launchVeilColor = Palette.BG_TOP;
                this.launchVeilIconStroke = ThemeService.isDark() ? START_ICON_STROKE_DARK : START_ICON_STROKE_NONE;
              });
            }, LAUNCH_VEIL_HOLD_MS);
          })
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG_TOP)
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** 隐私声明：托管链接优先，取不到时由 PrivacyLinkService 回退到公开声明 */
  private openPrivacyStatement(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean): void => {
      if (!opened) {
        this.toast(I18n.t('profile.privacyUnavailable'));
      }
    });
  }

  /**
   * 隐私服务不可用时的重试页（该征询却征询不了）。
   *
   * 只在 `privacyBlocked` 为真时出现：正常等待系统弹窗时首页照常渲染在下面。
   * 不出现任何「同意」按钮——同意只由系统标准化弹窗给出，自绘同意界面属审核驳回项。
   */
  @Builder
  privacyGate() {
    Column({ space: 18 }) {
      Text(I18n.t('privacy.failed'))
        .fontSize(13)
        .fontColor(Palette.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
        .lineHeight(21)
        .width('78%')
      Text(I18n.t('privacy.retry'))
        .fontSize(13)
        .fontColor(Palette.TEXT_PRIMARY)
        .padding({ left: 26, right: 26, top: 9, bottom: 9 })
        .borderRadius(15)
        .backgroundColor(Palette.GLASS_BTN)
        .onClick((): void => {
          this.retryPrivacy();
        })
      Text(I18n.t('privacy.viewStatement'))
        .fontSize(12)
        .fontColor(Palette.TEXT_TERTIARY)
        .onClick((): void => {
          this.openPrivacyStatement();
        })
      Text(I18n.t('privacy.exit'))
        .fontSize(12)
        .fontColor(Palette.TEXT_TERTIARY)
        .onClick((): void => {
          this.exitApp();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Palette.BG_TOP)
    // 吃掉点击，避免占位期间的手势穿透到下面
    .onClick((): void => {
    })
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
