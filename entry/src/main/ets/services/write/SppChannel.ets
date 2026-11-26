import { BusinessError } from '@kit.BasicServicesKit';
import { socket } from '@kit.ConnectivityKit';
import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { Logger } from '../../common/utils/Logger';
import { MbbProtocol, PacketAssembler } from '../bluetooth/MbbProtocol';
import { CancelledError, ToneError } from '../bluetooth/ToneTypes';
import { DeviceTimeline } from './DeviceTimeline';
import { PacketInbox, PacketMatcher } from './PacketInbox';
import { SppErrors } from './SppErrors';
import { TraceSink } from './WriteTypes';

const MODULE: string = 'SppChannel';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 一条 SPP（RFCOMM）串口。
 *
 * 只管字节：建立/关闭、收包拆帧、串行化写入。协议语义在 MbbSession 里。
 *
 * 两个关键约束：
 * 1. 写入必须串行。旧实现里保活定时器、命令和数据窗口各自调 sppWriteAsync，
 *    一条跨多次写入的帧中间可能被插进另一条帧，耳机侧会把它当成坏帧丢掉。
 *    这里所有写入都排进同一条队列，一个 payload 的所有分片写完才轮到下一个。
 * 2. 链路一旦判死（2901054 等），收件箱立刻失败，所有等待者马上醒来，
 *    不再等到下一次轮询或回执超时才发现。
 */
export class SppChannel {
  /**
   * 本进程里所有还没关掉的串口 id。
   * 用来排查「合盖也恢复不了」的卡死：如果是我们自己漏关了 socket，这里会留下 id，
   * 合盖只能重置耳机，重置不了手机这边的协议栈状态。
   */
  private static openIds: Set<number> = new Set<number>();
  /** sppConnect 超时后仍未回调的请求数：系统里可能还挂着一个出站连接 */
  private static pendingTimeouts: number = 0;
  /** 正在等挂起请求迟到回调的人：回调来了就把结果交给它，而不是直接关掉 */
  private static lateWaiter: ((id: number) => void) | null = null;
  /** 每条 sppConnect 的序号：只等「最近一次超时」的那一条，不被更早的陈年挂起干扰 */
  private static requestSeq: number = 0;
  private static hungSeq: number = 0;
  private static hungOpen: boolean = false;

  /**
   * 最近一次超时的那条请求是否还挂着。
   * 2026-11-26 20:23 真机：早先一条请求挂起后一直没回来，之后每次普通的 -1 失败都被当成「有挂起」，
   * 各等 10 秒再判卡死——其实那几次是耳机正常拒绝。所以只认最近超时的那一条。
   */
  static isHung(): boolean {
    return SppChannel.hungOpen;
  }

