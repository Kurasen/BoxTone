import { a2dp, connection, constant } from '@kit.ConnectivityKit';
import { MbbSpec } from '../../common/constants/AppConstants';
import { DeviceTimeline } from './DeviceTimeline';
import { SppErrors } from './SppErrors';
import { TraceSink } from './WriteTypes';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 音频通道（A2DP/HFP）的处理结果，只作诊断：
 * idle=本来没连，released=已断开，kept=系统拒绝断开且仍在连，reused=复用热会话没动过音频。
 */
export class AudioGateState {
  static readonly IDLE: string = 'idle';
  static readonly RELEASED: string = 'released';
  static readonly KEPT: string = 'kept';
  static readonly REUSED: string = 'reused';
}

/**
 * 音频通道协调。
 *
 * 鸿蒙上 SPP 和 A2DP 共用一条 ACL，系统还会周期性地把 A2DP 自动连回已配对耳机。
 * 这里集中处理「建链前松开音频」「传输/擦写期间把被连回的音频压下去」两件事，
 * 行为与旧实现逐条一致（每条都有真机日志依据，见 docs/harmonyos-api-notes.md 第 4 节）。
 */
export class AudioLink {
  private readonly address: string;
  private readonly timeline: DeviceTimeline;
  private readonly trace: TraceSink;
  private readonly cancelled: () => boolean;
  state: string = AudioGateState.IDLE;
  /** 最近一次确认音频已断开的时刻：建链日志里记「距断开多久」，用来判断失败是时序还是通道 */
  releasedAt: number = 0;

  constructor(address: string, timeline: DeviceTimeline, trace: TraceSink, cancelled: () => boolean) {
    this.address = address;
    this.timeline = timeline;
    this.trace = trace;
    this.cancelled = cancelled;
  }

  /**
   * 目标设备的 A2DP 状态：1=连着 0=没连 -1=查不到。
   * 不用全局 getProfileConnectionState()：它在链路断开后仍会回缓存值。
   */
  static a2dpStateOf(address: string): number {
    try {
      const profile: a2dp.A2dpSourceProfile = a2dp.createA2dpSrcProfile();
      const ids: string[] = profile.getConnectedDevices();
      if (ids.length === 0) {
        return 0;
      }
      for (let i = 0; i < ids.length; i++) {
        if (ids[i].length > 0 && ids[i].toUpperCase() === address.toUpperCase()) {
          return 1;
        }
      }
      // 有连接但地址对不上：系统会虚拟化地址，不能据此断言目标设备没连
      return -1;
    } catch (error) {
      return -1;
    }
  }

  private static globalProfileState(): number {
    try {
      return connection.getProfileConnectionState();
    } catch (error) {
      return -1;
    }
  }

  /** 音频通道是否还占着这台耳机；精确状态取不到时退回全局状态 */
  static linked(address: string): boolean {
    const precise: number = AudioLink.a2dpStateOf(address);
    if (precise === 1) {
      return true;
    }
    if (precise === 0) {
      return false;
    }
    return AudioLink.globalProfileState() === constant.ProfileConnectionState.STATE_CONNECTED;
  }

  isLinked(): boolean {
    return AudioLink.linked(this.address);
  }

