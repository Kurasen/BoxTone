import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv } from '../common/utils/AppEnv';
import { Logger } from '../common/utils/Logger';
import { LogService } from '../services/LogService';
import { BluetoothService } from '../services/BluetoothService';
import { LanguageService } from '../services/LanguageService';
import { PrivacyConsentService } from '../services/PrivacyConsentService';
import { SettingsService } from '../services/SettingsService';
import { ThemeService } from '../services/ThemeService';
import { WriteGuard } from '../services/write/WriteGuard';
import { WriteSpec } from '../services/write/WriteSpec';

const MODULE: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // ---- 基础能力：只读写本地数据、不涉及个人信息，在隐私同意前完成 ----
    // 运行环境标记最先：Logger.dev 依赖它，晚于此刻会把 debug 包早期的开发期日志丢掉
    AppEnv.init(this.context);
    // 日志中心紧随其后：隐私状态查询、签署事件都发生在业务服务之前，
    // 晚于此刻初始化会导致这些早期日志只写 hilog、进不了日志中心，release 包排查困难
    LogService.getInstance().init(this.context);
    // 写入保护（短时任务 + 屏幕常亮）需要 UIAbility 上下文；只登记，不申请任何东西
    WriteGuard.attach(this.context);
    // 应用语言：按设备地区自动选择简体中文 / English（每次启动判定，幂等）
    LanguageService.apply();
    // 设置存储必须早于外观：ThemeService 要读取保存的外观模式，存储未就绪会一直读到默认深色
    SettingsService.init(this.context);
    // 写后间隔测试：只有 debug 包读取覆盖值，正式包始终用默认 25 秒
    if (AppEnv.isDebug()) {
      WriteSpec.gapOverrideMs = SettingsService.getDebugFlashGapMs();
    }
    // 应用外观：默认跟随系统，可在「我的 → 外观设置」切换深色/浅色/跟随系统；
    // setColorMode 同时决定系统弹窗、半模态与 HDS 底栏材质的深浅
    ThemeService.init(this.context);
    // ---- 隐私闸门：只查状态 + 订阅事件，不初始化业务 ----
    // 业务服务（蓝牙、音效库、反馈）由闸门放行时统一初始化：
    // 它们会读取已配对设备、扫描音效目录，属于用户同意隐私声明前不该发生的处理动作。
    // 首页首帧只渲染渐变背景与占位，系统弹窗在 onPageShow 阶段拉起
    PrivacyConsentService.start(this.context);
  }

  /** 仅"跟随系统"模式会收到该回调；手动指定深浅色时系统不派发 */
  onConfigurationUpdate(newConfig: Configuration): void {
    ThemeService.onSystemColorChanged(newConfig);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error: BusinessError) => {
      if (error.code) {
        Logger.exception(MODULE, '加载首页失败', error);
        return;
      }
      Logger.info(MODULE, '首页加载完成');
    });

    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      // 全屏布局，让背景渐变延伸到状态栏下方
      return mainWindow.setWindowLayoutFullScreen(true).then(() => {
        // 登记主窗口：系统栏图标颜色统一由 ThemeService 按当前外观设置，之后切换外观也用这个窗口
        ThemeService.attachWindow(mainWindow);
      });
    }).catch((error: BusinessError) => {
      Logger.exception(MODULE, '设置沉浸式布局失败', error);
    });
  }

  onWindowStageDestroy(): void {
    ThemeService.detachWindow();
    Logger.info(MODULE, '窗口销毁');
  }

  onDestroy(): void {
    PrivacyConsentService.stop();
    LogService.getInstance().flush();
    Logger.info(MODULE, '应用退出');
  }

  onBackground(): void {
    // 写入中退到后台：短时任务保住进程，这里只记一笔，便于对照断链日志
    WriteGuard.setForeground(false);
    LogService.getInstance().flush();
  }

  onForeground(): void {
    WriteGuard.setForeground(true);
    // 后台期间蓝牙/星闪状态可能变化且没有事件补发：回前台立即拉一次。
    // 隐私放行前不读取蓝牙状态（refresh 会补注册监听并读取已配对设备）
    if (PrivacyConsentService.isCleared()) {
      BluetoothService.refresh();
    }
  }
}
