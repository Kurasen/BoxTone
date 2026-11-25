import { common } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';
import { BluetoothService } from './BluetoothService';
import { FeedbackService } from './FeedbackService';
import { ToneRepositoryService } from './ToneRepositoryService';
import { SelfCheckService } from './SelfCheckService';

const MODULE: string = 'Bootstrap';

/**
 * 业务服务启动入口。
 *
 * 由 PrivacyConsentService 在隐私闸门放行时（markCleared）调用，是业务初始化的唯一入口：
 * 幂等条件不成立时会读取已配对设备、扫描音效库、注册蓝牙/星闪监听，
 * 这些都属于用户同意隐私声明之前不该发生的处理动作。
 * 放行前首页只渲染渐变背景与占位，不碰任何数据。
 * 运行环境、日志中心、设置、外观这些基础能力已在 EntryAbility.onCreate 初始化。
 * 完成后置位 AppStorage 的 servicesReady，首页据此把占位切换成完整界面。
 */
export class AppBootstrap {
  private static initialized: boolean = false;

  /** @param reason 放行路径（已同意 / 弹窗同意 / 非市场分发包…），只用于日志 */
  public static init(context: common.UIAbilityContext, reason: string): void {
    if (AppBootstrap.initialized) {
      // Ability 重建后重新放行：服务已经跑过，不重复初始化
      return;
    }
    AppBootstrap.initialized = true;
    // 隐私状态属内部信息，只给开发期看，不进日志中心
    Logger.dev(MODULE, `业务服务初始化（${reason}）`);
    // 逐个初始化：某个服务失败不连累其他服务，
    // 否则音效库异常会让蓝牙也初始化不了，用户看到的是一连串功能同时失效
    AppBootstrap.initOne('音效库', (): void => {
      ToneRepositoryService.init(context);
    });
    AppBootstrap.initOne('蓝牙', (): void => {
      BluetoothService.init(context);
    });
    AppBootstrap.initOne('反馈', (): void => {
      FeedbackService.init(context);
    });
    // 纯计算部分的自检：协议编解码、摘要、音效包结构、波形合成等改错后肉眼看不出来。
    // runIfDebug 内部按 applicationInfo.debug 判断，release 包直接返回，不消耗任何性能
    AppBootstrap.initOne('自检', (): void => {
      SelfCheckService.runIfDebug(context);
    });
  }

  private static initOne(name: string, action: () => void): void {
    try {
      action();
    } catch (error) {
      // 单个服务失败只记录，继续初始化其余服务
      Logger.exception(MODULE, `${name}服务初始化失败`, error as Error);
    }
  }
}