  /**
   * 尽力断开音频通道。返回值只表示「音频是否真的断开了」，从不抛错：
   * 断不掉是要直接试串口的理由，不是终止写入的理由。
   */
  async release(): Promise<boolean> {
    this.trace(`AUDIO_STATE a2dp=${AudioLink.a2dpStateOf(this.address)} global=${AudioLink.globalProfileState()}`);
    if (!this.isLinked()) {
      this.state = AudioGateState.IDLE;
      this.trace('AUDIO_LINK_IDLE 音频通道本来就没连');
      return true;
    }
    const startedAt: number = Date.now();
    let accepted: boolean = false;
    try {
      await connection.disconnectAllowedProfiles(this.address);
      accepted = true;
      this.trace('AUDIO_LINK_RELEASE_SENT');
    } catch (error) {
      // 2900099：这条音频连接不是本应用发起的。先认领到本应用名下，再断开就能成功
      this.trace(`AUDIO_RELEASE_DENIED code=${SppErrors.codeOf(error)} ${SppErrors.messageOf(error)}`);
      try {
        await connection.connectAllowedProfiles(this.address);
        this.trace('AUDIO_ADOPT_OK 已把音频连接认领到本应用');
        await sleep(250);
        await connection.disconnectAllowedProfiles(this.address);
        accepted = true;
        this.trace('AUDIO_LINK_RELEASE_SENT adopt=true');
      } catch (adoptError) {
        this.trace(`AUDIO_ADOPT_FAIL code=${SppErrors.codeOf(adoptError)} ${SppErrors.messageOf(adoptError)}`);
      }
    }
    const dropped: boolean = accepted ? await this.waitDrop(MbbSpec.AUDIO_DROP_WAIT_MS) : false;
    if (dropped) {
      this.state = AudioGateState.RELEASED;
      this.releasedAt = Date.now();
      this.timeline.releaseHint = true;
      this.trace(`AUDIO_LINK_RELEASED ms=${Date.now() - startedAt}`);
      // profile 断开不等于 ACL 已拆完：等 1 秒再发第一枪（MbbSpec.AUDIO_SETTLE_MS）。
      // 2026-11-26 试过 2 秒：第一枪照样被拒，只是整体慢了 1 秒，见 docs/write-engine.md 9.2
      await sleep(MbbSpec.AUDIO_SETTLE_MS);
      return true;
    }
    this.state = AudioGateState.KEPT;
    this.timeline.releaseHint = false;
    this.trace('AUDIO_LINK_KEPT 音频通道仍在，改为直接尝试串口');
    return false;
  }

  /**
   * 把音频通道连回来。
   *
   * 2026-11-26 19:50 真机：上一条写完时音频被我们压下去后再没回来，下一条建链时音频是断开的，
   * 串口连续 11 次被耳机拒（每次约 500ms 的 -1，请求到了耳机）。而所有成功的建链都发生在
   * 「音频连着 → 我们断开 → 1 秒后连串口」这个顺序上。所以音频不在时先把它连回来，再走正常的断开流程。
   * 返回是否连上；连不上（例如盒盖合着）不抛错，照常去试串口。
   */
  async restore(timeoutMs: number): Promise<boolean> {
    if (this.isLinked()) {
      return true;
    }
    const startedAt: number = Date.now();
    try {
      await connection.connectAllowedProfiles(this.address);
      this.trace('AUDIO_RESTORE_SENT');
    } catch (error) {
      this.trace(`AUDIO_RESTORE_DENIED code=${SppErrors.codeOf(error)}`);
      return false;
    }
    while (Date.now() - startedAt < timeoutMs && !this.cancelled()) {
      if (this.isLinked()) {
        this.trace(`AUDIO_RESTORED ms=${Date.now() - startedAt}`);
        // 刚连上时 A2DP 还在协商，立刻断开容易被拒：留一点时间
        await sleep(500);
        return true;
      }
      await sleep(150);
    }
    this.trace(`AUDIO_RESTORE_TIMEOUT ms=${Date.now() - startedAt}`);
    return false;
  }

  /**
   * 传输/擦写期间把被系统连回来的音频按下去。
   * 只发断开，不走「先认领再断开」：认领本身会建立音频连接，擦写期间等于主动去撞闪存。
   */
  async suppress(): Promise<void> {
    try {
      await connection.disconnectAllowedProfiles(this.address);
      this.trace('AUDIO_SUPPRESSED');
    } catch (error) {
      this.trace(`AUDIO_SUPPRESS_DENIED code=${SppErrors.codeOf(error)}`);
    }
  }

  /** 等音频真的掉下来：掉链分几拍完成，要连续两次读到未连接才认账 */
  private async waitDrop(timeoutMs: number): Promise<boolean> {
    const until: number = Date.now() + timeoutMs;
    while (Date.now() < until && !this.cancelled()) {
      if (!this.isLinked()) {
        await sleep(180);
        return !this.isLinked();
      }
      await sleep(120);
    }
    return false;
  }
}
