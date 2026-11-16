import { BusinessError } from '@kit.BasicServicesKit';
import { connection, constant, socket } from '@kit.ConnectivityKit';
import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { Logger } from '../../common/utils/Logger';
import { MbbProtocol, PacketAssembler, ToneStatus, ToneStatusCodec } from './MbbProtocol';

const MODULE: string = 'ToneClient';

export type ToneProgress = (ratio: number, stage: string) => void;
export type ToneLog = (line: string) => void;

/** 协议层异常：code 为耳机或系统错误码，message 直接面向用户 */
export class ToneError extends Error {
  code: number;
  /** 用于在 catch 里识别协议层异常，避免依赖 instanceof */
  kind: string;
  /** 失败归类（见 ToneErrorReason），空串表示未归类；上层据此给出不同结局 */
  reason: string = '';
  /** 结构化诊断片段（能力原始数据、耳机回包的协议结果等），用于一键复制反馈 */
  diagnostic: string = '';

  constructor(message: string, code: number = 0) {
    super(message);
    this.name = 'ToneError';
    this.kind = 'tone';
    this.code = code;
  }
}

/** 耳机/固件不支持盒音自定义：是终端结局，区别于值得重试的链路问题 */
export const TONE_CODE_UNSUPPORTED: number = -96;

export class ToneErrorReason {
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly FORMAT: string = 'format';
  static readonly LINK: string = 'link';
  static readonly ACK_TIMEOUT: string = 'ackTimeout';
  static readonly FLUSH_TIMEOUT: string = 'flushTimeout';
  static readonly DATA_WRITTEN: string = 'dataWritten';
  static readonly CANCELLED: string = 'cancelled';
}

export class CancelledError extends ToneError {
  constructor() {
    super(I18n.t('toneErr.cancelled'), -99);
    this.name = 'CancelledError';
    this.reason = ToneErrorReason.CANCELLED;
  }
}

/** 回执超时：命令可能刚发出去就被耳机忽略，值得原样重发一次 */
export class AckTimeoutError extends ToneError {
  constructor() {
    super(I18n.t('toneErr.ackTimeout'), -98);
    this.name = 'AckTimeoutError';
    this.reason = ToneErrorReason.ACK_TIMEOUT;
  }
}

