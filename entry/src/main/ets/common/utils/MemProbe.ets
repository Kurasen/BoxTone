import { hidebug, jsLeakWatcher } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv } from './AppEnv';
import { Logger } from './Logger';

const MODULE: string = 'MemProbe';
/** debug 包两次常规采样的最小间隔；release 包不做常规采样，只记异常（见 sample） */
const SAMPLE_MIN_GAP_MS: number = 30000;
/** 距上次采样 JS 堆涨了这么多（KB）就不等间隔，立刻再记一条 */
const SAMPLE_GROWTH_KB: number = 16 * 1024;
/** JS 堆用量超过上限的这个比例改记 warn，并缩短采样间隔；release 包只在超过它或突增时记录 */
const HEAP_WARN_RATIO: number = 0.5;
const HEAP_WARN_GAP_MS: number = 5000;
/** debug 包泄漏检查的最小间隔：check() 会触发一次 GC，不能每次切后台都做 */
const LEAK_CHECK_GAP_MS: number = 60000;
/** 卸载后多久做第一次复查：给框架留出真正销毁节点的时间 */
const AUDIT_FIRST_MS: number = 20000;
/** 还有存活实例时，隔多久再复查一次 */
const AUDIT_REPEAT_MS: number = 60000;
/**
 * 卸载超过这么久仍然存活，记 MEM_RETAINED（真正需要排查的信号）。
 * 11-27 10:37 实测：32 个已卸载实例全部回收，但设备行、音效库空态卡要 2~3 分钟才回收
 * （推测已晋升老生代、等下一次老生代 GC），按 60 秒判会误报 5 个，所以放宽到 5 分钟。
 */
const RETAINED_AFTER_MS: number = 300000;
/** 卸载超过这么久仍然存活，记 MEM_LEAK_CONFIRMED 并停止跟踪 */
const CONFIRMED_AFTER_MS: number = 600000;
/** 最多同时跟踪的已卸载实例数 */
const TRACK_MAX: number = 300;
/**
 * 每种组件最多跟踪多少个实例，其余只计数。
 * 11-27 10:50 模拟一次卸载 1250 个 DeviceRow，按总量 300 先进先出，把更早的 GlassCard / LogPage 全挤掉了，
 * 它们最后回没回收就看不到了。按种类各留一份样本，复查结论对每种组件都成立。
 */
const TRACK_PER_KIND: number = 40;

/** 一个已卸载、等待确认是否被回收的组件实例（只有弱引用，不影响回收） */
interface TrackedUnmount {
  /** 组件名 + 提示，例如 DeviceRow(nearby)；复查时按它汇总 */
  kind: string;
  label: string;
  at: number;
  ref: WeakRef<object>;
}

