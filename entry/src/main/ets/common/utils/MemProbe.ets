import { hidebug, jsLeakWatcher } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv } from './AppEnv';
import { Logger } from './Logger';

const MODULE: string = 'MemProbe';
/** 两次常规采样的最小间隔：测试平台每 5~10 秒切一次前后台，不节流会刷满 600 条的日志中心 */
const SAMPLE_MIN_GAP_MS: number = 30000;
/** 距上次采样 JS 堆涨了这么多（KB）就不等间隔，立刻再记一条 */
const SAMPLE_GROWTH_KB: number = 16 * 1024;
/** JS 堆用量超过上限的这个比例改记 warn，并缩短采样间隔 */
const HEAP_WARN_RATIO: number = 0.6;
const HEAP_WARN_GAP_MS: number = 5000;
/** debug 包泄漏检查的最小间隔：check() 会触发一次 GC，不能每次切后台都做 */
const LEAK_CHECK_GAP_MS: number = 60000;

/**
 * 内存打点（release 包同样记录，不含任何用户数据）。
 *
 * 背景：1.2.1 上架测试 OOM，JS 堆 386MB 打满、Full GC 后存活率 97%，
 * 堆里是几十万个 Function / Set / WeakRef / Proxy —— 组件与状态变量在累积，见 docs/stability-oom.md。
 *
 * 两类数据：
 * - 实例计数：组件在 aboutToAppear / aboutToDisappear 里调 mount / unmount。
 *   live 是当前存活数，created 是进程内累计创建数。页面级组件 live 超过预期即 `MEM_DUP` 告警；
 *   created 远大于 live 说明页面在被反复销毁重建（例如页签切换时重建子页）。
 * - 进程内存：sample() 记 JS 堆 / 上限、RSS / PSS、显存，由 EntryAbility 在前后台切换时调用，自带节流。
 * - 泄漏确认（仅 debug 包）：unmount 时把组件实例交给系统 jsLeakWatcher，切后台时 check()，
 *   GC 后仍没回收的实例记 MEM_LEAK。这是「谁没被释放」的直接证据，release 包不开（check 会触发 GC）。
 *
 * 日志关键字：MEM_MOUNT / MEM_UNMOUNT / MEM_DUP / MEM_SAMPLE / MEM_LEAK。
 */
export class MemProbe {
  private static live: Map<string, number> = new Map<string, number>();
  private static created: Map<string, number> = new Map<string, number>();
  private static lastSampleAt: number = 0;
  private static lastHeapKb: number = 0;
  /** JS 堆上限（KB）：进程内不变，读一次缓存；-1 表示还没读，0 表示读不到 */
  private static heapLimitKb: number = -1;
  /** 上一条带原生内存的采样还没回来时，不再叠加新的异步读取 */
  private static nativePending: boolean = false;
  private static leakWatching: boolean = false;
  private static lastLeakCheckAt: number = 0;
  /** 上次检查之后新交给 jsLeakWatcher 的实例数 */
  private static watchedSinceCheck: number = 0;

  /** 进程启动时调用一次：debug 包打开系统 JS 泄漏检测，release 包什么都不做 */
  public static init(): void {
    if (!AppEnv.isDebug()) {
      return;
    }
    try {
      jsLeakWatcher.enable(true);
      MemProbe.leakWatching = true;
      Logger.info(MODULE, 'jsLeakWatcher 已开启（debug 包）');
    } catch (error) {
      Logger.warn(MODULE, `开启 jsLeakWatcher 失败 code=${(error as BusinessError).code}`);
    }
  }

  /**
   * 组件挂载。
   * @param name 组件名
   * @param maxLive 正常情况下最多同时存活的实例数，超出记 MEM_DUP
   * @param verbose 是否每次都记一条 MEM_MOUNT；列表行、卡片这类高频组件传 false，只计数
   */
  public static mount(name: string, maxLive: number = 1, verbose: boolean = true): void {
    const live: number = (MemProbe.live.get(name) ?? 0) + 1;
    const created: number = (MemProbe.created.get(name) ?? 0) + 1;
    MemProbe.live.set(name, live);
    MemProbe.created.set(name, created);
    if (live > maxLive) {
      Logger.warn(MODULE, `MEM_DUP ${name} live=${live} max=${maxLive} created=${created}`);
      return;
    }
    if (verbose) {
      Logger.info(MODULE, `MEM_MOUNT ${name} live=${live} created=${created}`);
    }
  }

  /**
   * 组件卸载。
   * @param target 组件实例（传 this）：debug 包里交给 jsLeakWatcher，之后 GC 还在就判泄漏
   */
  public static unmount(name: string, verbose: boolean = true, target?: object): void {
    const live: number = Math.max(0, (MemProbe.live.get(name) ?? 0) - 1);
    MemProbe.live.set(name, live);
    if (MemProbe.leakWatching && target !== undefined) {
      try {
        jsLeakWatcher.watch(target, name);
        MemProbe.watchedSinceCheck++;
      } catch (error) {
        // 只是诊断，失败不影响业务
      }
    }
    if (verbose) {
      Logger.info(MODULE, `MEM_UNMOUNT ${name} live=${live} created=${MemProbe.created.get(name) ?? 0}`);
    }
  }

