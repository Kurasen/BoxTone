import { MbbSpec } from '../../common/constants/AppConstants';
import { WriteSpec } from './WriteSpec';

/**
 * 每台耳机的「时间线」。
 *
 * 旧实现把这些状态分散在 ToneClient 的十来个静态字段里（冷却、沉降、协议缓存、
 * 断音频是否成功过……），读写点遍布建链、上传、保活和收尾，很难看出谁会改到谁。
 * 现在按设备地址收拢成一个对象，只由写入引擎串行访问。
 */
export class DeviceTimeline {
  private static timelines: Map<string, DeviceTimeline> = new Map<string, DeviceTimeline>();

  readonly address: string;
  /** 耳机收掉 SPP 后一段时间内会拒绝连接 */
  cooldownUntil: number = 0;
  /** 写完音效后耳机在擦闪存：这段时间不能开始新的传输 */
  settleUntil: number = 0;
  /** 上一条写入收完整包（耳机开始收尾）的时刻：间隔测试用 */
  lastFlashedAt: number = 0;
  /** 上一条活着的串口被主动关掉的时刻 */
  lastCloseAt: number = 0;
  /** 上一次主动断开音频是否成功：成功过才在建链前抢先断开 */
  releaseHint: boolean = true;
  /** 协议版本缓存：0 = 未探测 */
  protocol: number = 0;

  private constructor(address: string) {
    this.address = address;
  }

  static of(address: string): DeviceTimeline {
    const key: string = address.toUpperCase();
    const known: DeviceTimeline | undefined = DeviceTimeline.timelines.get(key);
    if (known !== undefined) {
      return known;
    }
    const created: DeviceTimeline = new DeviceTimeline(address);
    DeviceTimeline.timelines.set(key, created);
    return created;
  }

  cooldownLeft(): number {
    const left: number = this.cooldownUntil - Date.now();
    return left > 0 ? left : 0;
  }

  settleLeft(): number {
    const left: number = this.settleUntil - Date.now();
    return left > 0 ? left : 0;
  }

  /** 传输中掉线：耳机要收尾十几秒，期间拒绝连接 */
  noteLinkDown(): void {
    this.cooldownUntil = Date.now() + MbbSpec.LINK_COOLDOWN_MS;
  }

  /** 一段写入结束：开始沉降期 */
  noteFlashed(): void {
    this.lastFlashedAt = Date.now();
    this.settleUntil = this.lastFlashedAt + WriteSpec.postFlashGapMs();
  }

  noteSocketClosed(): void {
    this.lastCloseAt = Date.now();
  }
}