/** 复查时一种组件的汇总 */
interface AuditGroup {
  reclaimed: number;
  pending: number;
  retained: number;
  oldestMs: number;
}

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
 * - 进程内存：sample() 记 JS 堆 / 上限、RSS / PSS、显存，由 EntryAbility 在前后台切换时调用。
 *   debug 包 30 秒一条；release 包只在 JS 堆比上次记录涨了 16MB、或超过上限一半时记（不挤占日志中心）。
 * - 泄漏确认（仅 debug 包）：unmount 时把组件实例交给系统 jsLeakWatcher，切后台时 check()，
 *   GC 后仍没回收的实例记 MEM_LEAK。这是「谁没被释放」的直接证据，release 包不开（check 会触发 GC）。
 *
 * 日志关键字：MEM_MOUNT / MEM_UNMOUNT / MEM_DUP / MEM_SAMPLE / MEM_AUDIT / MEM_RETAINED / MEM_LEAK_CONFIRMED。
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
  /**
   * 已卸载实例的弱引用：复查时 GC 后 deref() 为空即已回收。
   * 比单看 jsLeakWatcher.check() 的一次结果可靠——第 2、3 轮各报过 DeviceRow ×1、GlassCard ×2，
   * 都只有卸载后几秒的一次观测，分不清「框架还没来得及销毁」和「真的被挂住」。这里按卸载后存活多久来判。
   */
  private static tracked: TrackedUnmount[] = [];
  /** 超出每种上限、没进跟踪的卸载实例数（按种类） */
  private static untracked: Map<string, number> = new Map<string, number>();
  /** 每种组件的卸载序号：标签用它区分同名实例（之前用 created 计数，同一批卸载的实例标签会重复） */
  private static unmounted: Map<string, number> = new Map<string, number>();
  /** MEM_DUP 上次记录时的 live：之后翻倍才再记，几百个同名实例同时挂载时不刷屏 */
  private static dupLogged: Map<string, number> = new Map<string, number>();
  private static auditTimer: number = -1;

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
      const last: number = MemProbe.dupLogged.get(name) ?? 0;
      if (live >= last * 2) {
        MemProbe.dupLogged.set(name, live);
        Logger.warn(MODULE, `MEM_DUP ${name} live=${live} max=${maxLive} created=${created}`);
      }
      return;
    }
    MemProbe.dupLogged.delete(name);
    if (verbose) {
      // 挂载 / 卸载流水只在 debug 包记；release 包里计数照样进 MEM_SAMPLE / MEM_DUP
      Logger.dev(MODULE, `MEM_MOUNT ${name} live=${live} created=${created}`);
    }
  }

  /**
   * 组件卸载。
   * @param target 组件实例（传 this）：debug 包里交给 jsLeakWatcher 并留一个弱引用，之后按存活时长判泄漏
   * @param hint 区分同名实例的提示（不含用户数据），例如 GlassCard 的样式、DeviceRow 是已配对还是附近
   */
  public static unmount(name: string, verbose: boolean = true, target?: object, hint: string = ''): void {
    const live: number = Math.max(0, (MemProbe.live.get(name) ?? 0) - 1);
    MemProbe.live.set(name, live);
    const seq: number = (MemProbe.unmounted.get(name) ?? 0) + 1;
    MemProbe.unmounted.set(name, seq);
    const label: string = `${name}#u${seq}${hint.length > 0 ? `(${hint})` : ''}`;
    if (MemProbe.leakWatching && target !== undefined) {
      try {
        jsLeakWatcher.watch(target, label);
        MemProbe.watchedSinceCheck++;
      } catch (error) {
        // 只是诊断，失败不影响业务
      }
      MemProbe.track(`${name}${hint.length > 0 ? `(${hint})` : ''}`, label, target);
    }
    // 高频组件（verbose=false）不逐条记：一次清空上千行会刷满日志中心，回收情况看 MEM_AUDIT
    if (verbose) {
      Logger.dev(MODULE, `MEM_UNMOUNT ${name} live=${live} created=${MemProbe.created.get(name) ?? 0}`);
    }
  }

  private static track(kind: string, label: string, target: object): void {
    let sameKind: number = 0;
    for (let i = 0; i < MemProbe.tracked.length; i++) {
      if (MemProbe.tracked[i].kind === kind) {
        sameKind++;
      }
    }
    if (sameKind >= TRACK_PER_KIND || MemProbe.tracked.length >= TRACK_MAX) {
      MemProbe.untracked.set(kind, (MemProbe.untracked.get(kind) ?? 0) + 1);
      return;
    }
    MemProbe.tracked.push({ kind: kind, label: label, at: Date.now(), ref: new WeakRef<object>(target) });
    MemProbe.scheduleAudit(AUDIT_FIRST_MS);
  }

  private static scheduleAudit(delayMs: number): void {
    if (MemProbe.auditTimer >= 0) {
      return;
    }
    MemProbe.auditTimer = setTimeout((): void => {
      MemProbe.auditTimer = -1;
      MemProbe.audit('timer');
    }, delayMs);
  }

  /**
   * 复查已卸载实例：先借 jsLeakWatcher.check() 触发一次 GC，再逐个 deref。
   * 结果一行 MEM_AUDIT；卸载超过 60 秒仍在的记 MEM_RETAINED，超过 10 分钟的记 MEM_LEAK_CONFIRMED 并不再跟踪。
   */
  private static audit(reason: string): void {
    if (MemProbe.tracked.length === 0) {
      Logger.info(MODULE, `MEM_AUDIT reason=${reason} 没有待复查的卸载实例`);
      return;
    }
    let watcherCount: number = -1;
    try {
      const leaked: string = jsLeakWatcher.check();
      if (leaked.length > 0) {
        const parsed: Object[] = JSON.parse(leaked) as Object[];
        watcherCount = parsed.length;
      }
    } catch (error) {
      // check 只是用来触发 GC；失败时下面的 deref 结果只代表「上一次 GC 之后」
    }
    const now: number = Date.now();
    const keep: TrackedUnmount[] = [];
    const groups: Map<string, AuditGroup> = new Map<string, AuditGroup>();
    const retained: string[] = [];
    const confirmed: string[] = [];
    for (let i = 0; i < MemProbe.tracked.length; i++) {
      const item: TrackedUnmount = MemProbe.tracked[i];
      let group: AuditGroup | undefined = groups.get(item.kind);
      if (group === undefined) {
        group = { reclaimed: 0, pending: 0, retained: 0, oldestMs: 0 };
        groups.set(item.kind, group);
      }
      if (item.ref.deref() === undefined) {
        group.reclaimed++;
        continue;
      }
      const age: number = now - item.at;
      group.oldestMs = Math.max(group.oldestMs, age);
      const text: string = `${item.label} ${Math.round(age / 1000)}s`;
      if (age >= CONFIRMED_AFTER_MS) {
        confirmed.push(text);
        continue;
      }
      if (age >= RETAINED_AFTER_MS) {
        group.retained++;
        retained.push(text);
      } else {
        group.pending++;
      }
      keep.push(item);
    }
    MemProbe.tracked = keep;
    // 一行汇总：每种组件「回收 / 待定 / 滞留，最久多少秒」，另附没进跟踪的数量
    const parts: string[] = [];
    let reclaimedAll: number = 0;
    groups.forEach((group: AuditGroup, kind: string): void => {
      reclaimedAll += group.reclaimed;
      const extra: number = MemProbe.untracked.get(kind) ?? 0;
      parts.push(`${kind} 回收${group.reclaimed}/待定${group.pending}/滞留${group.retained}` +
        `${group.oldestMs > 0 ? ` 最久${Math.round(group.oldestMs / 1000)}s` : ''}${extra > 0 ? ` 未跟踪${extra}` : ''}`);
    });
    Logger.info(MODULE, `MEM_AUDIT reason=${reason} reclaimed=${reclaimedAll} ${parts.join('; ')} watcher=${watcherCount}`);
    if (keep.length === 0) {
      // 这一批样本已全部有结论，未跟踪的计数清零，下一批重新开始
      MemProbe.untracked.clear();
    }
    if (retained.length > 0) {
      // 只列前 10 个，避免一大批同时滞留时刷屏
      Logger.warn(MODULE, `MEM_RETAINED ${retained.length} 个：${retained.slice(0, 10).join(', ')}` +
        `${retained.length > 10 ? ' …' : ''}`);
    }
    if (confirmed.length > 0) {
      Logger.warn(MODULE, `MEM_LEAK_CONFIRMED ${confirmed.length} 个：${confirmed.slice(0, 10).join(', ')}` +
        `${confirmed.length > 10 ? ' …' : ''}`);
    }
    if (keep.length > 0) {
      MemProbe.scheduleAudit(AUDIT_REPEAT_MS);
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
    // 以弱引用复查为准：它能区分「刚卸载还没销毁」和「卸载很久仍被挂住」；
    // 下面 jsLeakWatcher 原始结果的分支只在复查不可用时走到
    if (MemProbe.tracked.length > 0 || force) {
      // 切后台触发的复查同样 60 秒节流：每次复查都会触发一次 GC，测试平台 5~10 秒就切一次前后台
      if (!force && Date.now() - MemProbe.lastLeakCheckAt < LEAK_CHECK_GAP_MS) {
        return;
      }
      MemProbe.watchedSinceCheck = 0;
      MemProbe.lastLeakCheckAt = Date.now();
      MemProbe.audit(force ? 'manual' : 'bg');
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
    // release 包只记异常（堆突增、或已超上限一半），不做定时采样：测试平台每 5~10 秒切一次前后台，
    // 30 秒一条 50 分钟就是约 100 条，会挤掉日志中心（600 条）里写入引擎的诊断日志
    const periodic: boolean = AppEnv.isDebug() && sinceLast >= SAMPLE_MIN_GAP_MS;
    const growth: boolean = heapUsedKb - MemProbe.lastHeapKb >= SAMPLE_GROWTH_KB;
    const due: boolean = force || periodic || growth || (high && sinceLast >= HEAP_WARN_GAP_MS);
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
    // 先 GC 再采样：堆用量才代表「还活着的」，否则混着待回收的垃圾，前后对比没有意义
    MemProbe.collect();
    MemProbe.sample(reason, true);
    MemProbe.checkLeaks(true);
  }

  /**
   * 仅 debug 包：借 jsLeakWatcher.check() 触发一次 GC（SDK：check 返回「GC 后仍未回收」的对象，即调用会先 GC）。
   * release 包没开 jsLeakWatcher，什么都不做。
   */
  public static collect(): void {
    if (!MemProbe.leakWatching) {
      return;
    }
    try {
      jsLeakWatcher.check();
    } catch (error) {
      // 只是为了触发 GC，失败不影响采样
    }
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
