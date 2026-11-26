import { describe, it, expect } from '@ohos/hypium';
import { ByteUtils } from '../main/ets/common/utils/ByteUtils';
import { MbbProtocol } from '../main/ets/services/bluetooth/MbbProtocol';
import { AckTimeoutError, CancelledError, ToneError, ToneErrorReason } from '../main/ets/services/bluetooth/ToneTypes';
import { PacketInbox } from '../main/ets/services/write/PacketInbox';
import { SppErrors } from '../main/ets/services/write/SppErrors';
import { PackageBuilder, ToneUploader } from '../main/ets/services/write/ToneUploader';
import { UploadPort, UploadReport, UploadTiming } from '../main/ets/services/write/WriteTypes';

/** 不依赖加密框架的音效包：单测只关心长度与分窗 */
const FAKE_BUILDER: PackageBuilder = (pcm: Uint8Array, name: string, mcu: Uint8Array): Uint8Array => {
  return ByteUtils.concat([pcm, mcu]);
};

function reply(service: number, command: number, fields: Uint8Array[]): Uint8Array {
  const parts: Uint8Array[] = [new Uint8Array([service, command])];
  for (let i = 0; i < fields.length; i++) {
    parts.push(fields[i]);
  }
  return ByteUtils.concat(parts);
}

/** 假耳机的结局 */
class Ending {
  /** 正常：擦写走满并补 09 06 */
  static readonly CONFIRMED: string = 'confirmed';
  /** FreeClip 2 常见：走满但不补 09 06 */
  static readonly SILENT: string = 'silent';
  /** 长音效：擦写第二阶段卡在半路 */
  static readonly STALL: string = 'stall';
  /** 数据传到一半串口被收回 */
  static readonly DROP: string = 'drop';
  /** 声明阶段就拒收格式 */
  static readonly REJECT: string = 'reject';
}

/**
 * 假耳机：按协议 2 的时序回包，用虚拟时钟（每次等不到包就把时钟拨快一个切片）。
 */
class FakeEarbud implements UploadPort {
  clock: number = 0;
  ending: string;
  chunk: number = 960;
  packageBytes: number = 0;
  receivedBytes: number = 0;
  windowOffset: number = 0;
  windows: number = 0;
  dead: boolean = false;
  preselectCalls: number = 0;
  private queue: Uint8Array[] = [];

  constructor(ending: string) {
    this.ending = ending;
  }

  send(payload: Uint8Array): Promise<void> {
    const service: number = payload[0];
    const command: number = payload[1];
    if (service === 0x09 && command === 0x01) {
      this.packageBytes = ByteUtils.intBE(payload.slice(17, 21));
      const result: number = this.ending === Ending.REJECT ? 109999 : 100000;
      this.queue.push(reply(0x09, 0x01, [MbbProtocol.field(127, ByteUtils.be32(result))]));
    } else if (service === 0x09 && command === 0x02) {
      this.queue.push(reply(0x09, 0x02, [MbbProtocol.field(3, ByteUtils.be16(this.chunk + 9))]));
    } else if (service === 0x09 && command === 0x09) {
      this.pushWindow();
    }
    return Promise.resolve();
  }

  sendWindow(payloads: Uint8Array[]): Promise<void> {
    for (let i = 0; i < payloads.length; i++) {
      // 0904 ff | offset(4) | index(1) | chunk
      this.receivedBytes += payloads[i].length - 8;
    }
    this.windows++;
    this.windowOffset += this.chunk * 8;
    if (this.ending === Ending.DROP && this.windows === 1) {
      this.dead = true;
      return Promise.resolve();
    }
    if (this.windowOffset < this.packageBytes) {
      this.pushWindow();
      return Promise.resolve();
    }
    const total: number = this.packageBytes * 2;
    this.queue.push(this.progress(total, this.packageBytes));
    if (this.ending === Ending.STALL) {
      this.queue.push(this.progress(total, Math.floor(total * 0.53)));
    } else {
      this.queue.push(this.progress(total, total));
      if (this.ending === Ending.CONFIRMED) {
        this.queue.push(new Uint8Array([0x09, 0x06]));
      }
    }
    return Promise.resolve();
  }

