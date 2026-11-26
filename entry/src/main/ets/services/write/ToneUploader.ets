import { I18n } from '../../common/i18n/I18n';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { MbbProtocol, ToneStatusCodec } from '../bluetooth/MbbProtocol';
import { AckTimeoutError, CancelledError, ToneError, ToneErrorReason } from '../bluetooth/ToneTypes';
import {
  StageProgress,
  TraceSink,
  UploadPort,
  UploadReport,
  UploadState,
  UploadTiming
} from './WriteTypes';

/** 音效包构造：真机用 MbbProtocol.tonePackage（含 SHA-256），单测可换成不依赖加密框架的假实现 */
export type PackageBuilder = (pcm: Uint8Array, name: string, mcu: Uint8Array) => Uint8Array;

const DEFAULT_BUILDER: PackageBuilder = (pcm: Uint8Array, name: string, mcu: Uint8Array): Uint8Array => {
  return MbbProtocol.tonePackage(pcm, name, mcu);
};

/** 耳机侧上传事件类型（协议 2 取 payload[1]，协议 1 取 TLV[1]） */
class UploadEvent {
  static readonly ACCEPTED: number = 1;
  static readonly SESSION: number = 2;
  static readonly WINDOW: number = 3;
  static readonly PROGRESS: number = 5;
  static readonly COMPLETE: number = 6;
  static readonly ERROR: number = 7;
  static readonly DONE_LEGACY: number = 10;
}

/** 擦写阶段的收尾方式 */
class FlushEnd {
  static readonly NONE: number = 0;
  static readonly CONFIRMED: number = 1;
  static readonly SILENT: number = 2;
}

/**
 * 诊断用：发出「开始传输」后多久还没等到第一个窗口就记一笔（只记日志，不影响判定）。
 * 2026-11-26 真机正常 93~451ms；21:47:02 那次握手中耳机连回音频，09 09 之后 8 秒没有任何窗口，
 * 最后以 idleMs 超时整包重来。见 docs/write-engine.md 第 12 节。
 */
const START_STALL_NOTE_MS: number = 2000;

/** 诊断用：擦写进度按这几个百分比各记一行（09 05 原始帧不再逐条打印，见 SppChannel.isProgressFrame） */
const PROGRESS_MILESTONES: number[] = [25, 50, 75];

/**
 * 音效上传状态机。
 *
 * 只依赖 UploadPort，不碰系统接口，所以能在本地单测里用「假耳机」跑完整流程。
 *
 * 协议 2（新固件，09 命令族）流程，与参考实现（OpenFreebuds）一致：
 *   09 01 声明包长 → 耳机回 09 01（credit=100000 才继续）→ 选中目标槽位
 *   → 09 02 → 耳机回分包大小 → 09 09 开始 → 耳机按窗口回 09 03（偏移 + 位图）
 *   → 我们补齐位图里缺的帧 → …… → 耳机回 09 05 进度（total = 2 × 包长）
 *   → 走满后等 09 06 最终确认，FreeClip 2 常不补 09 06，静默 confirmMs 即按「未确认成功」收尾
 *
 * 进度划分：0~8% 准备，8~50% 传输，50~95% 擦写，98% 等确认。
 */
export class ToneUploader {
  private readonly port: UploadPort;
  private readonly timing: UploadTiming;
  private readonly trace: TraceSink;
  private readonly progress: StageProgress;
  private readonly builder: PackageBuilder;
  readonly state: UploadState = new UploadState();
  private shown: number = 0;

  constructor(port: UploadPort, timing: UploadTiming, trace: TraceSink, progress: StageProgress,
    builder: PackageBuilder = DEFAULT_BUILDER) {
    this.port = port;
    this.timing = timing;
    this.trace = trace;
    this.progress = progress;
    this.builder = builder;
  }

  /** 进度只能向前：传输与擦写各自到 100% 会互相覆盖，统一做单调收敛 */
  private emit(value: number, stage: string): void {
    const bounded: number = value > 1 ? 1 : (value < 0 ? 0 : value);
    if (bounded <= this.shown) {
      return;
    }
    this.shown = bounded;
    this.progress(bounded, stage);
  }