  /**
   * 等挂起的那条 sppConnect 迟到回调。
   * 返回值：>= 0 迟到成功、串口 id 交给调用方使用；-1 迟到失败；-2 这段时间内仍没回调。
   * 一次只允许一个等待者；超时会自动注销，之后迟到的成功连接照旧立刻关掉。
   */
  static awaitLate(timeoutMs: number): Promise<number> {
    if (!SppChannel.hungOpen) {
      return Promise.resolve(-1);
    }
    return new Promise<number>((resolve: (value: number) => void) => {
      let done: boolean = false;
      const timer: number = setTimeout(() => {
        if (done) {
          return;
        }
        done = true;
        SppChannel.lateWaiter = null;
        resolve(-2);
      }, Math.max(1, timeoutMs));
      SppChannel.lateWaiter = (id: number): void => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        resolve(id);
      };
    });
  }

  /** 诊断用：当前没关的串口与悬挂的连接请求 */
  static ledger(): string {
    const ids: number[] = Array.from(SppChannel.openIds);
    return `open=[${ids.join(',')}] pending=${SppChannel.pendingTimeouts}`;
  }

  /** 关掉本进程遗留的串口（不属于任何活跃会话）；返回关掉的数量 */
  static sweepOrphans(): number {
    const ids: number[] = Array.from(SppChannel.openIds);
    for (let i = 0; i < ids.length; i++) {
      try {
        socket.sppCloseClientSocket(ids[i]);
      } catch (error) {
        Logger.warn(MODULE, `SOCKET_SWEEP_FAIL id=${ids[i]} code=${SppErrors.codeOf(error)}`);
      }
      SppChannel.openIds.delete(ids[i]);
    }
    if (ids.length > 0) {
      Logger.warn(MODULE, `SOCKET_SWEEP 关掉遗留串口 ids=[${ids.join(',')}]`);
    }
    return ids.length;
  }

  readonly id: number;
  readonly address: string;
  readonly secure: boolean;

  private readonly timeline: DeviceTimeline;
  private readonly trace: TraceSink;
  private readonly inbox: PacketInbox = new PacketInbox();
  private readonly assembler: PacketAssembler;
  private readListener: ((data: ArrayBuffer) => void) | null = null;
  private writeTail: Promise<void> = Promise.resolve();
  private closed: boolean = false;
  private broken: boolean = false;
  private writeChunk: number = MbbSpec.SPP_WRITE_CHUNK;
  private batchWrite: boolean = true;
  private useAsyncWrite: boolean = true;
  /** 设备信息查询窗口：回包可能带 SN，这段时间不打印原始 RX */
  private muteRxUntil: number = 0;

  /** 收到的业务包数：用来判断耳机侧串口是否真的开口了 */
  rxCount: number = 0;
  lastIoAt: number = Date.now();
  /** 传输进行中：这期间掉线要记冷却（耳机要收尾十几秒） */
  transferring: boolean = false;

  constructor(id: number, address: string, secure: boolean, timeline: DeviceTimeline, trace: TraceSink) {
    this.id = id;
    this.address = address;
    this.secure = secure;
    this.timeline = timeline;
    this.trace = trace;
    this.assembler = new PacketAssembler((payload: Uint8Array): void => {
      this.rxCount++;
      this.lastIoAt = Date.now();
      // 连接后耳机会主动推 01 xx 状态包：不是业务回执，进队列只会干扰匹配
      if (payload.length === 2 && ByteUtils.byteAt(payload, 0) === 1) {
        this.trace(`RX_STATE ${ByteUtils.toHex(payload)}`);
        return;
      }
      this.inbox.push(payload);
    }, (message: string): void => {
      this.trace(`RX_ERR ${message}`);
    });
  }

  /**
   * 发起一次 sppConnect。
   * 蓝牙栈在设备无响应时可能永远不回调，所以自己加超时；超时后才回来的连接立刻关掉，避免占住串口。
   */
  static connect(address: string, secure: boolean, timeoutMs: number, neutral: boolean): Promise<number> {
    SppChannel.requestSeq++;
    const seq: number = SppChannel.requestSeq;
    return new Promise<number>((resolve: (value: number) => void, reject: (reason: ToneError) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        SppChannel.pendingTimeouts++;
        SppChannel.hungSeq = seq;
        SppChannel.hungOpen = true;
        Logger.warn(MODULE, `CONNECT_HUNG secure=${secure} ${timeoutMs}ms 无回调 ${SppChannel.ledger()}`);
        reject(new ToneError(I18n.t('toneErr.connectTimeout')));
      }, timeoutMs);
      const options: socket.SppOptions = {
        uuid: MbbSpec.SPP_UUID,
        secure: secure,
        type: socket.SppType.SPP_RFCOMM
      };
      try {
        socket.sppConnect(address, options, (error: BusinessError, id: number) => {
          if (settled) {
            SppChannel.pendingTimeouts = Math.max(0, SppChannel.pendingTimeouts - 1);
            const lateOk: boolean = error === undefined || error === null || error.code === 0;
            const latest: boolean = seq === SppChannel.hungSeq;
            if (latest) {
              SppChannel.hungOpen = false;
            }
            // 有人在等这条请求：结果交给它（成功的串口直接拿去用）
            const waiter: ((id: number) => void) | null = latest ? SppChannel.lateWaiter : null;
            if (waiter !== null) {
              SppChannel.lateWaiter = null;
              if (lateOk) {
                SppChannel.openIds.add(id);
              }
              Logger.warn(MODULE, `CONNECT_LATE ok=${lateOk} handed_over=true code=${lateOk ? 0 : error.code}`);
              waiter(lateOk ? id : -1);
              return;
            }
            // 没人等：成功就立刻关掉，否则这条串口会一直占着
            if (lateOk) {
              try {
                socket.sppCloseClientSocket(id);
              } catch (closeError) {
                Logger.warn(MODULE, '关闭迟到连接失败');
              }
            }
            Logger.warn(MODULE, `CONNECT_LATE ok=${lateOk} id=${lateOk ? id : -1} ` +
              `code=${lateOk ? 0 : error.code}`);
            return;
          }
          settled = true;
          clearTimeout(timer);
          if (error !== undefined && error !== null && error.code !== 0) {
            reject(SppErrors.describe(error, neutral));
            return;
          }
          SppChannel.openIds.add(id);
          resolve(id);
        });
      } catch (error) {
        settled = true;
        clearTimeout(timer);
        reject(SppErrors.describe(error, neutral));
      }
    });
  }

  /** 挂上读监听并按协议栈能力确定单次写入长度；失败会关掉 socket 并抛错 */
  attach(neutral: boolean): void {
    const listener: (data: ArrayBuffer) => void = (data: ArrayBuffer): void => {
      if (this.closed) {
        return;
      }
      try {
        const bytes: Uint8Array = new Uint8Array(data);
        if (Date.now() >= this.muteRxUntil) {
          this.trace(`RX ${SppChannel.shortHex(bytes)}`);
        }
        this.assembler.feed(bytes);
      } catch (error) {
        this.trace(`RX_DECODE_ERROR ${SppErrors.messageOf(error)}`);
      }
    };
    try {
      socket.on('sppRead', this.id, listener);
      this.readListener = listener;
    } catch (error) {
      this.closeSocketOnly();
      throw SppErrors.describe(error, neutral);
    }
    let max: number = 0;
    try {
      max = socket.getMaxTransmitDataSize(this.id);
    } catch (error) {
      this.trace(`MAX_TX_QUERY_FAILED code=${SppErrors.codeOf(error)}`);
    }
    this.writeChunk = max >= 256 ? Math.min(max, 8192) : MbbSpec.SPP_WRITE_CHUNK;
    this.trace(`TX_CONFIG max=${max} chunk=${this.writeChunk}`);
  }

  /** 耳机声明分包大小后，把单次写入放大到一整帧（少几次跨线程往返） */
  applyChunkHint(chunkSize: number): void {
    const frame: number = Math.min(chunkSize + 32, 8192);
    if (frame > this.writeChunk) {
      this.writeChunk = frame;
      this.trace(`TX_CONFIG chunk=${this.writeChunk} hint=${chunkSize}`);
    }
  }

  isOpen(): boolean {
    return !this.closed && !this.broken;
  }

  /**
   * 是否还能当热会话用。
   * 耳机合盖/休眠后会静默关闭 RFCOMM，而系统不会回调断开事件，太久没收发就视为失效。
   */
  isFresh(maxIdleMs: number): boolean {
    return this.isOpen() && Date.now() - this.lastIoAt < maxIdleMs;
  }

  /** 发一条 MBB 载荷：自动分帧，所有分片作为一个整体排队写出 */
  sendPayload(payload: Uint8Array, logTx: boolean): Promise<void> {
    if (logTx) {
      this.trace(`TX ${SppChannel.shortHex(payload)}`);
    }
    const frames: Uint8Array[] = MbbProtocol.frames(payload);
    return this.enqueue(async (): Promise<void> => {
      for (let i = 0; i < frames.length; i++) {
        const frame: Uint8Array = frames[i];
        let offset: number = 0;
        while (offset < frame.length) {
          const end: number = Math.min(offset + this.writeChunk, frame.length);
          await this.writeOnce(frame.slice(offset, end), false);
          offset = end;
        }
      }
    });
  }

  /**
   * 写一个分片组的若干帧。
   * 优先合并成一整块一次写出（≈7.8KB）：鸿蒙每次 sppWriteAsync 是一次跨线程往返，
   * 逐帧写会让一窗在本地就耗掉一百多毫秒。协议栈拒收大块时降级为逐帧写，并在本会话内不再尝试。
   */
  sendFrames(frames: Uint8Array[]): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (frames.length === 0) {
        return;
      }
      if (frames.length > 1 && this.batchWrite) {
        let total: number = 0;
        for (let i = 0; i < frames.length; i++) {
          total += frames[i].length;
        }
        if (total <= MbbSpec.BULK_WRITE_BYTES) {
          const merged: Uint8Array = ByteUtils.concat(frames);
          const at: number = Date.now();
          try {
            await this.writeOnce(merged, true);
            this.trace(`BULK_WRITE frames=${frames.length} bytes=${merged.length} ms=${Date.now() - at}`);
            return;
          } catch (error) {
            if (!this.isOpen()) {
              throw error as Error;
            }
            this.batchWrite = false;
            this.trace(`BULK_WRITE_FALLBACK bytes=${merged.length} code=${SppErrors.codeOf(error)}`);
          }
        }
      }
      for (let i = 0; i < frames.length; i++) {
        const frame: Uint8Array = frames[i];
        let offset: number = 0;
        while (offset < frame.length) {
          const end: number = Math.min(offset + this.writeChunk, frame.length);
          await this.writeOnce(frame.slice(offset, end), false);
          offset = end;
        }
        await sleep(MbbSpec.SPP_WRITE_GAP_MS);
      }
    });
  }

  wait(matcher: PacketMatcher, timeoutMs: number): Promise<Uint8Array> {
    return this.inbox.wait(matcher, timeoutMs);
  }

  purge(matcher: PacketMatcher): void {
    this.inbox.purge(matcher);
  }

  clearQueue(): void {
    this.inbox.clearQueue();
  }

  describePending(skip: PacketMatcher): string {
    return this.inbox.describePending(skip);
  }

  /** 在接下来 ms 毫秒内不打印原始 RX（设备信息回包可能带 SN） */
  muteRx(ms: number): void {
    this.muteRxUntil = Date.now() + ms;
  }

  /** 用户取消：等待者立刻以取消结束，socket 关闭 */
  cancel(): void {
    if (this.closed) {
      return;
    }
    this.inbox.fail(new CancelledError());
    this.close();
  }

  /** 主动关闭 */
  close(): void {
    if (this.closed) {
      return;
    }
    const wasAlive: boolean = !this.broken;
    this.closed = true;
    this.inbox.fail(SppErrors.linkLost());
    this.closeSocketOnly();
    this.assembler.reset();
    // 只有「主动关掉一条活着的链路」才需要给耳机留收尾时间；对端早没了就不必等
    if (wasAlive) {
      this.timeline.noteSocketClosed();
    }
  }

  private closeSocketOnly(): void {
    const listener: ((data: ArrayBuffer) => void) | null = this.readListener;
    this.readListener = null;
    try {
      if (listener !== null) {
        socket.off('sppRead', this.id, listener);
      }
    } catch (error) {
      Logger.warn(MODULE, '取消串口监听失败');
    }
    try {
      socket.sppCloseClientSocket(this.id);
    } catch (error) {
      Logger.warn(MODULE, `关闭串口失败 id=${this.id} code=${SppErrors.codeOf(error)}`);
    }
    SppChannel.openIds.delete(this.id);
  }

  /** 把一个写任务排进队列：前一个任务失败不影响后一个开始（但链路死了后一个会立刻失败） */
  private enqueue(task: () => Promise<void>): Promise<void> {
    const run: Promise<void> = this.writeTail.then((): Promise<void> => {
      if (this.closed) {
        return Promise.reject(new CancelledError());
      }
      if (this.broken) {
        return Promise.reject(SppErrors.linkLost());
      }
      return task();
    });
    this.writeTail = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  /**
   * 写一次串口。
   * soft 用于试探性写入（合并大块）：失败不重试、不判死，交给调用方降级。
   */
  private async writeOnce(chunk: Uint8Array, soft: boolean): Promise<void> {
    const buffer: ArrayBuffer = ByteUtils.toArrayBuffer(chunk);
    let attempt: number = 0;
    while (true) {
      if (this.closed) {
        throw new CancelledError();
      }
      try {
        if (this.useAsyncWrite) {
          await socket.sppWriteAsync(this.id, buffer);
        } else {
          socket.sppWrite(this.id, buffer);
        }
        this.lastIoAt = Date.now();
        return;
      } catch (error) {
        attempt++;
        const code: number = SppErrors.codeOf(error);
        this.trace(`WRITE_FAIL attempt=${attempt} bytes=${chunk.length} code=${code} ${SppErrors.messageOf(error)}`);
        if (attempt === 1 && this.useAsyncWrite && (code === 801 || code === 202)) {
          // 该机型没有异步写接口，退回同步写
          this.useAsyncWrite = false;
          continue;
        }
        const fatal: boolean = SppErrors.isFatalWrite(code);
        if (soft && !fatal) {
          throw error as Error;
        }
        if (attempt >= 3 || fatal) {
          this.markBroken(code);
          throw SppErrors.describe(error);
        }
        await sleep(24);
      }
    }
  }

  /** 链路判死：收件箱立刻失败，socket 关闭 */
  private markBroken(code: number): void {
    if (this.broken || this.closed) {
      return;
    }
    this.broken = true;
    if (this.transferring) {
      // 传输中掉线：耳机要收尾十几秒，这段时间拒绝新连接
      this.timeline.noteLinkDown();
      Logger.info(MODULE, `LINK_DOWN write code=${code} cooldown=${MbbSpec.LINK_COOLDOWN_MS}ms`);
    } else {
      Logger.info(MODULE, `SESSION_DROPPED 空闲期写失败 code=${code}`);
    }
    this.inbox.fail(SppErrors.linkLost());
    this.closed = true;
    this.closeSocketOnly();
    this.assembler.reset();
  }

  private static shortHex(data: Uint8Array): string {
    if (data.length <= 32) {
      return ByteUtils.toHex(data);
    }
    return `${ByteUtils.toHex(data.slice(0, 24))}…(${data.length}B)`;
  }
}