  chunkHint(chunkSize: number): void {
  }

  next(timeoutMs: number): Promise<Uint8Array> {
    if (this.dead) {
      return Promise.reject(SppErrors.linkLost());
    }
    const packet: Uint8Array | undefined = this.queue.shift();
    if (packet !== undefined) {
      return Promise.resolve(packet);
    }
    this.clock += timeoutMs;
    return Promise.reject(new AckTimeoutError());
  }

  preselect(): Promise<boolean> {
    this.preselectCalls++;
    return Promise.resolve(true);
  }

  idle(suppressAudio: boolean): Promise<void> {
    return Promise.resolve();
  }

  now(): number {
    return this.clock;
  }

  private pushWindow(): void {
    this.queue.push(reply(0x09, 0x03, [
      MbbProtocol.field(1, ByteUtils.be32(this.windowOffset)),
      MbbProtocol.field(3, new Uint8Array([0]))
    ]));
  }

  private progress(total: number, done: number): Uint8Array {
    return reply(0x09, 0x05, [MbbProtocol.field(1, ByteUtils.be32(total)), MbbProtocol.field(2, ByteUtils.be32(done))]);
  }
}

function fastTiming(): UploadTiming {
  const timing: UploadTiming = new UploadTiming();
  timing.totalMs = 100000;
  timing.idleMs = 100;
  timing.transferSliceMs = 10;
  timing.flushMs = 200;
  timing.flushSliceMs = 10;
  timing.confirmMs = 50;
  return timing;
}

/** 约 2.5 秒的音效（83500 字节），覆盖多窗 */
function samplePcm(): Uint8Array {
  return new Uint8Array(83500);
}

class RunResult {
  report: UploadReport | null = null;
  error: ToneError | null = null;
  ratios: number[] = [];
}

async function runUpload(earbud: FakeEarbud, uploader: ToneUploader, result: RunResult): Promise<void> {
  try {
    result.report = await uploader.run(samplePcm(), 2);
  } catch (error) {
    result.error = error as ToneError;
  }
}

function makeUploader(earbud: FakeEarbud, result: RunResult): ToneUploader {
  return new ToneUploader(earbud, fastTiming(), (line: string): void => {
  }, (ratio: number, stage: string): void => {
    result.ratios.push(ratio);
  }, FAKE_BUILDER);
}

function monotonic(values: number[]): boolean {
  for (let i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) {
      return false;
    }
  }
  return true;
}

