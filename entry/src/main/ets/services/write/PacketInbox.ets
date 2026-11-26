import { ByteUtils } from '../../common/utils/ByteUtils';
import { AckTimeoutError, ToneError } from '../bluetooth/ToneTypes';

/** 回包匹配条件 */
export type PacketMatcher = (packet: Uint8Array) => boolean;

/** 一个挂起的等待者 */
class Waiter {
  matcher: PacketMatcher;
  resolve: (packet: Uint8Array) => void;
  reject: (error: ToneError) => void;
  timer: number = -1;

  constructor(matcher: PacketMatcher, resolve: (packet: Uint8Array) => void, reject: (error: ToneError) => void) {
    this.matcher = matcher;
    this.resolve = resolve;
    this.reject = reject;
  }
}

/**
 * 回包收件箱。
 *
 * 旧实现用「sleep 5~15ms 轮询队列」等回执：每一窗都要白等半个轮询周期，
 * 而且链路断开、用户取消都要等下一次轮询醒来才能发现。
 * 这里改成事件驱动：包一到就唤醒匹配的等待者；链路失败或取消时 fail() 立刻唤醒全部等待者。
 *
 * 匹配规则保持旧语义：按到达顺序找第一条满足条件的包，不满足的留在队列里，
 * 因为上传过程中耳机可能先推传输事件再回命令。
 */
export class PacketInbox {
  private static readonly MAX_QUEUED: number = 512;

  private queue: Uint8Array[] = [];
  private waiters: Waiter[] = [];
  private failure: ToneError | null = null;

  /** 收到一条完整业务包 */
  push(packet: Uint8Array): void {
    if (this.failure !== null) {
      return;
    }
    for (let i = 0; i < this.waiters.length; i++) {
      const waiter: Waiter = this.waiters[i];
      if (waiter.matcher(packet)) {
        this.waiters.splice(i, 1);
        if (waiter.timer >= 0) {
          clearTimeout(waiter.timer);
        }
        waiter.resolve(packet);
        return;
      }
    }
    if (this.queue.length >= PacketInbox.MAX_QUEUED) {
      this.queue.shift();
    }
    this.queue.push(packet);
  }

  /** 等一条满足条件的包；已经到了就立刻返回 */
  wait(matcher: PacketMatcher, timeoutMs: number): Promise<Uint8Array> {
    const failed: ToneError | null = this.failure;
    if (failed !== null) {
      return Promise.reject(failed);
    }
    const queued: Uint8Array | null = this.take(matcher);
    if (queued !== null) {
      return Promise.resolve(queued);
    }
    return new Promise<Uint8Array>((resolve: (packet: Uint8Array) => void, reject: (error: ToneError) => void) => {
      const waiter: Waiter = new Waiter(matcher, resolve, reject);
      waiter.timer = setTimeout(() => {
        waiter.timer = -1;
        const index: number = this.waiters.indexOf(waiter);
        if (index >= 0) {
          this.waiters.splice(index, 1);
        }
        reject(new AckTimeoutError());
      }, Math.max(0, timeoutMs));
      this.waiters.push(waiter);
    });
  }

  /** 链路断开 / 用户取消：之后所有等待立刻以这个错误结束 */
  fail(error: ToneError): void {
    if (this.failure !== null) {
      return;
    }
    this.failure = error;
    const pending: Waiter[] = this.waiters;
    this.waiters = [];
    for (let i = 0; i < pending.length; i++) {
      if (pending[i].timer >= 0) {
        clearTimeout(pending[i].timer);
      }
      pending[i].reject(error);
    }
    this.queue = [];
  }

  /** 丢掉队列里满足条件的旧包（例如连接期耳机主动推的状态包） */
  purge(matcher: PacketMatcher): void {
    this.queue = this.queue.filter((packet: Uint8Array): boolean => !matcher(packet));
  }

  /** 清空队列但保留等待者 */
  clearQueue(): void {
    this.queue = [];
  }

  /** 超时日志里回显几条没被认领的包，帮助判断耳机到底回了什么 */
  describePending(skip: PacketMatcher, max: number = 4): string {
    const parts: string[] = [];
    for (let i = 0; i < this.queue.length && parts.length < max; i++) {
      const packet: Uint8Array = this.queue[i];
      if (skip(packet)) {
        continue;
      }
      parts.push(packet.length <= 24 ? ByteUtils.toHex(packet) :
        `${ByteUtils.toHex(packet.slice(0, 16))}…(${packet.length}B)`);
    }
    return parts.length > 0 ? parts.join('|') : 'none';
  }

  private take(matcher: PacketMatcher): Uint8Array | null {
    for (let i = 0; i < this.queue.length; i++) {
      if (matcher(this.queue[i])) {
        const packet: Uint8Array = this.queue[i];
        this.queue.splice(i, 1);
        return packet;
      }
    }
    return null;
  }
}
