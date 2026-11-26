/**
 * 写入引擎自己的时序参数。
 *
 * 协议常量（帧格式、UUID、槽位号）和建链时序仍在 AppConstants 的 MbbSpec 里，
 * 那些数值都有真机日志依据，这次重构不动；这里只放新引擎引入的参数。
 */
export class WriteSpec {
  /** 整包重传最多几轮：只在「数据还没收完就断链」时才会用到第二轮 */
  static readonly MAX_UPLOAD_ROUNDS: number = 2;
  /** 两轮之间的间隔：给耳机收掉上一条串口的时间 */
  static readonly ROUND_GAP_MS: number = 1200;

  /**
   * 进度回调的最小间隔。
   * 擦写进度约 80ms 一包，每包都推给界面会让主线程忙于重绘，
   * 而 sppRead 回调和写完成回调也排在同一个主线程上——界面越忙，回执处理越慢。
   */
  static readonly PROGRESS_MIN_INTERVAL_MS: number = 120;

  /** 失败回滚：第一次在失败后多久尝试（串口刚断，立刻重连只会先吃冷却） */
  static readonly ROLLBACK_FIRST_DELAY_MS: number = 3000;
  /** 失败回滚：之后每次重试的间隔 */
  static readonly ROLLBACK_RETRY_DELAY_MS: number = 5000;
  /** 失败回滚最多尝试几次 */
  /** 失败回滚最多尝试几次：盒盖合着时每次只检查不建链，所以给到约 1 分钟 */
  static readonly ROLLBACK_ATTEMPTS: number = 12;
  /** 失败回滚最多真正建链几次：每次可能占十几秒，再多就交给用户自己处理 */
  static readonly ROLLBACK_CONNECT_TRIES: number = 2;
  /** 回滚时的建链预算：后台任务，不必像前台写入那样等满 15 秒 */
  static readonly ROLLBACK_CONNECT_BUDGET_MS: number = 8000;

  /** 写完后多久尝试把 A2DP 连回来（耳机擦闪存期间不接受新连接） */
  static readonly AUDIO_RESTORE_DELAY_MS: number = 16000;

  /**
   * 写完一条后，至少隔多久才允许再建串口。
   *
   * 2026-11-26 19:05 真机：上一条写完（擦写走满、未补 09 06）13.8 秒后开始下一条，
   * 沉降期因「音频已自行连回」被提前放行，第一枪 sppConnect 3 秒无响应，此后耳机串口卡死：
   * 之后 3 分钟内四轮写入全部被拒（-1 / 10ms 内的 2900099）。同一轮里间隔 27 秒、52 秒的两次都正常。
   * 结合更早的记录（6 秒卡死、11 秒正常），「音频连回」不能当擦写完成的信号，这里不再提前放行，
   * 一律等满。25 秒是按现有几组数据取的保守值，后续有更多样本再收紧。
   */
  static readonly POST_FLASH_GAP_MS: number = 25000;

  /**
   * 调试覆盖：只在 debug 包里由「我的 → 连点版本号」设置，用来测 25 秒能不能缩短。
   * 0 表示用默认值。正式包启动时不会读取这个设置。
   */
  static gapOverrideMs: number = 0;

  /** 实际生效的写后间隔 */
  static postFlashGapMs(): number {
    return WriteSpec.gapOverrideMs > 0 ? WriteSpec.gapOverrideMs : WriteSpec.POST_FLASH_GAP_MS;
  }

  /** 2900099 在这么短的时间内就回来，说明是本机协议栈直接拒绝，没有走到耳机 */
  static readonly FAST_REJECT_MS: number = 150;
  /** 连续这么多次「秒拒」就判定串口卡死，不再耗满建链预算 */
  static readonly FAST_REJECT_LIMIT: number = 4;

  /**
   * sppConnect 超时没回调后，最多等它多久迟到回调，期间不发新的连接请求。
   *
   * 2026-11-26 19:05:23 与 20:01:55 两次真机：第一枪 sppConnect 3 秒无回调，我们随即发下一条请求，
   * 之后每条都在 150ms 左右被本机拒绝，挂起的那条一直没回来，直到重启应用。
   * 不确定是挂起本身就卡死了协议栈，还是「挂起期间又塞请求」把它卡死——先不再塞请求，等它回来：
   * 迟到成功就直接用这条串口；迟到失败照常重试；等满仍没回来才判定卡死。
   */
  static readonly HUNG_CONNECT_WAIT_MS: number = 10000;

  /**
   * 串口在松开音频这么久之后才连上，就不用它：关掉，按标准顺序重新建一次。
   *
   * 2026-11-26 真机，第一枪 sppConnect 挂起后迟到失败、再试才连上的三次：
   * 21:47:02（距松开 15.7 秒）开始传输后一直没有窗口 → 回执超时；
   * 22:35:27（14.6 秒）、22:38:06（15.4 秒）握手时音频已被系统连回，断开音频后第一包就 2901054。
   * 三次第 1 轮全部作废，还各吃一次冷却，22:38 那次第 2 轮再挂起后卡死。
   * 正常建链是 2~3 秒；20:13 那次挂起后 7.7 秒连上的照常写成功，所以取 10 秒。样本少，后续再调。
   */
  static readonly STALE_LINK_MS: number = 10000;

  /** 建链前音频不在时，等它重新连上的上限（盒盖合着时会走满） */
  static readonly AUDIO_RESTORE_WAIT_MS: number = 5000;

  /** 短时任务的申请理由：会出现在系统的后台任务记录里 */
  static readonly SUSPEND_REASON: string = 'boxtone-write';
}