function isToneError(error: Object | null | undefined): boolean {
  if (error === null || error === undefined) {
    return false;
  }
  return (error as ToneError).kind === 'tone';
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 耳机音效会话。
 *
 * 传输层是经典蓝牙 RFCOMM（SPP），不是 BLE GATT：
 * 连上之后是纯字节流，帧格式由 MBB 协议自己保证；
 * 写入必须按协议栈允许的长度切片，并等待每次写完成形成背压，
 * 否则一次把几十 KB 灌进发送缓冲，真机上会表现为「写入中断 / 回执丢失」。
 */
export class ToneClient {
  /** 同一台耳机的协议版本短时间内不会变，缓存后省掉每次上传前的探测往返 */
  private static protocolCache: Map<string, number> = new Map<string, number>();
  /** 上一次真正连通的 secure 取值，避免每次都从头试一遍 */
  private static secureCache: Map<string, boolean> = new Map<string, boolean>();
  /** 上一条串口被关掉的时刻 */
  private static lastCloseAt: number = 0;
  /** 耳机收掉 SPP 通道后 15 秒内会拒绝连接，记为全局冷却 */
  private static cooldownUntil: number = 0;

  private clientSocket: number = -1;
  private address: string = '';
  private readListener: ((data: ArrayBuffer) => void) | null = null;
  private received: Uint8Array[] = [];
  private assembler: PacketAssembler;
  private closed: boolean = false;
  private broken: boolean = false;
  private retiredAt: number = 0;
  private writeChunk: number = MbbSpec.SPP_WRITE_CHUNK;
  /** 帧间空档：耳机侧接收缓冲不大，连发会丢包 */
  private writeGap: number = MbbSpec.SPP_WRITE_GAP_MS;
  private useAsyncWrite: boolean = true;
  private detailLog: boolean = false;
  private lastErrorCode: number = 0;
  private lastIoAt: number = 0;
  /** 当前链路是否为加密通道：加密通道传大包会被耳机掐断，仅作兜底与诊断用 */
  private secureLink: boolean = false;
  /** 本次连接收到的业务包数量，用于判断耳机侧串口是否真的就绪 */
  private rxCount: number = 0;
  /**
   * 传输中标记。
   * 耳机在写闪存（擦扇区）时会静默几秒，这期间绝不能插状态查询：
   * 心跳帧会被当成中止信号，链路随后必断（日志里是 2901054）。
   */
  private transferring: boolean = false;
  private keepAliveTimer: number = -1;
  /** 本次连接探测出的协议版本：0 = 未探测，1 = 2BB6 分片，2 = 09 命令族 */
  protocolUsed: number = 0;
  /** 耳机自报型号（0107 tag 15），未识别时为空串；不读取 SN 等其他字段 */
  private deviceModelCode: string = '';
  /** 型号查询窗口：0107 回包可能带 SN，这段时间不打印原始 RX */
  private infoQueryUntil: number = 0;
  /** 未收录品牌/机型：串口失败时不套用「智慧音频」等华为专属指引 */
  private neutralHints: boolean = false;

  constructor(detail: boolean = false) {
    this.detailLog = detail;
    this.assembler = new PacketAssembler((payload: Uint8Array): void => {
      this.rxCount++;
      // 连接后耳机会主动推 01 06 之类的状态包，它不是业务回执，留在队列里只会干扰匹配
      if (payload.length === 2 && ByteUtils.byteAt(payload, 0) === 1) {
        this.trace(`RX_STATE ${ToneClient.shortHex(payload)}`);
        this.lastIoAt = Date.now();
        return;
      }
      this.lastIoAt = Date.now();
      if (this.received.length >= 512) {
        this.received.shift();
      }
      this.received.push(payload);
    }, (message: string): void => {
      this.trace(`RX_ERR ${message}`);
    });
  }

  isOpen(): boolean {
    // 耳机合盖/休眠后会静默关闭 RFCOMM，而系统不会回调断开事件，超时即视为失效
    return this.clientSocket >= 0 && !this.closed && !this.broken && Date.now() - this.lastIoAt < 45000;
  }

  isRetired(): boolean {
    return this.retiredAt > 0;
  }

  /** 当前是否走了加密通道（加密通道在大包传输时容易被耳机断开） */
  isSecureLink(): boolean {
    return this.secureLink;
  }

  get errorCode(): number {
    return this.lastErrorCode;
  }

  /** 耳机自报型号，空串表示未识别；型号来自固件，用户改名不影响 */
  get deviceModel(): string {
    return this.deviceModelCode;
  }

  /** 未收录机型用中性失败提示，避免把非华为耳机误判成智慧音频占用 */
  setNeutralHints(neutral: boolean): void {
    this.neutralHints = neutral;
  }

  static cooldownLeft(): number {
    const left: number = ToneClient.cooldownUntil - Date.now();
    return left > 0 ? left : 0;
  }

  static noteLinkDown(reason: string): void {
    ToneClient.cooldownUntil = Date.now() + MbbSpec.LINK_COOLDOWN_MS;
    Logger.info(MODULE, `LINK_DOWN ${reason} cooldown=${MbbSpec.LINK_COOLDOWN_MS}ms`);
  }

  private trace(line: string): void {
    if (this.detailLog) {
      Logger.debug(MODULE, line);
    }
  }

  private static shortHex(data: Uint8Array): string {
    if (data.length <= 32) {
      return ByteUtils.toHex(data);
    }
    return `${ByteUtils.toHex(data.slice(0, 24))}…(${data.length}B)`;
  }

  private static hex8(value: number): string {
    const text: string = (value & 0xFF).toString(16);
    return text.length === 1 ? `0${text}` : text;
  }

  private static codeOf(error: Object | null | undefined): number {
    if (error === null || error === undefined) {
      return 0;
    }
    const businessError: BusinessError = error as BusinessError;
    return businessError.code !== undefined ? businessError.code : 0;
  }

  private static messageOf(error: Object | null | undefined): string {
    if (error === null || error === undefined) {
      return '';
    }
    const businessError: BusinessError = error as BusinessError;
    return businessError.message !== undefined ? businessError.message : '';
  }

  /** 系统错误码翻译：这些码是实测中会稳定出现的失败原因 */
  private static describe(error: Object | null | undefined, neutral: boolean = false): ToneError {
    if (isToneError(error)) {
      return error as ToneError;
    }
    const code: number = ToneClient.codeOf(error);
    if (code === 201) {
      return new ToneError(I18n.t('toneErr.perm'), code);
    }
    if (code === 801) {
      return new ToneError(I18n.t('toneErr.unsupportedBt'), code);
    }
    if (code === 2900001) {
      return new ToneError(I18n.t('toneErr.serviceNotReady'), code);
    }
    if (code === 2900003) {
      return new ToneError(I18n.t('toneErr.btOff'), code);
    }
    if (code === 2900004) {
      return new ToneError(I18n.t('toneErr.noSpp'), code);
    }
    if (code === 2900099) {
      return new ToneError(neutral
        ? I18n.t('toneErr.notAcceptedNeutral')
        : I18n.t('toneErr.notAccepted'), code);
    }
    if (code === 2901054) {
      return new ToneError(I18n.t('toneErr.linkLost'), code);
    }
    if (code === -1) {
      return new ToneError(neutral
        ? I18n.t('toneErr.rejectedNeutral')
        : I18n.t('toneErr.rejected'), code);
    }
    if (code === 401) {
      return new ToneError(I18n.t('toneErr.badAddress'), code);
    }
    const text: string = ToneClient.messageOf(error);
    return new ToneError(text.length > 0 ?
      I18n.f('toneErr.serialFailedWith', [text]) : I18n.t('toneErr.serialFailed'), code);
  }

  /**
   * 单次连接。
   * 蓝牙栈在设备无响应时可能永远不回调，所以自己加超时；
   * 超时后才成功的连接必须立刻关闭，否则 socket 泄漏并占住串口。
   */
  private connectOnce(address: string, secure: boolean): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void, reject: (reason: Object) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new ToneError(I18n.t('toneErr.connectTimeout')));
      }, MbbSpec.CONNECT_TIMEOUT_MS);
      const options: socket.SppOptions = {
        uuid: MbbSpec.SPP_UUID,
        secure: secure,
        type: socket.SppType.SPP_RFCOMM
      };
      try {
        socket.sppConnect(address, options, (error: BusinessError, id: number) => {
          if (settled) {
            try {
              socket.sppCloseClientSocket(id);
            } catch (closeError) {
              Logger.warn(MODULE, '关闭迟到连接失败');
            }
            return;
          }
          settled = true;
          clearTimeout(timer);
          if (error !== undefined && error !== null && error.code !== 0) {
            reject(ToneClient.describe(error, this.neutralHints));
            return;
          }
          resolve(id);
        });
      } catch (error) {
        settled = true;
        clearTimeout(timer);
        reject(ToneClient.describe(error, this.neutralHints));
      }
    });
  }

  /**
   * 建立 SPP 连接。
   *
   * 真机日志里 FreeClip 2 只接受非加密通道居多，secure=true 经常直接返回 -1，
   * 所以优先用上一次成功的取值，其余取值作为兜底。
   */
  async connect(address: string, budgetMs: number = MbbSpec.CONNECT_TOTAL_BUDGET_MS): Promise<void> {
    this.closed = false;
    this.broken = false;
    this.retiredAt = 0;
    this.lastErrorCode = 0;
    this.lastIoAt = Date.now();
    this.rxCount = 0;
    this.deviceModelCode = '';
    this.address = address;
    const startedAt: number = Date.now();
    /**
     * 通道模式顺序固定为「非加密优先」。
     *
     * 实测（FreeClip 2）：secure=true 的通道能连上、也能传前 30KB，
     * 但大包传到一半会被耳机掐掉并回 2901054（SPP IO error）。
     * 之前按"上次成功的模式"排序，导致成功/失败交替出现——
     * 因为断开 A2DP 后第一次连接必然返回 -1，第二次就轮到加密通道。
     */
    const modes: boolean[] = [false, true];
    let lastError: ToneError | null = null;
    let silentFailures: number = 0;

    // 耳机连着手机音频（A2DP/HFP）时串口基本连不上，先替用户断开
    await this.releaseAudioLink(address);

    const cooling: number = ToneClient.cooldownLeft();
    if (cooling > 0) {
      this.trace(`LINK_COOLDOWN wait=${cooling}ms`);
      const until: number = Date.now() + cooling;
      while (Date.now() < until && !this.closed) {
        /**
         * 耳机把音频通道连回来，说明它已经把上一段闪存写完、重新可用了。
         * 「合盖再开盖」正是这个时机——用户按智慧音频的习惯这么操作时，
         * 不必再白等十几秒冷却。
         */
        if (this.audioLinkUp()) {
          this.trace('LINK_COOLDOWN_SKIP 音频通道已恢复');
          break;
        }
        await sleep(Math.min(200, until - Date.now()));
      }
      if (this.closed) {
        throw new CancelledError();
      }
      this.trace(`LINK_COOLDOWN_DONE ms=${Date.now() - startedAt}`);
    }

    const deadline: number = Date.now() + budgetMs;
    const sinceClose: number = Date.now() - ToneClient.lastCloseAt;
    if (ToneClient.lastCloseAt > 0 && sinceClose < MbbSpec.SOCKET_SETTLE_MS) {
      await sleep(MbbSpec.SOCKET_SETTLE_MS - sinceClose);
    }

    for (let round = 0; round < 40; round++) {
      if (round > 0 && round % 2 === 0) {
        await this.releaseAudioLink(address);
      }
      for (let mode = 0; mode < modes.length; mode++) {
        if (this.closed) {
          throw new CancelledError();
        }
        if (Date.now() > deadline) {
          break;
        }
        if (round > 0 || mode > 0) {
          await sleep(Math.min(MbbSpec.CONNECT_RETRY_GAP_MS + round * 350, 3000));
        }
        // 同一种模式给两次机会：刚断开音频时第一次连接几乎必然被拒（-1），
        // 立刻改用加密通道反而会落进会断链的那条路
        for (let attempt = 0; attempt < 2; attempt++) {
          if (this.closed) {
            throw new CancelledError();
          }
          if (Date.now() > deadline) {
            break;
          }
          if (attempt > 0) {
            await sleep(1300);
          }
          this.trace(`CONNECT try secure=${modes[mode]} round=${round + 1} attempt=${attempt + 1}`);
          try {
            const id: number = await this.connectOnce(address, modes[mode]);
            if (this.closed) {
              socket.sppCloseClientSocket(id);
              throw new CancelledError();
            }
            this.clientSocket = id;
            this.secureLink = modes[mode];
            ToneClient.secureCache.set(address, modes[mode]);
            this.bindReader(id);
            this.resolveWriteChunk();
            this.trace(`CONNECTED id=${id} secure=${modes[mode]} chunk=${this.writeChunk} ` +
              `ms=${Date.now() - startedAt}`);

            // 等耳机先开口（连接后它会推状态包）再发第一条命令；一声不吭的连接不可用
            const readyAt: number = Date.now();
            while (this.rxCount === 0 && Date.now() - readyAt < MbbSpec.LINK_READY_TIMEOUT_MS &&
              !this.closed) {
              await sleep(30);
            }
            this.trace(`LINK_READY rx=${this.rxCount} wait=${Date.now() - readyAt}ms`);
            if (this.rxCount === 0) {
              this.closeSocket();
              silentFailures++;
              if (silentFailures >= 3) {
                this.broken = true;
                throw new ToneError(this.neutralHints
                  ? I18n.t('toneErr.noResponseNeutral')
                  : I18n.t('toneErr.noResponse'));
              }
              throw new ToneError(I18n.t('toneErr.silentReconnect'));
            }
            this.startKeepAlive();
            return;
          } catch (error) {
            if (isToneError(error) && (error as ToneError).code === -99) {
              throw error as ToneError;
            }
            const failure: ToneError = ToneClient.describe(error, this.neutralHints);
            this.lastErrorCode = failure.code;
            lastError = failure;
            this.trace(`CONNECT_FAILED secure=${modes[mode]} code=${failure.code} ${failure.message}`);
            if (this.broken) {
              throw failure;
            }
            // -1 是「还没准备好」，值得原样再来一次；其它错误直接换模式
            const transient: boolean = failure.code === -1 || failure.code === 2900099;
            if (attempt === 0 && transient) {
              continue;
            }
            if (failure.code === 2900099) {
              await sleep(1200);
            }
            break;
          }
        }
      }
      if (Date.now() > deadline) {
        break;
      }
    }
    this.broken = true;
    throw lastError !== null ? lastError as ToneError :
      new ToneError(this.neutralHints
        ? I18n.t('toneErr.cannotConnectNeutral')
        : I18n.t('toneErr.cannotConnect'));
  }

  /** 耳机是否又把音频通道连回来了 */
  private audioLinkUp(): boolean {
    try {
      return connection.getProfileConnectionState() ===
        constant.ProfileConnectionState.STATE_CONNECTED;
    } catch (error) {
      return false;
    }
  }

  /**
   * 断开耳机与手机的音频通道（A2DP/HFP）。
   * 真机上只要耳机还连着音频，sppConnect 就会一直返回 -1 或 2900099。
   */
  private async releaseAudioLink(address: string): Promise<void> {
    let state: number = -1;
    try {
      state = connection.getProfileConnectionState();
    } catch (error) {
      this.trace(`AUDIO_STATE_FAIL code=${ToneClient.codeOf(error)}`);
      return;
    }
    this.trace(`AUDIO_LINK state=${state}`);
    if (state !== constant.ProfileConnectionState.STATE_CONNECTED) {
      return;
    }
    try {
      await connection.disconnectAllowedProfiles(address);
      this.trace('AUDIO_LINK_RELEASED');
      // ACL 拆链要一点时间，立刻 sppConnect 必然拿到 -1（实测约 300ms 内）
      await sleep(1300);
    } catch (error) {
      this.trace(`AUDIO_RELEASE_FAIL code=${ToneClient.codeOf(error)} ${ToneClient.messageOf(error)}`);
    }
  }

  private bindReader(id: number): void {
    const listener: (data: ArrayBuffer) => void = (data: ArrayBuffer): void => {
      if (this.closed) {
        return;
      }
      try {
        const bytes: Uint8Array = new Uint8Array(data);
        // 0107 回包可能包含 SN：查询窗口内不记录原始 RX，只保留解析后的型号
        if (Date.now() >= this.infoQueryUntil) {
          this.trace(`RX ${ToneClient.shortHex(bytes)}`);
        }
        this.assembler.feed(bytes);
      } catch (error) {
        this.trace(`RX_DECODE_ERROR ${ToneClient.messageOf(error)}`);
      }
    };
    this.readListener = listener;
    try {
      socket.on('sppRead', id, listener);
    } catch (error) {
      try {
        socket.sppCloseClientSocket(id);
      } catch (closeError) {
        Logger.warn(MODULE, '关闭串口失败');
      }
      this.readListener = null;
      this.clientSocket = -1;
      throw ToneClient.describe(error, this.neutralHints);
    }
  }

  /** 查询协议栈建议的最大单次写入长度 */
  private resolveWriteChunk(): void {
    let max: number = 0;
    try {
      max = socket.getMaxTransmitDataSize(this.clientSocket);
    } catch (error) {
      this.trace(`MAX_TX_QUERY_FAILED code=${ToneClient.codeOf(error)}`);
    }
    if (max >= 256) {
      this.writeChunk = Math.min(max, 8192);
    } else {
      this.writeChunk = MbbSpec.SPP_WRITE_CHUNK;
    }
    this.trace(`TX_CONFIG max=${max} chunk=${this.writeChunk}`);
  }

  /**
   * 耳机声明分包大小后，把 SPP 单次写入放大到一整帧。
   * 默认的 480 会把 974 字节的帧拆成三次写，多两次往返、两个 10ms 空档，
   * 5 秒音效因此要传 7~9 秒，正好撞上耳机收回串口的时间窗。
   */
  private applyChunkSizeHint(chunkSize: number): void {
    const frame: number = Math.min(chunkSize + 32, 8192);
    if (frame <= this.writeChunk) {
      return;
    }
    this.writeChunk = frame;
    this.trace(`TX_CONFIG chunk=${this.writeChunk} hint=${chunkSize}`);
  }

  private async writeOnce(chunk: Uint8Array, paced: boolean = false): Promise<void> {
    const buffer: ArrayBuffer = ByteUtils.toArrayBuffer(chunk);
    let attempt: number = 0;
    while (true) {
      try {
        if (this.useAsyncWrite) {
          await socket.sppWriteAsync(this.clientSocket, buffer);
        } else {
          socket.sppWrite(this.clientSocket, buffer);
        }
        this.lastIoAt = Date.now();
        // 分包数据在帧与帧之间留空档：耳机接收缓冲有限，
        // 连发 8 个分包时回执位图会出现"只收到前 5 个"的丢包
        if (paced) {
          await sleep(this.writeGap);
        }
        return;
      } catch (error) {
        attempt++;
        const code: number = ToneClient.codeOf(error);
        this.trace(`WRITE_FAIL attempt=${attempt} bytes=${chunk.length} code=${code} ` +
          `${ToneClient.messageOf(error)}`);
        if (attempt === 1 && this.useAsyncWrite && (code === 801 || code === 202)) {
          // 该机型没有异步写接口，退回同步写
          this.useAsyncWrite = false;
          continue;
        }
        // 2901054 表示这条串口已经死了，重试只会多耗时间
        const fatal: boolean = code === 2901054 || code === 2900003 || code === 2900001;
        if (attempt >= 3 || fatal) {
          const failure: ToneError = ToneClient.describe(error, this.neutralHints);
          this.lastErrorCode = failure.code;
          this.broken = true;
          this.closeSocket();
          ToneClient.noteLinkDown(`write code=${code}`);
          throw failure;
        }
        await sleep(24);
      }
    }
  }

  private async send(payload: Uint8Array, bulk: boolean = false): Promise<void> {
    if (this.closed) {
      throw new CancelledError();
    }
    // 链路已死不能报“已取消”：那会把真正的原因（串口被耳机收回）盖掉
    if (this.clientSocket < 0 || this.broken) {
      const error: ToneError = new ToneError(I18n.t('toneErr.linkLost'), 2901054);
      error.reason = ToneErrorReason.LINK;
      throw error;
    }
    if (!bulk) {
      this.trace(`TX ${ToneClient.shortHex(payload)}`);
    }
    const frames: Uint8Array[] = MbbProtocol.frames(payload);
    for (let i = 0; i < frames.length; i++) {
      const frame: Uint8Array = frames[i];
      let offset: number = 0;
      while (offset < frame.length) {
        if (this.closed) {
          throw new CancelledError();
        }
        const end: number = Math.min(offset + this.writeChunk, frame.length);
        await this.writeOnce(frame.slice(offset, end), bulk);
        offset = end;
      }
    }
  }

  /**
   * 在已收到的包里找目标回执。
   * 不能「取队首、不匹配就丢」：上传过程中耳机可能先推传输事件再回命令。
   */
  private takeMatch(predicate: (packet: Uint8Array) => boolean): Uint8Array | null {
    for (let i = 0; i < this.received.length; i++) {
      if (predicate(this.received[i])) {
        const packet: Uint8Array = this.received[i];
        this.received.splice(i, 1);
        return packet;
      }
    }
    return null;
  }

  /** 重发会让耳机回多份回执，匹配成功后清掉同一命令的重复包 */
  private dropDuplicates(service: number, commandId: number): void {
    const keep: Uint8Array[] = [];
    for (let i = 0; i < this.received.length; i++) {
      const packet: Uint8Array = this.received[i];
      const duplicate: boolean = packet.length >= 2 && ByteUtils.byteAt(packet, 0) === service &&
        ByteUtils.byteAt(packet, 1) === commandId;
      if (!duplicate) {
        keep.push(packet);
      }
    }
    this.received = keep;
  }

  private async awaitPacket(timeout: number, predicate: (packet: Uint8Array) => boolean): Promise<Uint8Array> {
    const deadline: number = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (this.closed) {
        throw new CancelledError();
      }
      if (this.broken) {
        const error: ToneError = new ToneError(I18n.t('toneErr.linkDown'));
        error.reason = ToneErrorReason.LINK;
        throw error;
      }
      const packet: Uint8Array | null = this.takeMatch(predicate);
      if (packet !== null) {
        return packet;
      }
      await sleep(15);
    }
    if (this.closed) {
      throw new CancelledError();
    }
    throw new AckTimeoutError();
  }

  private pendingText(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.received.length && parts.length < 4; i++) {
      // 设备信息回包可能带 SN，不在超时日志里回显
      if (ToneClient.isDeviceInfoPacket(this.received[i])) {
        continue;
      }
      parts.push(ToneClient.shortHex(this.received[i]));
    }
    return parts.length > 0 ? parts.join('|') : 'none';
  }

  private static isDeviceInfoPacket(packet: Uint8Array): boolean {
    return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x01 && ByteUtils.byteAt(packet, 1) === 0x07;
  }

  private async command(payload: Uint8Array, timeoutMs: number = MbbSpec.ACK_TIMEOUT_MS,
    attempts: number = 2): Promise<Uint8Array> {
    const service: number = ByteUtils.byteAt(payload, 0);
    const commandId: number = ByteUtils.byteAt(payload, 1);
    const match: (packet: Uint8Array) => boolean = (packet: Uint8Array): boolean => {
      return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === service &&
        ByteUtils.byteAt(packet, 1) === commandId;
    };
    const total: number = Math.max(1, attempts);
    for (let attempt = 0; attempt < total; attempt++) {
      await this.send(payload);
      try {
        const reply: Uint8Array = await this.awaitPacket(timeoutMs, match);
        this.dropDuplicates(service, commandId);
        return reply;
      } catch (error) {
        const timeout: boolean = isToneError(error) && (error as ToneError).code === -98;
        if (timeout && attempt < total - 1) {
          this.trace(`ACK_TIMEOUT_RETRY attempt=${attempt + 1}/${total} seen=${this.pendingText()}`);
          await sleep(150);
          continue;
        }
        if (timeout) {
          this.trace(`ACK_TIMEOUT service=${ToneClient.hex8(service)} cmd=${ToneClient.hex8(commandId)} ` +
            `attempt=${attempt + 1}/${total} seen=${this.pendingText()}`);
        }
        throw error as Error;
      }
    }
    throw new AckTimeoutError();
  }

  async query(): Promise<ToneStatus> {
    // 刚建链时耳机可能丢掉第一条命令，用短超时多次重发
    const payload: Uint8Array = ByteUtils.fromHex('2bb4010110');
    return MbbProtocol.parseStatus(await this.command(payload, MbbSpec.QUERY_TIMEOUT_MS, MbbSpec.QUERY_ATTEMPTS));
  }

  /** 轻量探活：1.5 秒内拿不到状态就认为这条串口已经失效 */
  async probe(): Promise<void> {
    this.received = this.received.filter((packet: Uint8Array): boolean => {
      return !(packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x2b && ByteUtils.byteAt(packet, 1) === 0xb4);
    });
    const payload: Uint8Array = ByteUtils.fromHex('2bb4010110');
    await this.send(payload);
    await this.awaitPacket(1500, (packet: Uint8Array): boolean => {
      return packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x2b && ByteUtils.byteAt(packet, 1) === 0xb4;
    });
  }

  /**
   * 读取耳机自报型号（0107 的 15 号字段）。
   *
   * 只请求并解析型号；即使耳机把整个设备信息包回过来，SN（9/24）也直接丢弃，
   * 不写日志、不落盘、不进诊断。超时或失败返回空串，不影响盒音写入。
   */
  private async readDeviceModel(): Promise<string> {
    // 查询窗口覆盖回包到达时间：期间不打印原始 RX，避免 SN 进日志
    this.infoQueryUntil = Date.now() + 2000;
    try {
      // 0107：读取设备信息；0F 00：只请求型号字段（空值）
      const reply: Uint8Array = await this.command(ByteUtils.fromHex('01070F00'), 1200, 1);
      const modelField: Uint8Array | undefined = MbbProtocol.tlv(reply).get(15);
      if (modelField === undefined || modelField.length === 0 || modelField.length > 32) {
        return '';
      }
      const model: string = ToneClient.asciiText(modelField);
      if (model.length > 0) {
        this.trace(`DEVICE_MODEL ${model}`);
      }
      return model;
    } catch (error) {
      this.trace(`DEVICE_MODEL_FAIL code=${ToneClient.codeOf(error)}`);
      return '';
    } finally {
      // 会话里不留设备信息包：即使它带了 SN，也随解析结束一起丢掉
      this.received = this.received.filter((packet: Uint8Array): boolean => {
        return !ToneClient.isDeviceInfoPacket(packet);
      });
    }
  }

  /** 型号是 ASCII 短字符串；出现非可打印字节就当作没识别到 */
  private static asciiText(bytes: Uint8Array): string {
    let text: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const value: number = bytes[i] & 0xFF;
      if (value === 0) {
        break;
      }
      if (value < 0x20 || value > 0x7E) {
        return '';
      }
      text += String.fromCharCode(value);
    }
    return text.trim();
  }

  /** 探测固件支持哪一版音效传输协议：2 = 09 命令族，1 = 2BB6 分片 */
  private async protocolVersion(): Promise<number> {
    const cached: number | undefined = ToneClient.protocolCache.get(this.address);
    if (cached !== undefined) {
      this.trace(`PROTOCOL_CACHED ${cached}`);
      return cached;
    }
    const rawCaps: Uint8Array = await this.command(ByteUtils.fromHex('2bb30101010e0100150100'));
    // 原始能力字段全量入库：其他机型兼容性只能靠这些 tag 判断，别只留解析结果。
    // 走 info 而不是 detail：这是收集未验证机型数据的关键一行
    const capsHex: string = ByteUtils.toHex(rawCaps);
    Logger.info(MODULE, `CAPS ${capsHex}`);
    const caps: Map<number, Uint8Array> = MbbProtocol.tlv(rawCaps);
    const supported: (tag: number) => boolean = (tag: number): boolean => {
      const value: Uint8Array | undefined = caps.get(tag);
      return value !== undefined && value.length >= 2 && ByteUtils.byteAt(value, 1) === 1;
    };
    if (supported(21)) {
      ToneClient.protocolCache.set(this.address, 2);
      return 2;
    }
    if (supported(14)) {
      ToneClient.protocolCache.set(this.address, 1);
      return 1;
    }
    // 有回包但两个协议 tag 都不可用，拆开两种局面：
    // 固件明确报了能力项（值为 0）= 明确不支持；tag 缺失 = 认不出这款固件
    const declared: boolean = caps.has(21) || caps.has(14);
    const failure: ToneError = declared
      ? new ToneError(I18n.t('toneErr.unsupportedReported'), TONE_CODE_UNSUPPORTED)
      : new ToneError(I18n.t('toneErr.unknownFirmware'), TONE_CODE_UNSUPPORTED);
    failure.reason = ToneErrorReason.UNSUPPORTED;
    failure.diagnostic = `CAPS=${capsHex} declared=${declared ? 1 : 0}`;
    throw failure;
  }

  private async setTone(id: number, selected: boolean, volume: number,
    timeoutMs: number = MbbSpec.ACK_TIMEOUT_MS, attempts: number = 2): Promise<ToneStatus> {
    const clamped: number = volume < 0 ? 0 : (volume > 15 ? 15 : volume);
    const setting: Uint8Array = new Uint8Array(12);
    setting[0] = 1;
    setting[1] = 1;
    setting[2] = clamped;
    setting.set(ByteUtils.be16(id), 9);
    setting[11] = selected ? 1 : 0;
    const payload: Uint8Array = ByteUtils.concat([ByteUtils.fromHex('2bb4010110'),
      MbbProtocol.field(2, setting)]);
    const status: ToneStatus = MbbProtocol.parseStatus(await this.command(payload, timeoutMs, attempts));
    this.trace(`TONE_SET id=${id} sel=${selected} vol=${clamped} -> enabled=${status.enabled} ` +
      `master=${status.master} tone=${status.toneId} selected=${status.selected}`);
    if (!status.enabled || status.selected !== selected) {
      throw new ToneError(I18n.t('toneErr.applyFailed'));
    }
    return status;
  }

  async queryStatus(): Promise<ToneStatus> {
    return this.query();
  }

  /**
   * 只补发「选中自定义音效」。
   * 音效数据已经写进耳机、只差切换时用，避免为了一个 20 字节的命令重传 80KB。
   */
  async applyCustom(): Promise<ToneStatus> {
    const current: ToneStatus = await this.query();
    this.trace(`APPLY_CUSTOM vol=${current.volume} tone=${current.toneId} sel=${current.selected}`);
    return await this.confirmTone(current.volume);
  }

  async restoreDefault(): Promise<ToneStatus> {
    const current: ToneStatus = await this.query();
    return await this.setTone(0, false, current.volume);
  }

  /**
   * 上传自定义开盖音效。
   * 协议 1（旧固件）：0x2BB6 分片传输，bitmap 回执；
   * 协议 2（新固件）：0x09 命令族，耳机主动给出分包大小与写入进度。
   */
  async upload(pcm: Uint8Array, onProgress: ToneProgress): Promise<ToneStatus> {
    let data: Uint8Array = MbbProtocol.tonePackage(pcm);
    /**
     * 进度只能向前。
     * 传输阶段的进度按"已发送字节"，写入阶段按"已落盘字节"，
     * 两者各自到 100% 会互相覆盖（先到 92% 再掉回 50%），所以统一做单调收敛。
     */
    let shown: number = 0;
    const emit = (value: number, stage: string): void => {
      const bounded: number = value > 1 ? 1 : (value < 0 ? 0 : value);
      if (bounded <= shown) {
        return;
      }
      shown = bounded;
      onProgress(bounded, stage);
    };
    emit(0.04, I18n.t('stage.readStatus'));
    // 不预发盒内查询：FreeClip 2 经常不回包，空等还会让耳机静默关掉 RFCOMM
    const before: ToneStatus = await this.query();
    emit(0.06, I18n.t('stage.readTone'));
    // 链路已证明可用后再查型号：只读 15 号字段，失败忽略，不阻塞写入
    this.deviceModelCode = await this.readDeviceModel();
    const protocol: number = await this.protocolVersion();
    this.protocolUsed = protocol;
    this.trace(`PROTOCOL ${protocol} PCM_BYTES ${pcm.length} PACKAGE_BYTES ${data.length}`);

    emit(0.08, I18n.t('stage.prepare'));
    // 从声明音效包开始就进入传输态：整段期间不发心跳
    this.transferring = true;
    if (protocol === 1) {
      await this.send(ByteUtils.fromHex('2bb6010101'));
    } else {
      await this.send(ByteUtils.concat([
        ByteUtils.fromHex('0901010101020200000301000601040904'),
        ByteUtils.be32(data.length),
        ByteUtils.fromHex('0a0100')
      ]));
    }

    let chunkSize: number = 0;
    let completed: boolean = false;
    let sentChunks: number = 0;
    /** 数据是否已全部送达：之后只剩耳机擦写闪存，静默时间会很长 */
    let receivedAll: boolean = false;
    const started: number = Date.now();

    while (!completed) {
      if (this.closed) {
        throw new CancelledError();
      }
      if (Date.now() - started > MbbSpec.UPLOAD_TOTAL_TIMEOUT_MS) {
        throw new ToneError(I18n.t('toneErr.timeout'));
      }
      const idleTimeout: number = receivedAll ? MbbSpec.UPLOAD_FLUSH_TIMEOUT_MS : MbbSpec.UPLOAD_IDLE_TIMEOUT_MS;
      let packet: Uint8Array = new Uint8Array(0);
      try {
        packet = await this.awaitPacket(idleTimeout, (candidate: Uint8Array): boolean => {
          if (candidate.length < 2) {
            return false;
          }
          if (protocol === 1) {
            return ByteUtils.byteAt(candidate, 0) === 43 && ByteUtils.byteAt(candidate, 1) === 182;
          }
          return ByteUtils.byteAt(candidate, 0) === 9;
        });
      } catch (error) {
        if (receivedAll) {
          // 数据已完整送达，但耳机没有回报擦写完成。此时音效可能只写进去一部分，
          // 不要自动补选（会选中半个音效）；重传也没有意义，交给用户合盖重试
          const flushError: ToneError = new ToneError(I18n.t('toneErr.flushTimeout'), -98);
          flushError.reason = ToneErrorReason.FLUSH_TIMEOUT;
          throw flushError;
        }
        throw error as Error;
      }
      const fields: Map<number, Uint8Array> = MbbProtocol.tlv(packet);
      const typeField: Uint8Array | undefined = fields.get(1);
      const type: number = protocol === 1
        ? (typeField !== undefined ? ByteUtils.byteAt(typeField, 0) : -1)
        : ByteUtils.byteAt(packet, 1);
      this.trace(`UPLOAD_EVENT protocol=${protocol} type=${type}`);

      if (type === 1) {
        // 耳机确认音效包格式，协议 1 会回 MCU 信息需要重新构包
        const resultField: Uint8Array | undefined = protocol === 1 ? fields.get(2) : fields.get(127);
        const result: number = resultField !== undefined && resultField.length === 4
          ? ByteUtils.intBE(resultField) : -1;
        if (result !== 100000) {
          if (ToneStatusCodec.isKnown(result)) {
            throw new ToneError(ToneStatusCodec.errorText(result), result);
          }
          // 这一步在任何 PCM 之前：被拒说明格式不被接受，但一个字节都没落盘
          const formatError: ToneError = new ToneError(
            I18n.f('toneErr.formatRejected', [`${pcm.length}`]), result);
          formatError.reason = ToneErrorReason.FORMAT;
          formatError.diagnostic = `PACKAGE_BYTES=${data.length} PCM_BYTES=${pcm.length} ` +
            `PROTOCOL=${protocol} RESULT=${result}`;
          throw formatError;
        }
        if (protocol === 1) {
          const mcuField: Uint8Array | undefined = fields.get(3);
          if (mcuField === undefined || mcuField.length !== 2) {
            throw new ToneError(I18n.t('toneErr.noFormat'));
          }
          data = MbbProtocol.tonePackage(pcm, 'Whistle',
            ByteUtils.concat([new Uint8Array(2), mcuField]));
        }
        await this.setTone(0, false, before.volume);
        if (protocol === 1) {
          await this.send(ByteUtils.concat([
            ByteUtils.fromHex('2bb60101020204'),
            ByteUtils.be32(data.length),
            ByteUtils.fromHex('030100')
          ]));
        } else {
          await this.send(ByteUtils.fromHex('0902'));
        }
      } else if (type === 2) {
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
        this.applyChunkSizeHint(chunkSize);
        await this.send(ByteUtils.fromHex('0909010101'));
      } else if (type === 3) {
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
          this.applyChunkSizeHint(chunkSize);
        }
        if (chunkSize < 1 || chunkSize > 16300 || offset < 0 || offset > data.length) {
          throw new ToneError(I18n.t('toneErr.badRange'));
        }
        const bitmapField: Uint8Array | undefined = fields.get(protocol === 1 ? 4 : 3);
        if (bitmapField === undefined || bitmapField.length === 0) {
          throw new ToneError(I18n.t('toneErr.noAck'));
        }
        const bitmap: number = ByteUtils.byteAt(bitmapField, 0);
        for (let index = 0; index < 8; index++) {
          if (this.closed) {
            throw new CancelledError();
          }
          const at: number = offset + index * chunkSize;
          const missing: boolean = (bitmap & (1 << index)) === 0;
          if (missing && at < data.length) {
            const chunk: Uint8Array = ByteUtils.slice(data, at, Math.min(at + chunkSize, data.length));
            if (protocol === 1) {
              const payload: Uint8Array = ByteUtils.concat([
                ByteUtils.fromHex('ff'),
                offsetField,
                ByteUtils.be16(chunk.length),
                new Uint8Array([index]),
                chunk
              ]);
              await this.send(ByteUtils.concat([ByteUtils.fromHex('2bb6010104'),
                MbbProtocol.field(2, payload)]), true);
              sentChunks++;
            } else {
              await this.send(ByteUtils.concat([
                ByteUtils.fromHex('0904ff'),
                offsetField,
                new Uint8Array([index]),
                chunk
              ]), true);
              sentChunks++;
            }
          }
        }
        this.trace(`UPLOAD_CHUNKS sent=${sentChunks} offset=${offset}/${data.length} ` +
          `elapsed=${Date.now() - started}ms`);
        // 传输阶段占 8%~50%：一个分包组是 8 个 chunk，按下一次要写的偏移估算
        const sentBytes: number = Math.min(data.length, offset + chunkSize * 8);
        emit(0.08 + 0.42 * (sentBytes / data.length), I18n.t('stage.transfer'));
      } else if (type === 5) {
        if (protocol === 2) {
          const totalField: Uint8Array | undefined = fields.get(1);
          const receivedField: Uint8Array | undefined = fields.get(2);
          const total: number = totalField !== undefined && totalField.length === 4
            ? ByteUtils.intBE(totalField) : 0;
          const written: number = receivedField !== undefined && receivedField.length === 4
            ? ByteUtils.intBE(receivedField) : 0;
          if (total > 0) {
            this.trace(`UPLOAD_WRITE ${written}/${total}`);
            // 写入阶段占 50%~95%：耳机的 total 是整包的两倍（收 + 校验写），单独一段
            emit(0.5 + 0.45 * (written / total), I18n.t('stage.flash'));
            if (!receivedAll && written >= data.length) {
              receivedAll = true;
            }
            if (written >= total) {
              completed = true;
            }
          }
        } else {
          const update: Uint8Array | undefined = fields.get(2);
          if (update !== undefined && update.length >= 2) {
            const stage: string = ByteUtils.byteAt(update, 0) === 2 ?
              I18n.t('stage.flash') : I18n.t('stage.transfer');
            emit(ToneClient.range(ByteUtils.byteAt(update, 1) / 100, 0.1, 0.95), stage);
          }
        }
      } else if (type === 6) {
        if (protocol === 1) {
          const resultField: Uint8Array | undefined = fields.get(2);
          const result: number = resultField !== undefined && resultField.length === 4
            ? ByteUtils.intBE(resultField) : -1;
          if (result !== 1) {
            throw new ToneError(ToneStatusCodec.errorText(result), result);
          }
          completed = true;
        } else {
          // 协议 2 的 type=6 表示整包数据已收完，耳机转入闪存擦写。
          // 擦写大包时可能几十秒不发任何进度，按普通空闲超时处理会误判失败。
          receivedAll = true;
          Logger.info(MODULE, `UPLOAD_RECEIVED_ALL bytes=${data.length} elapsed=${Date.now() - started}ms`);
          onProgress(shown, I18n.t('stage.flushing'));
        }
      } else if (type === 7) {
        const errorField: Uint8Array | undefined = fields.get(protocol === 1 ? 2 : 127);
        const code: number = errorField !== undefined && errorField.length === 4
          ? ByteUtils.intBE(errorField) : -1;
        throw new ToneError(ToneStatusCodec.errorText(code), code);
      } else if (type === 10) {
        // 09 0A 有两个时机：紧跟 0901 声明后只是回执（此时一个分包都没发），
        // 真正传过数据之后再收到才是「整包收完」，老固件不补 type=5
        if (sentChunks > 0) {
          this.trace('UPLOAD_DONE_0A');
          completed = true;
        } else {
          this.trace('UPLOAD_EVENT_0A ignored');
        }
      }
    }

    const elapsed: number = Date.now() - started;
    Logger.info(MODULE, `UPLOAD_DONE bytes=${data.length} elapsed=${elapsed}ms ` +
      `rate=${Math.round(data.length / Math.max(1, elapsed))}KB/s chunk=${this.writeChunk}`);
    emit(0.97, I18n.t('stage.apply'));
    /**
     * 进度一满就立刻发选中命令，绝不再空等。
     *
     * 真机日志：耳机在「最后一个分包发出去」到「回报 100%」之间已经静默 2~3 秒
     * （正在擦写闪存），而它静默约 4 秒就会自己收掉 RFCOMM。
     * 原来这里固定 sleep(1500) 再去发命令，等于把静默推到 4 秒以上——
     * 所以每次都死在 98%~99%，写进去的数据其实已经完整。
     * 选中命令本身也是"写入"，重发会重置耳机的空闲计时，所以失败就贴着链路快速重试。
     */
    const status: ToneStatus = await this.confirmTone(before.volume);
    emit(1, I18n.t('stage.applied'));
    // 分片发送时用过的空档要还原，避免影响后续命令的响应速度
    this.writeGap = MbbSpec.SPP_WRITE_GAP_MS;
    this.transferring = false;
    this.retire();
    return status;
  }

  /**
   * 补发「选中自定义音效」。
   *
   * 只在同一条链路上快速重试：耳机写完音效后随时可能收掉串口，
   * 一旦链路已经断了就不要再对着死 socket 撞，
   * 直接抛出带明确指引的错误（数据其实已经写进去了）。
   */
  private async confirmTone(volume: number): Promise<ToneStatus> {
    const waits: number[] = [0, 260, 520, 900, 1400];
    let lastError: Error | null = null;
    for (let i = 0; i < waits.length; i++) {
      if (waits[i] > 0) {
        await sleep(waits[i]);
      }
      if (this.closed) {
        throw new CancelledError();
      }
      if (this.clientSocket < 0 || this.broken) {
        const writtenError: ToneError = new ToneError(I18n.t('toneErr.writtenNoSwitch'), 2901054);
        writtenError.reason = ToneErrorReason.DATA_WRITTEN;
        throw writtenError;
      }
      try {
        // 回执超时压到 1.5 秒：即使耳机忽略这次命令，也不会让链路空着超过 4 秒
        return await this.setTone(MbbSpec.TONE_CUSTOM_ID, true, volume, 1500, 1);
      } catch (error) {
        lastError = error as Error;
        this.trace(`TONE_CONFIRM_RETRY attempt=${i + 1}/${waits.length} ` +
          `${ToneClient.messageOf(error)}`);
        if (this.clientSocket < 0 || this.broken) {
          break;
        }
      }
    }
    if (this.clientSocket < 0 || this.broken) {
      const writtenError: ToneError = new ToneError(I18n.t('toneErr.writtenNoSwitch'), 2901054);
      writtenError.reason = ToneErrorReason.DATA_WRITTEN;
      throw writtenError;
    }
    throw lastError !== null ? lastError as Error
      : new ToneError(I18n.t('toneErr.applyTimeout'));
  }

  /**
   * 结束一条已用完的链路。
   * 写完音效后耳机正在刷闪存，接下来十几秒既不接受新连接也会掐掉旧通道，
   * 主动释放比留着更有用。
   */
  private retire(): void {
    this.retiredAt = Date.now();
    this.transferring = false;
    this.stopKeepAlive();
    this.closeSocket();
    ToneClient.noteLinkDown('tone applied');
  }

  /** 保活：耳机静默约 4 秒就会收掉串口，通道要一直有人说话 */
  private startKeepAlive(): void {
    this.stopKeepAlive();
    this.keepAliveTimer = setInterval(() => {
      if (this.closed || this.broken || this.clientSocket < 0) {
        this.stopKeepAlive();
        return;
      }
      if (Date.now() - this.lastIoAt < 3000) {
        return;
      }
      if (this.transferring) {
        // 传输阶段耳机可能正在擦闪存而短暂静默，此时不能插心跳
        this.trace('KEEPALIVE_SKIP transferring');
        return;
      }
      this.send(ByteUtils.fromHex('2bb4010110'), true).catch((error: Error) => {
        this.trace(`KEEPALIVE_FAIL ${ToneClient.messageOf(error)}`);
        this.stopKeepAlive();
        this.broken = true;
        ToneClient.noteLinkDown('keepalive');
      });
    }, 3000);
  }

  private stopKeepAlive(): void {
    if (this.keepAliveTimer >= 0) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
  }

  private static range(value: number, min: number, max: number): number {
    if (!Number.isFinite(value)) {
      return min;
    }
    return Math.max(min, Math.min(max, value));
  }

  private closeSocket(): void {
    this.stopKeepAlive();
    const client: number = this.clientSocket;
    const listener: ((data: ArrayBuffer) => void) | null = this.readListener;
    if (client >= 0) {
      try {
        if (listener !== null) {
          socket.off('sppRead', client, listener);
        }
      } catch (error) {
        Logger.warn(MODULE, '取消串口监听失败');
      }
      try {
        socket.sppCloseClientSocket(client);
      } catch (error) {
        Logger.warn(MODULE, '关闭串口失败');
      }
      ToneClient.lastCloseAt = Date.now();
    }
    this.clientSocket = -1;
    this.readListener = null;
  }

  /** 用户取消 / 页面退出 */
  close(): void {
    this.closed = true;
    this.closeSocket();
    this.assembler.reset();
    this.received = [];
  }
}