  async run(pcm: Uint8Array, protocol: number): Promise<UploadReport> {
    let data: Uint8Array = this.builder(pcm, 'Whistle', new Uint8Array(4));
    const report: UploadReport = new UploadReport();
    report.protocol = protocol;
    const started: number = this.port.now();
    this.trace(`UPLOAD_BEGIN protocol=${protocol} pcm=${pcm.length} package=${data.length}`);
    this.emit(0.08, I18n.t('stage.prepare'));

    if (protocol === 1) {
      await this.port.send(ByteUtils.fromHex('2bb6010101'));
    } else {
      await this.port.send(ByteUtils.concat([
        ByteUtils.fromHex('0901010101020200000301000601040904'),
        ByteUtils.be32(data.length),
        ByteUtils.fromHex('0a0100')
      ]));
    }
    this.state.declared = true;

    let chunkSize: number = 0;
    let written: number = 0;
    let flushTotal: number = 0;
    let lastAckAt: number = 0;
    /** 是否已收到过窗口回执：不能拿 lastAckAt === 0 当哨兵，单测里的虚拟时钟就是从 0 开始的 */
    let acked: boolean = false;
    let lastProgressAt: number = started;
    let lastPacketAt: number = started;
    let receivedAt: number = 0;
    let flushedAt: number = 0;
    /** 擦写进度是否已走满：同理不用 flushedAt === 0 当哨兵 */
    let flushFull: boolean = false;
    let flushEnd: number = FlushEnd.NONE;
    let completed: boolean = false;
    /** 发出「开始传输」命令的时刻；是否已发看 startSent，不拿 0 当哨兵（理由同 acked） */
    let startSentAt: number = 0;
    let startSent: boolean = false;
    let stallNoted: boolean = false;
    let windows: number = 0;
    let milestone: number = 0;

    while (!completed) {
      if (this.port.now() - started > this.timing.totalMs) {
        throw new ToneError(I18n.t('toneErr.timeout'));
      }
      let packet: Uint8Array | null = null;
      if (this.state.receivedAll) {
        // 擦写阶段：只等静默超时；音频被连回就压住，压不住也让耳机自己继续写
        try {
          packet = await this.port.next(this.timing.flushSliceMs);
        } catch (error) {
          if (!(error instanceof AckTimeoutError)) {
            if (error instanceof CancelledError) {
              throw error as Error;
            }
            // 擦写中链路断开：数据已全部送达，按擦写未完成处理，不再整包重传
            throw this.flushAborted(data.length, receivedAt - started, written, flushTotal);
          }
          await this.port.idle(!flushFull);
          const now: number = this.port.now();
          if (flushFull && now >= flushedAt + this.timing.confirmMs) {
            this.emit(0.99, I18n.t('stage.confirming'));
            this.trace('UPLOAD_FLUSH_SILENT 100% 后未再收到 09 06，按未确认成功返回');
            flushEnd = FlushEnd.SILENT;
            completed = true;
            continue;
          }
          if (now - lastProgressAt > this.timing.flushMs) {
            this.trace(`FLUSH_TIMEOUT_PROGRESS 停在 ${written}/${flushTotal}，静默超时`);
            throw this.flushAborted(data.length, receivedAt - started, written, flushTotal);
          }
          continue;
        }
      } else {
        try {
          packet = await this.port.next(this.timing.transferSliceMs);
        } catch (error) {
          if (!(error instanceof AckTimeoutError)) {
            throw error as Error;
          }
          const waitedFrom: number = this.port.now();
          if (startSent && !acked && !stallNoted && waitedFrom - startSentAt >= START_STALL_NOTE_MS) {
            stallNoted = true;
            this.trace(`UPLOAD_START_STALL ${waitedFrom - startSentAt}ms 未收到第一个窗口`);
          }
          await this.port.idle(true);
          if (this.port.now() - lastPacketAt > this.timing.idleMs) {
            const now: number = this.port.now();
            this.trace(`UPLOAD_IDLE_TIMEOUT stage=${acked ? 'transfer' : (startSent ? 'start' : 'handshake')} ` +
              `idle=${now - lastPacketAt}ms windows=${windows}` +
              (startSent ? ` sinceStart=${now - startSentAt}ms` : ''));
            throw error as Error;
          }
          continue;
        }
      }
      if (packet === null) {
        continue;
      }
      lastPacketAt = this.port.now();

      const fields: Map<number, Uint8Array> = MbbProtocol.tlv(packet);
      const typeField: Uint8Array | undefined = fields.get(1);
      const type: number = protocol === 1
        ? (typeField !== undefined ? ByteUtils.byteAt(typeField, 0) : -1)
        : ByteUtils.byteAt(packet, 1);

      if (type === UploadEvent.ACCEPTED) {
        const resultField: Uint8Array | undefined = protocol === 1 ? fields.get(2) : fields.get(127);
        const result: number = resultField !== undefined && resultField.length === 4 ? ByteUtils.intBE(resultField) : -1;
        if (result !== 100000) {
          if (ToneStatusCodec.isKnown(result)) {
            throw new ToneError(ToneStatusCodec.errorText(result), result);
          }
          // 这一步在任何 PCM 之前：被拒说明格式不被接受，一个字节都没落盘
          const formatError: ToneError = new ToneError(I18n.f('toneErr.formatRejected', [`${pcm.length}`]), result);
          formatError.reason = ToneErrorReason.FORMAT;
          formatError.diagnostic = `PACKAGE_BYTES=${data.length} PCM_BYTES=${pcm.length} PROTOCOL=${protocol} ` +
            `RESULT=${result}`;
          throw formatError;
        }
        if (protocol === 1) {
          const mcuField: Uint8Array | undefined = fields.get(3);
          if (mcuField === undefined || mcuField.length !== 2) {
            throw new ToneError(I18n.t('toneErr.noFormat'));
          }
          data = this.builder(pcm, 'Whistle', ByteUtils.concat([new Uint8Array(2), mcuField]));
        }
        // 先选中目标槽位再传数据（参考实现的顺序）：传完不再改动，长音效拿不到回执也不会回落默认音
        const selected: boolean = await this.port.preselect();
        this.state.preselected = selected;
        report.preselected = selected;
        if (protocol === 1) {
          await this.port.send(ByteUtils.concat([
            ByteUtils.fromHex('2bb60101020204'),
            ByteUtils.be32(data.length),
            ByteUtils.fromHex('030100')
          ]));
          startSentAt = this.port.now();
          startSent = true;
        } else {
          await this.port.send(ByteUtils.fromHex('0902'));
        }
      } else if (type === UploadEvent.SESSION) {
        if (protocol !== 2) {
          continue;
        }
        const bytes: Uint8Array | undefined = fields.get(3);
        if (bytes === undefined || bytes.length !== 2) {
          throw new ToneError(I18n.t('toneErr.noChunkSize'));
        }
        chunkSize = ((ByteUtils.byteAt(bytes, 0) << 8) | ByteUtils.byteAt(bytes, 1)) - 9;
        if (chunkSize < 1 || chunkSize > 16300) {
          throw new ToneError(I18n.t('toneErr.badChunkSize'));
        }
        this.trace(`UPLOAD_CHUNK_SIZE ${chunkSize}`);
        this.port.chunkHint(chunkSize);
        await this.port.send(ByteUtils.fromHex('0909010101'));
        startSentAt = this.port.now();
        startSent = true;
      } else if (type === UploadEvent.WINDOW) {
        const offsetField: Uint8Array | undefined = fields.get(protocol === 1 ? 2 : 1);
        if (offsetField === undefined || offsetField.length !== 4) {
          throw new ToneError(I18n.t('toneErr.noOffset'));
        }
        const offset: number = ByteUtils.intBE(offsetField);
        if (protocol === 1) {
          const bytes: Uint8Array | undefined = fields.get(5);
          if (bytes === undefined || bytes.length !== 2) {
            throw new ToneError(I18n.t('toneErr.missingChunkSize'));
          }
          chunkSize = (ByteUtils.byteAt(bytes, 0) << 8) | ByteUtils.byteAt(bytes, 1);
          this.port.chunkHint(chunkSize);
        }
        if (chunkSize < 1 || chunkSize > 16300 || offset < 0 || offset > data.length) {
          throw new ToneError(I18n.t('toneErr.badRange'));
        }
        const bitmapField: Uint8Array | undefined = fields.get(protocol === 1 ? 4 : 3);
        if (bitmapField === undefined || bitmapField.length === 0) {
          throw new ToneError(I18n.t('toneErr.noAck'));
        }
        const bitmap: number = ByteUtils.byteAt(bitmapField, 0);
        const windowAt: number = this.port.now();
        if (!acked && startSent) {
          this.trace(`UPLOAD_START_LAG ${windowAt - startSentAt}ms`);
        }
        windows++;
        const payloads: Uint8Array[] = [];
        let retx: number = 0;
        for (let index = 0; index < 8; index++) {
          const at: number = offset + index * chunkSize;
          const missing: boolean = (bitmap & (1 << index)) === 0;
          if (!missing || at >= data.length) {
            continue;
          }
          const chunk: Uint8Array = ByteUtils.slice(data, at, Math.min(at + chunkSize, data.length));
          if (protocol === 1) {
            const body: Uint8Array = ByteUtils.concat([
              ByteUtils.fromHex('ff'), offsetField, ByteUtils.be16(chunk.length), new Uint8Array([index]), chunk
            ]);
            // 协议 1 的每个分片是一条独立命令
            await this.port.send(ByteUtils.concat([ByteUtils.fromHex('2bb6010104'), MbbProtocol.field(2, body)]));
          } else {
            payloads.push(ByteUtils.concat([ByteUtils.fromHex('0904ff'), offsetField, new Uint8Array([index]), chunk]));
          }
          retx++;
          this.state.framesSent++;
        }
        if (payloads.length > 0) {
          await this.port.sendWindow(payloads);
        }
        this.trace(`UPLOAD_WINDOW offset=${offset}/${data.length} frames=${retx} bitmap=${bitmap} ` +
          `send=${this.port.now() - windowAt}ms ackLag=${acked ? windowAt - lastAckAt : -1}ms`);
        lastAckAt = this.port.now();
        acked = true;
        const sentBytes: number = Math.min(data.length, offset + chunkSize * 8);
        this.emit(0.08 + 0.42 * (sentBytes / data.length), I18n.t('stage.transfer'));
      } else if (type === UploadEvent.PROGRESS) {
        if (protocol === 2) {
          const totalField: Uint8Array | undefined = fields.get(1);
          const doneField: Uint8Array | undefined = fields.get(2);
          const total: number = totalField !== undefined && totalField.length === 4 ? ByteUtils.intBE(totalField) : 0;
          const done: number = doneField !== undefined && doneField.length === 4 ? ByteUtils.intBE(doneField) : 0;
          if (total > 0) {
            flushTotal = total;
            written = done;
            lastProgressAt = this.port.now();
            // 原始 09 05 帧不再逐条打印：只在跨过 25/50/75% 时记一行，并带上那一帧的原文以免漏掉异常字段
            let crossed: number = -1;
            while (milestone < PROGRESS_MILESTONES.length && done * 100 >= total * PROGRESS_MILESTONES[milestone]) {
              crossed = milestone;
              milestone++;
            }
            if (crossed >= 0) {
              this.trace(`UPLOAD_PROGRESS ${PROGRESS_MILESTONES[crossed]}% ${done}/${total} raw=${ByteUtils.toHex(packet)}`);
            }
            // 耳机的 total 是整包的两倍（接收 + 校验写），擦写单独一段进度
            this.emit(0.5 + 0.45 * (done / total), I18n.t('stage.flash'));
            if (!this.state.receivedAll && done >= data.length) {
              this.markReceivedAll(data.length, started);
              receivedAt = this.port.now();
            }
            if (done >= total && !flushFull) {
              // 100% 先记时刻，不立刻收工：耳机可能还要几秒才补最终 09 06
              flushedAt = this.port.now();
              flushFull = true;
              this.trace('UPLOAD_FLUSH_100 等耳机最终确认');
              this.emit(0.98, I18n.t('stage.flushing'));
            }
          }
        } else {
          const update: Uint8Array | undefined = fields.get(2);
          if (update !== undefined && update.length >= 2) {
            const stage: string = ByteUtils.byteAt(update, 0) === 2 ? I18n.t('stage.flash') : I18n.t('stage.transfer');
            const ratio: number = ByteUtils.byteAt(update, 1) / 100;
            this.emit(Math.max(0.1, Math.min(0.95, ratio)), stage);
          }
        }
      } else if (type === UploadEvent.COMPLETE) {
        if (protocol === 1) {
          const resultField: Uint8Array | undefined = fields.get(2);
          const result: number = resultField !== undefined && resultField.length === 4 ? ByteUtils.intBE(resultField) : -1;
          if (result !== 1) {
            throw new ToneError(ToneStatusCodec.errorText(result), result);
          }
          if (!this.state.receivedAll) {
            receivedAt = this.port.now();
          }
          this.markReceivedAll(data.length, started);
          flushEnd = FlushEnd.CONFIRMED;
          completed = true;
        } else if (flushFull) {
          // 100% 之后的 09 06 才是最终确认
          this.trace('UPLOAD_FLUSH_CONFIRMED 收到 09 06');
          flushEnd = FlushEnd.CONFIRMED;
          completed = true;
        } else {
          // 早到的 09 06 只代表整包收完、转入擦写：之后可能几十秒没有进度
          if (!this.state.receivedAll) {
            this.markReceivedAll(data.length, started);
            receivedAt = this.port.now();
          }
          lastProgressAt = this.port.now();
          this.emit(this.shown + 0.0001, I18n.t('stage.flushing'));
        }
      } else if (type === UploadEvent.ERROR) {
        const errorField: Uint8Array | undefined = fields.get(protocol === 1 ? 2 : 127);
        const code: number = errorField !== undefined && errorField.length === 4 ? ByteUtils.intBE(errorField) : -1;
        throw new ToneError(ToneStatusCodec.errorText(code), code);
      } else if (type === UploadEvent.DONE_LEGACY) {
        // 09 0A 紧跟声明时只是回执；真正传过数据之后再收到才是「整包收完」（老固件不补 type=5）
        if (this.state.framesSent > 0) {
          this.trace('UPLOAD_DONE_0A');
          if (!this.state.receivedAll) {
            receivedAt = this.port.now();
          }
          this.markReceivedAll(data.length, started);
          flushEnd = FlushEnd.CONFIRMED;
          completed = true;
        } else {
          this.trace('UPLOAD_EVENT_0A ignored');
        }
      }
    }

    report.packageBytes = data.length;
    report.receivedAll = this.state.receivedAll;
    report.flushConfirmed = flushEnd === FlushEnd.CONFIRMED;
    report.framesSent = this.state.framesSent;
    report.transferMs = (this.state.receivedAll ? receivedAt : this.port.now()) - started;
    report.elapsedMs = this.port.now() - started;
    this.trace(`UPLOAD_DONE bytes=${data.length} elapsed=${report.elapsedMs}ms transfer=${report.transferMs}ms ` +
      `confirm=${report.flushConfirmed ? '09 06' : 'silent'}`);
    return report;
  }

  private markReceivedAll(bytes: number, started: number): void {
    if (this.state.receivedAll) {
      return;
    }
    this.state.receivedAll = true;
    this.trace(`UPLOAD_RECEIVED_ALL bytes=${bytes} elapsed=${this.port.now() - started}ms`);
  }

  private flushAborted(bytes: number, transferMs: number, written: number, total: number): ToneError {
    const rate: number = transferMs > 0 ? Math.max(1, Math.round(bytes / transferMs)) : 0;
    const error: ToneError = new ToneError(I18n.f('toneErr.flushAborted', [`${rate}`]), -98);
    error.reason = ToneErrorReason.FLUSH_TIMEOUT;
    error.diagnostic = `FLUSH=${written}/${total} PACKAGE_BYTES=${bytes} TRANSFER_MS=${transferMs}`;
    return error;
  }
}