  /**
   * debug 包：检查已卸载却没被回收的组件。
   * 默认 60 秒节流（切后台时调用）；压测结束、调试菜单手动触发时传 force 跳过节流。
   * 自动检查时，没有新卸载的组件就不查——首轮复现里唯一一次切后台发生在任何页面卸载之前，白白占掉了节流窗口。
   * force（手动 / 压测结束）总是查：第 2 轮 08:55 报了一个 DeviceRow 未回收，之后再没有新卸载，
   * 旧逻辑下手动检查也直接跳过，没法确认它后来是否被回收。
   */
  public static checkLeaks(force: boolean = false): void {
    if (!MemProbe.leakWatching || (!force && MemProbe.watchedSinceCheck === 0)) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - MemProbe.lastLeakCheckAt < LEAK_CHECK_GAP_MS) {
      return;
    }
    const watched: number = MemProbe.watchedSinceCheck;
    MemProbe.watchedSinceCheck = 0;
    MemProbe.lastLeakCheckAt = now;
    try {
      const leaked: string = jsLeakWatcher.check();
      if (leaked.length > 0 && leaked !== '[]') {
        // 列表可能很长，日志中心只留开头；完整内容用 hdc 看 hilog
        Logger.warn(MODULE, `MEM_LEAK watched=${watched} ` +
          `${leaked.length > 1500 ? leaked.substring(0, 1500) + '…' : leaked}`);
      } else {
        // 「检查过、没有泄漏」也要留一条，否则分不清是没泄漏还是根本没查
        Logger.info(MODULE, `MEM_LEAK_NONE watched=${watched}`);
      }
    } catch (error) {
      Logger.warn(MODULE, `jsLeakWatcher.check 失败 code=${(error as BusinessError).code}`);
    }
  }

  /**
   * 记录一次进程内存。默认节流：距上次 30 秒以上、或 JS 堆涨了 16MB 以上才记；
   * 堆用量超过上限 60% 时 5 秒即可再记，并改为 warn。
   */
  public static sample(reason: string, force: boolean = false): void {
    let heapUsedKb: number = 0;
    let heapTotalKb: number = 0;
    try {
      const vm: hidebug.VMMemoryInfo = hidebug.getAppVMMemoryInfo();
      heapUsedKb = Number(vm.heapUsed);
      heapTotalKb = Number(vm.totalHeap);
    } catch (error) {
      Logger.warn(MODULE, `读取 JS 堆信息失败 code=${(error as BusinessError).code}`);
      return;
    }
    const limitKb: number = MemProbe.readHeapLimitKb();
    const high: boolean = limitKb > 0 && heapUsedKb > limitKb * HEAP_WARN_RATIO;
    const now: number = Date.now();
    const sinceLast: number = now - MemProbe.lastSampleAt;
    const due: boolean = force || sinceLast >= SAMPLE_MIN_GAP_MS ||
      heapUsedKb - MemProbe.lastHeapKb >= SAMPLE_GROWTH_KB || (high && sinceLast >= HEAP_WARN_GAP_MS);
    if (!due) {
      return;
    }
    MemProbe.lastSampleAt = now;
    MemProbe.lastHeapKb = heapUsedKb;

    const head: string = `MEM_SAMPLE reason=${reason} heap=${MemProbe.mb(heapUsedKb)}/${MemProbe.mb(heapTotalKb)}MB ` +
      `limit=${limitKb > 0 ? MemProbe.mb(limitKb) : '?'}MB`;
    const tail: string = `live=${MemProbe.describe(MemProbe.live)} created=${MemProbe.describe(MemProbe.created)}`;
    if (MemProbe.nativePending) {
      MemProbe.emit(high, `${head} ${tail}`);
      return;
    }
    MemProbe.nativePending = true;
    MemProbe.readProcessMemory().then((native: string): void => {
      MemProbe.nativePending = false;
      MemProbe.emit(high, `${head} ${native} ${tail}`);
    });
  }

  /** 立即采样并检查泄漏（压测结束、调试菜单用），不受节流限制 */
  public static report(reason: string): void {
    MemProbe.sample(reason, true);
    MemProbe.checkLeaks(true);
  }

  private static emit(high: boolean, line: string): void {
    if (high) {
      Logger.warn(MODULE, line);
    } else {
      Logger.info(MODULE, line);
    }
  }

  /** RSS / PSS（读 smaps_rollup，SDK 要求走异步接口）与显存；任一失败只影响自己那一项 */
  private static async readProcessMemory(): Promise<string> {
    let rss: string = '?';
    let pss: string = '?';
    let gfx: string = '?';
    try {
      const native: hidebug.NativeMemInfo = await hidebug.getAppNativeMemInfoAsync();
      rss = MemProbe.mb(Number(native.rss));
      pss = MemProbe.mb(Number(native.pss));
    } catch (error) {
      Logger.warn(MODULE, `读取进程内存失败 code=${(error as BusinessError).code}`);
    }
    try {
      const graphicsKb: number = await hidebug.getGraphicsMemory();
      gfx = MemProbe.mb(graphicsKb);
    } catch (error) {
      // 部分设备不提供显存统计，不刷告警
    }
    return `rss=${rss}MB pss=${pss}MB gfx=${gfx}MB`;
  }

  private static readHeapLimitKb(): number {
    if (MemProbe.heapLimitKb >= 0) {
      return MemProbe.heapLimitKb;
    }
    try {
      MemProbe.heapLimitKb = Number(hidebug.getAppMemoryLimit().vmHeapLimit);
    } catch (error) {
      MemProbe.heapLimitKb = 0;
    }
    return MemProbe.heapLimitKb;
  }

  private static mb(kb: number): string {
    return (kb / 1024).toFixed(1);
  }

  private static describe(counts: Map<string, number>): string {
    const parts: string[] = [];
    counts.forEach((value: number, key: string): void => {
      parts.push(`${key}:${value}`);
    });
    return parts.length > 0 ? parts.join(',') : '-';
  }
}
