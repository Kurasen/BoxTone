import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../common/utils/Logger';
import { WriteSpec } from './WriteSpec';

const MODULE: string = 'WriteGuard';

/**
 * 写入期间的系统级保护。
 *
 * 1. 蓝牙长时任务（BLUETOOTH_INTERACTION）。
 *    2026-11-26 真机：写入中退到后台超过约 5 秒（5.3 / 5.8 / 6.2 / 7.9 / 8.8 秒，5 次全中），
 *    这一次写入照样成功，但**下一次** sppConnect 在 10ms 内就被本机协议栈回 2900099，
 *    合盖、关开耳机都无效，只有重启应用进程能恢复；后台 1.6 / 4.2 秒、以及从未进后台的写入都没有这个问题。
 *    短时任务只保证进程不被挂起，系统仍会对后台应用的蓝牙资源做管控，所以要申请蓝牙类长时任务——
 *    这正是 BackgroundMode.BLUETOOTH_INTERACTION 的用途。
 *    需要 ohos.permission.KEEP_BACKGROUND_RUNNING（system_grant）与 module.json5 里的 backgroundModes，
 *    只能在前台申请；运行期间系统会显示一条通知，写完立刻取消。
 * 2. 短时任务（requestSuspendDelay）：长时任务申请失败时的兜底，至少保证不被挂起。
 * 3. 屏幕常亮。
 *
 * 引用计数：嵌套的设备操作（写入失败后的回滚）共用同一份保护。
 */
export class WriteGuard {
  private static context: common.UIAbilityContext | null = null;
  private static foreground: boolean = true;
  private static holders: number = 0;
  private static requestId: number = -1;
  private static continuous: boolean = false;
  private static backgroundedDuringHold: boolean = false;
  private static backgroundSince: number = 0;
  private static backgroundTotalMs: number = 0;

  /** EntryAbility.onCreate 里登记 */
  static attach(context: common.UIAbilityContext): void {
    WriteGuard.context = context;
  }

  /** EntryAbility.onForeground / onBackground 里调用 */
  static setForeground(foreground: boolean): void {
    WriteGuard.foreground = foreground;
    if (WriteGuard.holders <= 0) {
      return;
    }
    if (!foreground) {
      WriteGuard.backgroundedDuringHold = true;
      WriteGuard.backgroundSince = Date.now();
    } else if (WriteGuard.backgroundSince > 0) {
      WriteGuard.backgroundTotalMs += Date.now() - WriteGuard.backgroundSince;
      WriteGuard.backgroundSince = 0;
    }
    Logger.info(MODULE, `写入期间应用${foreground ? '回到前台' : '退到后台'} ` +
      `continuous=${WriteGuard.continuous ? 'on' : 'off'} transient=${WriteGuard.requestId >= 0 ? 'on' : 'off'} ` +
      `bgTotal=${WriteGuard.backgroundMs()}ms`);
  }

  /** 这一轮保护期间应用是否进过后台 */
  static wasBackgrounded(): boolean {
    return WriteGuard.backgroundedDuringHold;
  }

  /** 这一轮保护期间累计在后台的时长 */
  static backgroundMs(): number {
    const running: number = WriteGuard.backgroundSince > 0 ? Date.now() - WriteGuard.backgroundSince : 0;
    return WriteGuard.backgroundTotalMs + running;
  }

  /** 这一轮是否拿到了蓝牙长时任务 */
  static hasContinuousTask(): boolean {
    return WriteGuard.continuous;
  }

  static async acquire(): Promise<void> {
    WriteGuard.holders++;
    if (WriteGuard.holders > 1) {
      return;
    }
    WriteGuard.backgroundedDuringHold = !WriteGuard.foreground;
    WriteGuard.backgroundSince = WriteGuard.foreground ? 0 : Date.now();
    WriteGuard.backgroundTotalMs = 0;
    await WriteGuard.startContinuous();
    WriteGuard.requestTransient();
    await WriteGuard.keepScreenOn(true);
  }

  static async release(): Promise<void> {
    if (WriteGuard.holders <= 0) {
      return;
    }
    WriteGuard.holders--;
    if (WriteGuard.holders > 0) {
      return;
    }
    WriteGuard.cancelTransient();
    await WriteGuard.stopContinuous();
    await WriteGuard.keepScreenOn(false);
  }

  /** 申请蓝牙长时任务：只能在前台申请，失败不影响写入（退回短时任务） */
  private static async startContinuous(): Promise<void> {
    const context: common.UIAbilityContext | null = WriteGuard.context;
    if (context === null || WriteGuard.continuous) {
      return;
    }
    if (!WriteGuard.foreground) {
      Logger.warn(MODULE, '应用在后台，无法申请蓝牙长时任务');
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION, agent);
      WriteGuard.continuous = true;
      Logger.info(MODULE, '蓝牙长时任务已申请');
    } catch (error) {
      Logger.warn(MODULE, `蓝牙长时任务申请失败 code=${(error as BusinessError).code}，退回短时任务`);
    }
  }

  private static async stopContinuous(): Promise<void> {
    const context: common.UIAbilityContext | null = WriteGuard.context;
    if (context === null || !WriteGuard.continuous) {
      return;
    }
    WriteGuard.continuous = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      Logger.info(MODULE, '蓝牙长时任务已取消');
    } catch (error) {
      Logger.warn(MODULE, `取消蓝牙长时任务失败 code=${(error as BusinessError).code}`);
    }
  }

  private static requestTransient(): void {
    if (WriteGuard.requestId >= 0) {
      return;
    }
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(WriteSpec.SUSPEND_REASON, () => {
          Logger.warn(MODULE, '短时任务即将到期，写入仍未结束');
          WriteGuard.cancelTransient();
        });
      WriteGuard.requestId = info.requestId;
    } catch (error) {
      // 配额用尽或系统拒绝：不影响写入本身
      Logger.warn(MODULE, `短时任务申请失败 code=${(error as BusinessError).code}`);
    }
  }

  private static cancelTransient(): void {
    const id: number = WriteGuard.requestId;
    if (id < 0) {
      return;
    }
    WriteGuard.requestId = -1;
    try {
      backgroundTaskManager.cancelSuspendDelay(id);
    } catch (error) {
      Logger.warn(MODULE, `取消短时任务失败 code=${(error as BusinessError).code}`);
    }
  }

  private static async keepScreenOn(on: boolean): Promise<void> {
    const context: common.UIAbilityContext | null = WriteGuard.context;
    if (context === null) {
      return;
    }
    try {
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowKeepScreenOn(on);
    } catch (error) {
      Logger.warn(MODULE, `设置屏幕常亮失败 on=${on} code=${(error as BusinessError).code}`);
    }
  }
}