export default function writeEngineTest() {
  describe('ToneUploader', () => {
    it('confirmed_flush', 0, async (done: Function) => {
      const earbud: FakeEarbud = new FakeEarbud(Ending.CONFIRMED);
      const result: RunResult = new RunResult();
      await runUpload(earbud, makeUploader(earbud, result), result);
      expect(result.error === null).assertTrue();
      const report: UploadReport | null = result.report;
      expect(report !== null).assertTrue();
      if (report !== null) {
        expect(report.flushConfirmed).assertTrue();
        expect(report.preselected).assertTrue();
        expect(report.receivedAll).assertTrue();
        // 包长 = PCM + 4 字节 MCU；每帧 960 字节
        expect(report.framesSent).assertEqual(Math.ceil((83500 + 4) / 960));
      }
      expect(earbud.receivedBytes).assertEqual(83500 + 4);
      expect(earbud.preselectCalls).assertEqual(1);
      expect(monotonic(result.ratios)).assertTrue();
      done();
    });

    it('silent_flush_is_unconfirmed_success', 0, async (done: Function) => {
      const earbud: FakeEarbud = new FakeEarbud(Ending.SILENT);
      const result: RunResult = new RunResult();
      await runUpload(earbud, makeUploader(earbud, result), result);
      expect(result.error === null).assertTrue();
      const report: UploadReport | null = result.report;
      expect(report !== null && !report.flushConfirmed).assertTrue();
      done();
    });

    it('stalled_flush_fails_without_retry', 0, async (done: Function) => {
      const earbud: FakeEarbud = new FakeEarbud(Ending.STALL);
      const result: RunResult = new RunResult();
      const uploader: ToneUploader = makeUploader(earbud, result);
      await runUpload(earbud, uploader, result);
      const error: ToneError | null = result.error;
      expect(error !== null).assertTrue();
      if (error !== null) {
        expect(error.reason).assertEqual(ToneErrorReason.FLUSH_TIMEOUT);
      }
      // 数据已全部送达：引擎据此不再整包重传，而是回滚
      expect(uploader.state.receivedAll).assertTrue();
      done();
    });

    it('link_drop_before_received_all_is_retryable', 0, async (done: Function) => {
      const earbud: FakeEarbud = new FakeEarbud(Ending.DROP);
      const result: RunResult = new RunResult();
      const uploader: ToneUploader = makeUploader(earbud, result);
      await runUpload(earbud, uploader, result);
      const error: ToneError | null = result.error;
      expect(error !== null).assertTrue();
      if (error !== null) {
        expect(error.reason).assertEqual(ToneErrorReason.LINK);
      }
      expect(uploader.state.receivedAll).assertFalse();
      expect(uploader.state.preselected).assertTrue();
      done();
    });

    it('format_rejected_before_any_pcm', 0, async (done: Function) => {
      const earbud: FakeEarbud = new FakeEarbud(Ending.REJECT);
      const result: RunResult = new RunResult();
      const uploader: ToneUploader = makeUploader(earbud, result);
      await runUpload(earbud, uploader, result);
      const error: ToneError | null = result.error;
      expect(error !== null).assertTrue();
      if (error !== null) {
        expect(error.reason).assertEqual(ToneErrorReason.FORMAT);
      }
      expect(uploader.state.preselected).assertFalse();
      expect(earbud.receivedBytes).assertEqual(0);
      done();
    });
  });

  describe('PacketInbox', () => {
    const isStatus: (packet: Uint8Array) => boolean = (packet: Uint8Array): boolean => packet.length >= 2 && packet[0] === 0x2b;

    it('queued_packet_resolves_immediately', 0, async (done: Function) => {
      const inbox: PacketInbox = new PacketInbox();
      inbox.push(new Uint8Array([0x09, 0x03]));
      inbox.push(new Uint8Array([0x2b, 0xb4]));
      const packet: Uint8Array = await inbox.wait(isStatus, 1000);
      expect(packet[1]).assertEqual(0xb4);
      done();
    });

    it('waiter_woken_by_push', 0, async (done: Function) => {
      const inbox: PacketInbox = new PacketInbox();
      const pending: Promise<Uint8Array> = inbox.wait(isStatus, 1000);
      inbox.push(new Uint8Array([0x2b, 0xb4]));
      const packet: Uint8Array = await pending;
      expect(packet[0]).assertEqual(0x2b);
      done();
    });

    it('fail_wakes_waiters', 0, async (done: Function) => {
      const inbox: PacketInbox = new PacketInbox();
      const pending: Promise<Uint8Array> = inbox.wait(isStatus, 60000);
      inbox.fail(new CancelledError());
      let cancelled: boolean = false;
      try {
        await pending;
      } catch (error) {
        cancelled = error instanceof CancelledError;
      }
      expect(cancelled).assertTrue();
      done();
    });

    it('timeout_rejects_with_ack_timeout', 0, async (done: Function) => {
      const inbox: PacketInbox = new PacketInbox();
      let timedOut: boolean = false;
      try {
        await inbox.wait(isStatus, 5);
      } catch (error) {
        timedOut = error instanceof AckTimeoutError;
      }
      expect(timedOut).assertTrue();
      done();
    });
  });
}
