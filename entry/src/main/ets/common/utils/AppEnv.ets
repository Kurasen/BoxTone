import { common } from '@kit.AbilityKit';

/**
 * 运行环境标记。
 *
 * `applicationInfo.debug` 是包自身的属性（debug 签名带调试标记，release 包为 false），
 * 本地就能判断，不需要联网、也不依赖任何服务端配置。
 *
 * 用途：
 * - 开发期日志（Logger.dev）只在 debug 构建输出，release 用户翻日志中心看不到内部判断过程；
 * - 仅供测试的入口（例如设置页连点版本号触发的评分弹窗）只在 debug 构建响应。
 */
export class AppEnv {
  private static debugBuild: boolean = false;

  public static init(context: common.UIAbilityContext): void {
    try {
      AppEnv.debugBuild = context.applicationInfo.debug;
    } catch (error) {
      // 读不到就按正式版处理：宁可少一条调试日志，也不让测试入口漏到线上
      AppEnv.debugBuild = false;
    }
  }

  public static isDebug(): boolean {
    return AppEnv.debugBuild;
  }
}
