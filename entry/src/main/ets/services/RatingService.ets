import { common } from '@kit.AbilityKit';
import { commentManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';
import { RatingState, SettingsService } from './SettingsService';

const MODULE: string = 'Rating';

const DAY_MS: number = 24 * 60 * 60 * 1000;
/** 至少成功写入几次：第一次刚写完，用户还没听到效果，没有说服力 */
const MIN_WRITES: number = 2;
/** 距首次使用至少几天：刚装上就弹像在讨要评分 */
const MIN_DAYS: number = 3;
/** 写入失败后多久内不打扰：用户正烦着，这时候弹等于火上浇油 */
const FAIL_QUIET_DAYS: number = 7;
/**
 * 两次请求的间隔由「上次结果」决定（华为官方博客建议的动态延后）：
 * 成功弹出 / 当前版本已评 / 次数上限 → 一个月后再问；
 * 一年内已评 → 一年后再问（对应官方「新版本 + 满一年」的硬限制）。
 */
const RETRY_AFTER_SUCCESS_MS: number = 30 * DAY_MS;
const RETRY_AFTER_YEAR_MS: number = 365 * DAY_MS;
/**
 * 临时故障（系统内部错误 / 服务请求失败 / 连不上应用市场）：多是网络或服务抖动，3 天后再试。
 * 未登录华为账号（1021500006）不算临时故障：评分记在系统华为账号下，没登录的用户通常长期不登录，仍按 30 天。
 */
const RETRY_AFTER_TRANSIENT_MS: number = 3 * DAY_MS;
const TRANSIENT_CODES: number[] = [1021500001, 1021500002, 1021500003];

/**
 * 应用评分。
 *
 * 只用系统弹窗（commentManager.showCommentDialog），不自绘「喜欢就给个好评」这类引导框：
 * 一是华为审核会把自绘的二段式评分引导判定为诱导评价，二是系统弹窗自带频次控制
 * （同版本已评、配额用完、一年内评过都会直接拒绝，见 1021500007/8/9）。
 *
 * 时机只放在「写入成功之后」——这是这类工具应用唯一的情绪高点；
 * 打开应用时弹、设置页弹，转化率都远不如刚写完那一下。
 */
export class RatingService {
  /** 进程内去重：同一次会话里即使多次触发也只尝试一次 */
  private static asking: boolean = false;

  /**
   * 写入成功后调用。所有条件都满足才会拉起系统评分弹窗。
   * 无论系统最终弹没弹，都会根据结果记下「下次可问时间」：
   * 成功 / 已评 / 次数上限 → 一个月后；一年内已评 → 一年后。
   *
   * 每个未通过的条件都会打一条日志：本地验证时看日志就知道卡在哪一步，
   * 线上也能据此判断"为什么这个用户从来没被请求过评分"。
   */
  public static async maybeAskAfterWrite(context: common.UIAbilityContext): Promise<void> {
    if (RatingService.asking) {
      Logger.dev(MODULE, '跳过：本次会话已经尝试过');
      return;
    }
    if (!SettingsService.isReady()) {
      Logger.dev(MODULE, '跳过：设置尚未加载完成');
      return;
    }
    const now: number = Date.now();

    // 1) 还没到下次可问时间：冷却时长由上次结果决定（成功/已评→30天，一年内已评→365天）
    const nextAskAt: number = SettingsService.getRatingAskedAt();
    if (nextAskAt > 0 && now < nextAskAt) {
      Logger.dev(MODULE, `跳过：距下次可问还有 ${RatingService.daysOf(nextAskAt - now)} 天`);
      return;
    }
    // 2) 成功写入次数不够
    const count: number = SettingsService.getWriteSuccessCount();
    if (count < MIN_WRITES) {
      Logger.dev(MODULE, `跳过：成功写入 ${count}/${MIN_WRITES} 次`);
      return;
    }
    // 3) 用得太短
    const firstUseAt: number = SettingsService.getFirstUseAt();
    if (firstUseAt === 0 || now - firstUseAt < MIN_DAYS * DAY_MS) {
      const used: string = firstUseAt === 0 ? '0' : RatingService.daysOf(now - firstUseAt);
      Logger.dev(MODULE, `跳过：已使用 ${used} 天，需满 ${MIN_DAYS} 天`);
      return;
    }
    // 4) 最近写入失败过
    const failAt: number = SettingsService.getLastWriteFailureAt();
    if (failAt > 0 && now - failAt < FAIL_QUIET_DAYS * DAY_MS) {
      Logger.dev(MODULE, `跳过：${RatingService.daysOf(now - failAt)} 天前有写入失败，需静默 ${FAIL_QUIET_DAYS} 天`);
      return;
    }

    RatingService.asking = true;
    Logger.dev(MODULE, `条件满足（写入 ${count} 次 / 使用 ${RatingService.daysOf(now - firstUseAt)} 天），拉起系统评分弹窗`);
    try {
      await commentManager.showCommentDialog(context);
      Logger.dev(MODULE, '已拉起系统评分弹窗');
      // 成功弹出：一个月后再问
      SettingsService.markRatingAsked(now + RETRY_AFTER_SUCCESS_MS);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      if (err.code === 1021500009) {
        // 一年内已评：按官方硬限制一年后再问
        SettingsService.markRatingAsked(now + RETRY_AFTER_YEAR_MS);
        Logger.dev(MODULE, `系统按配额拒绝 code=1021500009（一年内已评），延后一年`);
      } else if (err.code === 1021500007 || err.code === 1021500008) {
        // 当前版本已评 / 次数上限：一个月后再问
        SettingsService.markRatingAsked(now + RETRY_AFTER_SUCCESS_MS);
        Logger.dev(MODULE, `系统按配额拒绝 code=${err.code}，延后一个月`);
      } else if (TRANSIENT_CODES.indexOf(err.code) >= 0) {
        // 临时故障：3 天后再给一次机会
        SettingsService.markRatingAsked(now + RETRY_AFTER_TRANSIENT_MS);
        Logger.dev(MODULE, `评分弹窗未展示 code=${err.code}（临时故障），延后 3 天`);
      } else {
        // 未登录华为账号（006）、参数或 context 异常（004/005）等：重试意义不大，按一个月冷却
        SettingsService.markRatingAsked(now + RETRY_AFTER_SUCCESS_MS);
        Logger.dev(MODULE, `评分弹窗未展示 code=${err.code} ${err.message}，延后一个月`);
      }
    }
  }

  /** 毫秒差换成天数，日志里可读一些（保留一位小数） */
  private static daysOf(ms: number): string {
    return (ms / DAY_MS).toFixed(1);
  }

  /**
   * 仅供本地验证：把四个前置条件模拟成「刚好满足」，完整走一遍正式判断流程，
   * 结束后把真实计数原样恢复——测多少次都不会污染用户的真实数据。
   *
   * 入口藏在「我的」页连点版本号 3 次，且只在 debug 构建响应。
   */
  public static async simulateSatisfied(context: common.UIAbilityContext): Promise<void> {
    const backup: RatingState = SettingsService.snapshotRating();
    SettingsService.seedRatingSatisfied();
    RatingService.asking = false;
    Logger.dev(MODULE, '测试：已模拟为「写入 2 次 / 3 天前开始使用 / 无失败 / 从未请求」');
    try {
      await RatingService.maybeAskAfterWrite(context);
    } finally {
      SettingsService.restoreRating(backup);
      RatingService.asking = false;
      Logger.dev(MODULE, '测试：真实计数已恢复');
    }
  }
}
