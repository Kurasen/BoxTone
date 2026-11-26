import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogService } from '../../services/LogService';
import { Logger } from './Logger';

const MODULE: string = 'AppRestart';

/**
 * 重启应用进程。
 *
 * 用于蓝牙串口卡死：真机上卡死后合盖、关开耳机都没用，只有把应用从后台划掉才能恢复，
 * 说明卡住的是本进程在系统蓝牙服务里登记的串口状态（例如一条超时后仍挂着的 sppConnect），
 * 鸿蒙没有接口能撤回它，进程退出时系统才会一并回收。
 *
 * ApplicationContext.restartApp（API 12 起）只能在主线程、应用位于前台时调用，
 * 3 秒内重复调用会返回 16000064；重启不会走 onDestroy，所以先把日志落盘。
 * 只由用户在失败弹窗里点按钮触发，绝不自动重启；重启后由用户自己重新写入。
 */
export class AppRestart {
  static restart(context: common.UIAbilityContext): boolean {
    LogService.getInstance().flush();
    try {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      };
      Logger.warn(MODULE, '用户确认重启应用以恢复蓝牙串口');
      LogService.getInstance().flush();
      context.getApplicationContext().restartApp(want);
      return true;
    } catch (error) {
      Logger.warn(MODULE, `重启应用失败 code=${(error as BusinessError).code}`);
      return false;
    }
  }
}
