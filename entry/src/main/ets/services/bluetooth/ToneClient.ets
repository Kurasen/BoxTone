import { BusinessError } from '@kit.BasicServicesKit';
import { a2dp, connection, constant, socket } from '@kit.ConnectivityKit';
import { MbbSpec } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { ByteUtils } from '../../common/utils/ByteUtils';
import { Logger } from '../../common/utils/Logger';
import { MbbProtocol, PacketAssembler, ToneStatus, ToneStatusCodec } from './MbbProtocol';
import {
  AckTimeoutError,
  CancelledError,
  isToneError,
  TONE_CODE_UNSUPPORTED,
  ToneError,
  ToneErrorReason,
  ToneProgress
} from './ToneTypes';

const MODULE: string = 'ToneClient';


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
  /** 热会话：上一次操作结束后留下的通道，供下一次操作直接复用 */
  private static session: ToneClient | null = null;
  /** 热会话的回收定时器 */
  private static sweepTimer: number = -1;
  /** 上一次主动断开音频是否成功。
   * 成功过才敢在连接前抢跑（省掉一次注定失败的请求）；失败过就退回
   * 「先试再说」的老路，免得在系统不让断开时白等一次 AUDIO_DROP_WAIT_MS。
   */
  private static releaseHint: boolean = true;
  /**
   * 闪存沉降期结束时刻。
   * 写完音效后耳机在擦闪存，这段时间内不能开始任何新传输——无论通道是否还在。
   * 做成全局而不是实例字段：万一会话已经断了，新建的连接同样要等够这段时间。
   */
  private static settleUntil: number = 0;
  /**
   * 写入结束时音频是否已经断开。
   * 只有「断过、后来又自己连回来」才说明耳机擦完闪存重新工作了；
   * 音频一直没断（系统不让断）时不能拿它当信号，否则会提前去撞慢路径。
   */
  private static settleAudioWasDown: boolean = false;

  private clientSocket: number = -1;
  private address: string = '';
  private readListener: ((data: ArrayBuffer) => void) | null = null;
  private received: Uint8Array[] = [];
  private assembler: PacketAssembler;
  private closed: boolean = false;
  private broken: boolean = false;
  private retiredAt: number = 0;
  private writeChunk: number = MbbSpec.SPP_WRITE_CHUNK;
  /** 帧间空档：耳机侧接收缓冲不大，连发会丢包（仅在整窗合并写不可用时使用） */
  private writeGap: number = MbbSpec.SPP_WRITE_GAP_MS;
  /**
   * 一个分片组的 8 帧能否合并成一次写入。
   * 协议栈拒收过大的包时自动降级为逐帧写，并在本次会话内不再尝试。
   */
  private batchWrite: boolean = true;
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
  /**
   * 本次会话对音频通道的处理结果，只作诊断：
   * idle=本来没连，released=已断开，kept=系统拒绝断开且仍在连，reused=复用了热会话没动过音频，
   * restored=传数据前主动把音频连了回来。
   * 无论取哪种值都不再单独决定成败——串口能不能建起来才算数。
   */
  private audioGate: string = 'idle';
  /** 上一次上传的擦写回执是否没走满 100%（靠静默/音频回连收的尾） */
  private flushUnconfirmed: boolean = false;
  /** 本次上传是否已经预选过目标槽位：失败时要回滚默认音，避免停在空的 100 号槽 */
  private preselected: boolean = false;

  /** 擦写是否没拿到 100% 回执：界面据此提示用户去听一下确认 */
  isFlushUnconfirmed(): boolean {
    return this.flushUnconfirmed;
  }

  /** 上传是否已经发过「选中自定义槽位」：失败清理据此决定要不要恢复默认音 */
  wasPreselected(): boolean {
    return this.preselected;
  }

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

  /** 音频通道处理结果（idle/released/kept）：写进 DEVICE_MATRIX，方便日后定位同类问题 */
  get audioGateState(): string {
    return this.audioGate;
  }

  static cooldownLeft(): number {
    const left: number = ToneClient.cooldownUntil - Date.now();
    return left > 0 ? left : 0;
  }

  /** 是否留着一条热会话（恢复音频通道时打出来，用来判断两者会不会互相挤掉） */
  static hasSession(): boolean {
    return ToneClient.session !== null;
  }

  /** 闪存沉降期还剩多久：这段时间内不能开始新的传输 */
  static settleLeft(): number {
    const left: number = ToneClient.settleUntil - Date.now();
    return left > 0 ? left : 0;
  }

  /**
   * 等闪存沉降期结束。
   * 写入时音频被断开、之后耳机自己把它连了回来，就说明擦写已经完成，可以提前走，
   * 不必死等满 15 秒（真机上这个信号大约在第 7 秒出现）。
   */
  private async waitSettle(address: string): Promise<void> {
    const left: number = ToneClient.settleLeft();
    if (left <= 0) {
      return;
    }
    this.trace(`FLASH_SETTLE wait=${left}ms`);
    const until: number = Date.now() + left;
    while (Date.now() < until && !this.closed) {
      if (ToneClient.settleAudioWasDown && this.audioLinked(address)) {
        this.trace(`FLASH_SETTLE_SKIP 音频通道已恢复，提前 ${until - Date.now()}ms`);
        return;
      }
      await sleep(Math.min(200, until - Date.now()));
    }
  }

  /**
   * 热会话到底还能不能用。
   *
   * 耳机写完闪存后会把 SPP 收掉，而沉降期内保活是停发的（插心跳会被当成中止信号），
   * 所以「socket 还开着、最近也有收发」并不等于通道可用。
   * 复用前发一条只读查询确认：失败只花几十毫秒，比拿一整包数据去撞强得多。
   */
  private async probeAlive(): Promise<boolean> {
    if (this.clientSocket < 0 || this.broken || this.closed) {
      return false;
    }
    this.dropStatusPackets();
    try {
      await this.command(ByteUtils.fromHex('2bb4010110'), MbbSpec.QUERY_TIMEOUT_MS, 1);
      return true;
    } catch (error) {
      this.trace(`SESSION_PROBE_FAIL ${ToneClient.messageOf(error)}`);
      return false;
    }
  }

  /**
   * 取一条可用的音效会话。
   *
   * 同一台耳机上一条通道还活着就直接复用：一次 sppConnect 在真机上约 3 秒
   * （系统要先做 SDP 再握手），而连续操作音效时这一步纯属重复劳动。
   * 复用不改变协议行为，只是把「建链」这件事摊到第一次操作上。
   */
  static acquire(address: string, detail: boolean = true): ToneClient {
    const pooled: ToneClient | null = ToneClient.session;
    if (pooled !== null) {
      ToneClient.session = null;
      ToneClient.cancelSweep();
      if (pooled.address === address && pooled.isOpen()) {
        Logger.info(MODULE, `SESSION_REUSE 复用热会话 idle=${Date.now() - pooled.lastIoAt}ms`);
        return pooled;
      }
      Logger.info(MODULE, 'SESSION_STALE 热会话已失效，改为重新建链');
      pooled.close();
    }
    return new ToneClient(detail);
  }

  /** 用完交还：留一段热连接给下一次用；已经坏掉或用户取消则直接关 */
  release(): void {
    if (this.closed || this.broken || this.clientSocket < 0) {
      this.close();
      return;
    }
    // 刚写完闪存：耳机随后会自己把 SPP 收掉（日志里稳定在写入后 3~7 秒），
    // 留着这条会话只会让下一次操作撞在一条死 socket 上，不如直接关
    if (ToneClient.settleLeft() > 0) {
      Logger.info(MODULE, 'SESSION_CLOSE 刚写完闪存，不保留会话');
      this.close();
      return;
    }
    this.transferring = false;
    // 旧回包留在队列里会干扰下一次的匹配（例如把上一条 TONE_SET 回执当成新回执）
    this.received = [];
    ToneClient.adopt(this);
  }

  private static adopt(client: ToneClient): void {
    const held: ToneClient | null = ToneClient.session;
    if (held !== null && held !== client) {
      held.close();
    }
    ToneClient.session = client;
    ToneClient.cancelSweep();
    ToneClient.sweepTimer = setTimeout(() => {
      ToneClient.sweepTimer = -1;
      const expired: ToneClient | null = ToneClient.session;
      ToneClient.session = null;
      if (expired !== null) {
        Logger.info(MODULE, `SESSION_EXPIRE 闲置超过 ${MbbSpec.SESSION_TTL_MS}ms，关闭串口`);
        expired.close();
      }
    }, MbbSpec.SESSION_TTL_MS);
    Logger.info(MODULE, `SESSION_KEEP ttl=${MbbSpec.SESSION_TTL_MS}ms`);
  }

  private static cancelSweep(): void {
    if (ToneClient.sweepTimer >= 0) {
      clearTimeout(ToneClient.sweepTimer);
      ToneClient.sweepTimer = -1;
    }
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
  private connectOnce(address: string, secure: boolean,
    timeoutMs: number = MbbSpec.CONNECT_TIMEOUT_MS): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void, reject: (reason: Object) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
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
   *
   * 音频通道（A2DP/HFP）只在耳机拒绝串口时才动手断开，断不掉也不算失败：
   * 双耳放回盒里、手机没有任何播放时，系统仍会把 A2DP 报成「已连接」，
   * 而 disconnectAllowedProfiles 在音频是系统自己连上的场景下经常直接回 2900099。
   * 旧版把这个回包当致命错误，于是出现「耳机在盒里、没放任何音频，
   * 却提示音频通道被占用」的死结——真正被拒的是断开音频，不是串口。
   */
  async connect(address: string, budgetMs: number = MbbSpec.CONNECT_TOTAL_BUDGET_MS): Promise<void> {
    /**
     * 热会话直接返回：串口已经开着，再走一遍 SDP 与握手只是白花 3 秒。
     * 沉降期仍然要等——那是「耳机还在擦闪存」的限制，跟通道在不在无关。
     */
    if (this.clientSocket >= 0 && !this.broken && !this.closed && this.address === address) {
      await this.waitSettle(address);
      if (this.closed) {
        throw new CancelledError();
      }
      if (await this.probeAlive()) {
        this.audioGate = 'reused';
        Logger.info(MODULE, `CONNECTED reused 复用热会话 ms=0 protocol=${this.protocolUsed}`);
        return;
      }
      // 探测失败说明这条通道已经死了（多半是写完闪存后被耳机收回）：
      // 关掉走正常建链，别拿整包数据去撞一条死 socket
      Logger.info(MODULE, 'SESSION_DEAD 热会话探测无响应，改为重新建链');
      this.broken = true;   // 让 closeSocket 不记 lastCloseAt：对端早就不在了
      this.closeSocket();
      this.received = [];
      this.assembler.reset();
    }
    this.closed = false;
    this.broken = false;
    this.retiredAt = 0;
    this.lastErrorCode = 0;
    this.lastIoAt = Date.now();
    this.rxCount = 0;
    this.deviceModelCode = '';
    this.address = address;
    this.audioGate = 'idle';
    const startedAt: number = Date.now();
    /**
     * 通道模式顺序固定「非加密优先」。
     *
     * 曾经试过「断开音频后改走加密通道优先」，真机反而更慢：
     * 14:04 那轮 secure=true 第一条失败后，第二条在 10ms 内被回 2900099，
     * 而换成 secure=false 反而一次就通。说明先失败的是时序（ACL 还在收敛），
     * 不是通道类型——换顺序只是把失败挪到另一条通道上。
     */
    const modes: boolean[] = [false, true];
    let lastError: ToneError | null = null;
    let silentFailures: number = 0;
    let audioRelinks: number = 0;
    /** 本次会话是否已经试过断开音频：只试一次，避免反复撞系统的拒绝 */
    let releaseTried: boolean = false;
    /** 下一枪是断开音频后的第一次连接：用短超时，别卡在 ACL 收敛上 */
    let probeNext: boolean = false;
    /** 音频断不开、串口也连续被拒：早点给出准确提示，别让用户白等 40 秒 */
    let deadEnd: boolean = false;
    let rejected: number = 0;

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
        if (this.audioLinked(address)) {
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

    /**
     * 闪存沉降期：刚写完一段音效，耳机正在擦写，这时候连上也发不出东西。
     * 不再死等满 15 秒：耳机把音频通道连回来就说明闪存已经写完（真机上约 7 秒）。
     */
    await this.waitSettle(address);
    if (this.closed) {
      throw new CancelledError();
    }

    /**
     * 音频还连着就先松开，别拿第一次注定失败的请求去试。
     *
     * 真机日志里音频连着时第一条 sppConnect 总是在 400~900ms 后回 -1，
     * 也就是说这一枪永远打不中。先松开再连，省掉的不只是那 0.5 秒，
     * 还包括它后面那一整个重试间隔。
     * 断开被系统拒绝也不影响流程，照样往下试——那本来就不是致命错误。
     */
    if (!releaseTried && ToneClient.releaseHint && this.audioLinked(address)) {
      releaseTried = true;
      const freed: boolean = await this.releaseAudioLink(address);
      probeNext = freed;
      if (this.closed) {
        throw new CancelledError();
      }
    }

    const deadline: number = Date.now() + budgetMs;
    const sinceClose: number = Date.now() - ToneClient.lastCloseAt;
    if (ToneClient.lastCloseAt > 0 && sinceClose < MbbSpec.SOCKET_SETTLE_MS) {
      await sleep(MbbSpec.SOCKET_SETTLE_MS - sinceClose);
    }

    for (let round = 0; round < 40; round++) {
      if (deadEnd) {
        break;
      }
      for (let mode = 0; mode < modes.length; mode++) {
        if (this.closed) {
          throw new CancelledError();
        }
        if (deadEnd || Date.now() > deadline) {
          break;
        }
        if (round > 0 || mode > 0) {
          await sleep(Math.min(MbbSpec.CONNECT_RETRY_GAP_MS + round * 200, 1500));
        }
        // 每种通道只试一次，失败立刻换另一种：真机上成功总是发生在「第 2 次尝试」，
        // 而同一种通道连打两次反而会撞 2900099
        for (let attempt = 0; attempt < MbbSpec.CONNECT_ATTEMPTS_PER_MODE; attempt++) {
          if (this.closed) {
            throw new CancelledError();
          }
          if (deadEnd || Date.now() > deadline) {
            break;
          }
          this.trace(`CONNECT try secure=${modes[mode]} round=${round + 1}`);
          // 音频还没断开时先用短超时探一次：耳机可能直接不回应，
          // 不值得为一通注定被拒的连接等满 8 秒
          const audioUp: boolean = !releaseTried && this.audioLinked(address);
          // 刚断开音频后的第一枪同样短超时：ACL 拆链未收敛时这条请求会彻底卡住
          const postRelease: boolean = probeNext;
          probeNext = false;
          try {
            const id: number = await this.connectOnce(address, modes[mode],
              audioUp ? MbbSpec.CONNECT_PROBE_TIMEOUT_MS :
                (postRelease ? MbbSpec.CONNECT_POST_RELEASE_MS : MbbSpec.CONNECT_TIMEOUT_MS));
            if (this.closed) {
              socket.sppCloseClientSocket(id);
              throw new CancelledError();
            }
            this.clientSocket = id;
            this.secureLink = modes[mode];
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
            // 只记「真的能用」的通道：14:53 那轮 secure=false 连上了却一声不吭，
            // 把它当成成功模式缓存下来会误导后续轮次
            ToneClient.secureCache.set(address, modes[mode]);
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
            // 只有「刚断开音频又被连回来」才算被别的应用抢走；
            // 音频一直没断开的情况下不算，否则耳机在盒里也会被误报成被占用
            if (this.audioGate === 'released' && this.audioLinked(address)) {
              audioRelinks++;
              this.trace(`AUDIO_RELINK ${audioRelinks}`);
              if (audioRelinks >= 2) {
                const reclaimed: ToneError = new ToneError(I18n.t('toneErr.audioReclaimed'), 2900099);
                reclaimed.reason = ToneErrorReason.LINK;
                throw reclaimed;
              }
            }
            if (this.broken) {
              throw failure;
            }
            // -1 是「还没准备好」，2900099 是「通道忙」：这两种才值得先松开音频再试一次。
            // 音频还连着时的连接超时同理——耳机被动挂着音频时可能干脆不回应。
            // 权限、地址、蓝牙开关这类错误断音频也没用，直接换模式
            const transient: boolean = failure.code === -1 || failure.code === 2900099 ||
              failure.code === 2900004 || (audioUp && failure.code === 0);
            if (!releaseTried && transient) {
              releaseTried = true;
              const freed: boolean = await this.releaseAudioLink(address);
              probeNext = freed;
              if (attempt === 0) {
                continue;
              }
              break;
            }
            if (releaseTried) {
              rejected++;
              /**
               * 音频断不开、串口又连续被拒，基本就是真的没路可走了。
               * 只在这种「音频还被占着」的局面上提前收手（约 15 秒），
               * 音频已经断开的场景仍然跑满整个预算，不抢走耳机刚唤醒时的机会。
               * 门槛必须远高于真机观察到的「第 6 次请求才开门」，否则会把成功拦在门外。
               */
              if (this.audioGate === 'kept' && rejected >= 14) {
                deadEnd = true;
                break;
              }
            }
            if (attempt === 0 && transient) {
              continue;
            }
            if (failure.code === 2900099) {
              // 只是「这条请求没被受理」，间隔已经由上面统一给足，
              // 原来额外加的 1200ms 纯属叠加（14:04 那轮因此多等了 1.7 秒）
              await sleep(300);
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
    throw this.finalLinkError(address, lastError);
  }

  /**
   * 建链彻底失败时的归因。
   * 音频通道确实还被占着，和「耳机根本没响应」是两种完全不同的处置方式，
   * 不能都笼统地报「被智慧音频占用」。
   */
  private finalLinkError(address: string, lastError: ToneError | null): ToneError {
    if (lastError === null) {
      return new ToneError(this.neutralHints
        ? I18n.t('toneErr.cannotConnectNeutral')
        : I18n.t('toneErr.cannotConnect'));
    }
    if (this.audioGate === 'kept' && this.audioLinked(address)) {
      const held: ToneError = new ToneError(I18n.t('toneErr.audioHeld'),
        lastError.code !== 0 ? lastError.code : 2900099);
      held.reason = ToneErrorReason.AUDIO_HELD;
      held.diagnostic = `AUDIO_GATE=kept last_code=${lastError.code}`;
      return held;
    }
    if (lastError.code === 2900099) {
      const notAccepted: ToneError = new ToneError(this.neutralHints
        ? I18n.t('toneErr.notAcceptedNeutral')
        : I18n.t('toneErr.notAccepted'), 2900099);
      notAccepted.reason = ToneErrorReason.LINK;
      return notAccepted;
    }
    return lastError;
  }

  /**
   * 目标设备的 A2DP 到底连没连：1=连着 0=没连 -1=查不到。
   * 不用全局 getProfileConnectionState()：它在链路断开后仍会回缓存值，
   * 耳机放进盒里、早就没有音频通道时它依然报「已连接」。
   */
  private static a2dpStateOf(address: string): number {
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
      // 有 A2DP 连接但地址对不上：系统会虚拟化地址，不能据此断言目标设备没连
      return -1;
    } catch (error) {
      return -1;
    }
  }

  /** 全局 profile 状态：只作兜底与诊断，耳机放进盒里后它仍会回缓存值 */
  private static globalProfileState(): number {
    try {
      return connection.getProfileConnectionState();
    } catch (error) {
      return -1;
    }
  }

  /** 音频通道是否还占着这台耳机；精确状态取不到时退回全局状态 */
  private audioLinked(address: string): boolean {
    const precise: number = ToneClient.a2dpStateOf(address);
    if (precise === 1) {
      return true;
    }
    if (precise === 0) {
      return false;
    }
    return ToneClient.globalProfileState() === constant.ProfileConnectionState.STATE_CONNECTED;
  }

  /**
   * 尽力断开耳机与手机的音频通道（A2DP/HFP）。
   *
   * 返回值只表示「音频是否真的断开了」，不再抛错：
   * 断不掉是要走串口的理由，不是终止写入的理由。
   * 旧实现连续失败两次就直接判「音频通道被占用」，导致耳机在盒里、
   * 手机没放任何音频时也永远写不进去（系统建立的音频连接常常断不掉，回 2900099）。
   */
  /**
   * 擦写期间把被系统连回来的音频通道再按下去。
   *
   * 手机系统会自动把 A2DP 连回已配对的耳机，而连接建立/握手要占用同一条 ACL，
   * 耳机正在写闪存时被这么打断就会中止——真机上表现为「擦写停在 8x%~99%、
   * 紧接着音频回连、音效被截断」。参考实现在 PC 上全程不碰音频，所以不会遇到。
   *
   * 这里只发断开，不再走「先 connectAllowedProfiles 认领再断」：
   * 认领本身会建立音频连接，在擦写期间等于主动去撞闪存；断不掉就让它去，
   * 由擦写静默超时统一收口。
   */
  private async suppressAudioLink(address: string): Promise<void> {
    try {
      await connection.disconnectAllowedProfiles(address);
      this.trace('AUDIO_SUPPRESSED');
    } catch (error) {
      this.trace(`AUDIO_SUPPRESS_DENIED code=${ToneClient.codeOf(error)}`);
    }
  }

  private async releaseAudioLink(address: string): Promise<boolean> {
    // a2dp 是逐设备查的真实状态，global 是系统的汇总缓存：两者不一致时以 a2dp 为准
    this.trace(`AUDIO_STATE a2dp=${ToneClient.a2dpStateOf(address)} ` +
      `global=${ToneClient.globalProfileState()}`);
    if (!this.audioLinked(address)) {
      this.audioGate = 'idle';
      this.trace('AUDIO_LINK_IDLE 音频通道本来就没连');
      return true;
    }
    const startedAt: number = Date.now();
    let accepted: boolean = false;
    try {
      await connection.disconnectAllowedProfiles(address);
      accepted = true;
      this.trace('AUDIO_LINK_RELEASE_SENT');
    } catch (error) {
      /**
       * 2900099：这条音频连接不是本应用发起的（通常是开盖后系统自动连的），
       * 系统不允许第三方断开它。
       *
       * 但 connectAllowedProfiles 会把这台设备的 profile「记到本应用名下」，
       * 之后同一份连接就能被 disconnectAllowedProfiles 断开——
       * 日志里两次「音频断不开 → 等 14 秒」和一次「断开只用 6ms」的差别正是这个。
       */
      this.trace(`AUDIO_RELEASE_DENIED code=${ToneClient.codeOf(error)} ` +
        `${ToneClient.messageOf(error)}`);
      try {
        await connection.connectAllowedProfiles(address);
        this.trace('AUDIO_ADOPT_OK 已把音频连接认领到本应用');
        await sleep(250);
        await connection.disconnectAllowedProfiles(address);
        accepted = true;
        this.trace('AUDIO_LINK_RELEASE_SENT adopt=true');
      } catch (adoptError) {
        this.trace(`AUDIO_ADOPT_FAIL code=${ToneClient.codeOf(adoptError)} ` +
          `${ToneClient.messageOf(adoptError)}`);
      }
    }
    let dropped: boolean = false;
    if (accepted) {
      dropped = await this.waitAudioDrop(address, MbbSpec.AUDIO_DROP_WAIT_MS);
    }
    if (dropped) {
      this.audioGate = 'released';
      ToneClient.releaseHint = true;
      this.trace(`AUDIO_LINK_RELEASED ms=${Date.now() - startedAt}`);
      // A2DP 掉链到能建串口之间还有一点收敛时间（实测 300ms 内拿不到通道）
      await sleep(MbbSpec.AUDIO_SETTLE_MS);
      return true;
    }
    this.audioGate = 'kept';
    ToneClient.releaseHint = false;
    // 请求都被拒的情况下不必再等：音频不会掉，等下去只是白耗时间
    this.trace(accepted ? 'AUDIO_LINK_KEPT 断开请求已受理但通道仍在，改为直接尝试串口' :
      'AUDIO_LINK_KEPT 音频通道仍在，改为直接尝试串口');
    return false;
  }

  /**
   * 等音频通道真的掉下来：比固定 sleep 快，也不会在它还连着时误判成已断开。
   *
   * 掉链是分几拍完成的（日志里 state 先 3 再 0 连报好几次），
   * 所以要求连续两次读到未连接才认账，免得在 ACL 还在拆的时候就去连串口——
   * 那种时机下的 sppConnect 会既不成功也不失败，一直挂到超时。
   */
  private async waitAudioDrop(address: string, timeoutMs: number): Promise<boolean> {
    const until: number = Date.now() + timeoutMs;
    while (Date.now() < until && !this.closed) {
      if (!this.audioLinked(address)) {
        await sleep(180);
        return !this.audioLinked(address);
      }
      await sleep(120);
    }
    return false;
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

  /**
   * 写一次串口。
   *
   * `soft` 用于「试探性」写入（例如把整个分片组合并成一次写）：
   * 失败时不重试、不判链路已死，直接抛给调用方去走降级路径——
   * 否则一次参数被拒就会把整条链路标记成 broken，代价太大。
   */
  private async writeOnce(chunk: Uint8Array, paced: boolean = false,
    soft: boolean = false): Promise<void> {
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
        if (soft) {
          throw error as Error;
        }
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
          // 传输中掉线才需要冷却（耳机要收尾十几秒）；空闲保活掉线是常态
          // （合盖、耳机休眠），给它加冷却会让用户开盖后白等
          if (this.transferring) {
            ToneClient.noteLinkDown(`write code=${code}`);
          } else {
            Logger.info(MODULE, 'SESSION_DROPPED 空闲期写失败，串口已关闭');
          }
          throw failure;
        }
        await sleep(24);
      }
    }
  }

  /**
   * 把一个分片组的 8 帧写出去。
   *
   * 优先合并成一整块（≈7.8KB）一次写：参考实现能跑到 ~63KB/s，靠的就是
   * "8 次 send 只是塞进缓冲"，而鸿蒙这边每次 sppWriteAsync 都是一次跨线程往返。
   * 合并失败（协议栈拒收大包）就退回逐帧写，并把空档压到 4ms。
   */
  private async writeFrames(frames: Uint8Array[], bulk: boolean = true): Promise<void> {
    if (frames.length === 0) {
      return;
    }
    if (this.closed) {
      throw new CancelledError();
    }
    if (frames.length > 1 && bulk && this.batchWrite) {
      let total: number = 0;
      for (let i = 0; i < frames.length; i++) {
        total += frames[i].length;
      }
      if (total <= MbbSpec.BULK_WRITE_BYTES) {
        const merged: Uint8Array = ByteUtils.concat(frames);
        const at: number = Date.now();
        try {
          await this.writeOnce(merged, false, true);
          this.trace(`BULK_WRITE frames=${frames.length} bytes=${merged.length} ms=${Date.now() - at}`);
          return;
        } catch (error) {
          // 大包被拒：本次会话后续窗口一律逐帧写，避免每个窗口都白撞一次
          this.batchWrite = false;
          this.trace(`BULK_WRITE_FALLBACK frames=${frames.length} bytes=${merged.length} ` +
            `ms=${Date.now() - at} code=${ToneClient.codeOf(error)}`);
        }
      }
    }
    for (let i = 0; i < frames.length; i++) {
      if (this.closed) {
        throw new CancelledError();
      }
      await this.writeOnce(frames[i], true);
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

  /**
   * 清掉队列里旧的 2B B4 状态包。
   * 连接/A2DP 回连过程中耳机可能主动推状态包；如果探活或 query 直接匹配到旧包，
   * 会误判「串口还活着」并把真正的查询超时掩盖掉。
   */
  private dropStatusPackets(): void {
    this.received = this.received.filter((packet: Uint8Array): boolean => {
      return !(packet.length >= 2 && ByteUtils.byteAt(packet, 0) === 0x2b &&
        ByteUtils.byteAt(packet, 1) === 0xb4);
    });
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
      // 传输中耳机每 ~100ms 就回一包，15ms 的轮询粒度会白白多等一格
      await sleep(this.transferring ? 5 : 15);
    }
    if (this.closed) {
      throw new CancelledError();
    }
    throw new AckTimeoutError();
  }

  /**
   * 传输阶段等包：不能一口气等满 8 秒。
   * 耳机出盒时系统会周期性自动重连 A2DP，如果正好处在一次长等待里，
   * 要等 8 秒超时才发现链路被抢，写入已经失败。
   * 这里改为 400ms 一片，间隙检查音频通道，一旦回连立即断开。
   */
  private async awaitUploadPacket(predicate: (packet: Uint8Array) => boolean): Promise<Uint8Array> {
    const until: number = Date.now() + MbbSpec.UPLOAD_IDLE_TIMEOUT_MS;
    while (true) {
      try {
        return await this.awaitPacket(400, predicate);
      } catch (error) {
        if (!(error instanceof AckTimeoutError)) {
          throw error as Error;
        }
        if (this.closed) {
          throw new CancelledError();
        }
        if (this.audioLinked(this.address)) {
          this.trace('AUDIO_RELINK_SUPPRESS 传输期间音频被连回，先断开它');
          await this.suppressAudioLink(this.address);
        }
        if (Date.now() >= until) {
          throw error as Error;
        }
      }
    }
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
    // 刚建链时耳机可能丢掉第一条命令，用短超时多次重发；
    // 先清旧状态包，避免把连接期推送的 2B B4 当成这次查询的回执
    this.dropStatusPackets();
    const payload: Uint8Array = ByteUtils.fromHex('2bb4010110');
    return MbbProtocol.parseStatus(await this.command(payload, MbbSpec.QUERY_TIMEOUT_MS, MbbSpec.QUERY_ATTEMPTS));
  }

  /** 轻量探活：1.5 秒内拿不到状态就认为这条串口已经失效 */
  async probe(): Promise<void> {
    this.dropStatusPackets();
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
    const status: ToneStatus = await this.setToneRaw(id, selected, volume, timeoutMs, attempts);
    if (!status.enabled || status.selected !== selected) {
      throw new ToneError(I18n.t('toneErr.applyFailed'));
    }
    return status;
  }

  /** 发一条「选中音效」设置，只回包解析、不做语义校验：内置音效的 selected 语义随固件不同 */
  private async setToneRaw(id: number, selected: boolean, volume: number,
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
    return status;
  }

  /**
   * 选中盒端内置音效：只切换播放哪一段，不写闪存，失败也能随时切回。
   *
   * selected 标志在不同固件上语义不一致（自定义槽位用 true、恢复出厂用 false），
   * 这里不猜：先按"恢复出厂"的写法发一次，用回包里的 toneId 是否等于目标判断，
   * 没生效再补一次 selected=true。
   */
  async selectBuiltIn(id: number): Promise<ToneStatus> {
    const current: ToneStatus = await this.query();
    const first: ToneStatus = await this.setToneRaw(id, false, current.volume);
    if (first.toneId === id) {
      return first;
    }
    const second: ToneStatus = await this.setToneRaw(id, true, current.volume);
    if (second.toneId !== id) {
      throw new ToneError(I18n.t('toneErr.applyFailed'));
    }
    return second;
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
    this.flushUnconfirmed = false;
    this.preselected = false;
    /**
     * 传输前如果音频通道已经连回来，先断开。
     * 2026-11 实测：耳机出盒后系统会周期性自动重连 A2DP，
     * 恰好撞在传输窗口上时会把 SPP 的 ACL 抢走，表现为 ackTimeout。
     */
    if (this.audioLinked(this.address)) {
      this.trace('AUDIO_PRE_SUPPRESS 传输前音频已连回，先断开');
      // 数据还没开始发，可以完整走「认领 + 断开 + 等通道真正掉下去」，
      // 避免第一个分包就撞上系统自动回连的 A2DP。
      await this.releaseAudioLink(this.address);
    }
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
    /** 目标槽位是否已在传输前选中：选中过就不必在收尾再发一次（那时串口常常已经没了） */
    let preSelected: boolean = false;
    /** 最近一次擦写进度，超时日志里要能看出停在哪 */
    let written: number = 0;
    let flushTotal: number = 0;
    /** 数据是否已全部送达：之后只剩耳机擦写闪存，静默时间会很长 */
    let receivedAll: boolean = false;
    /** 上一个分片组的回执时刻：用来量「发完到耳机要下一组」的间隔 */
    let lastAckAt: number = 0;
    /** 最近一次收到擦写进度的时刻：用来区分「耳机还在写」和「耳机已经重启」 */
    let lastProgressAt: number = 0;
    /** 数据传完的时刻：用于算这条链路实际跑多快 */
    let receivedAt: number = 0;
    /** 擦写进度首次到 100% 的时刻：之后再等一小段最终确认（09 06） */
    let flushedAt: number = 0;
    const started: number = Date.now();
    lastProgressAt = started;

    while (!completed) {
      if (this.closed) {
        throw new CancelledError();
      }
      if (Date.now() - started > MbbSpec.UPLOAD_TOTAL_TIMEOUT_MS) {
        throw new ToneError(I18n.t('toneErr.timeout'));
      }
      const isUploadPacket = (candidate: Uint8Array): boolean => {
        if (candidate.length < 2) {
          return false;
        }
        if (protocol === 1) {
          return ByteUtils.byteAt(candidate, 0) === 43 && ByteUtils.byteAt(candidate, 1) === 182;
        }
        return ByteUtils.byteAt(candidate, 0) === 9;
      };
      let packet: Uint8Array = new Uint8Array(0);
      try {
        if (receivedAll) {
          /**
           * 擦写阶段：等到进度走满。
           *
           * 2026-11 真实测：会话从 09 01 算起能活 39 秒，「9.2 秒预算」的说法已作废。
           * 长包（>106KB）卡死的直接原因是耳机擦写第二阶段失去响应，
           * 与音频回连无关（无音频干扰时同样卡死）。
           * 所以这里只等静默超时，音频回连就主动压住，压不住也让擦写自己再试。
           */
          const flushUntil: number = lastProgressAt + MbbSpec.UPLOAD_FLUSH_TIMEOUT_MS;
          while (true) {
            try {
              packet = await this.awaitPacket(600, isUploadPacket);
              break;
            } catch (sliceError) {
              // 只有「这一片没等到包」才继续等；链路断了、用户取消都直接上抛
              if (!(sliceError instanceof AckTimeoutError)) {
                throw sliceError as Error;
              }
              if (this.closed) {
                throw new CancelledError();
              }
              if (this.audioLinked(this.address)) {
                this.trace('AUDIO_RELINK_SUPPRESS 擦写期间音频被连回，先断开它');
                await this.suppressAudioLink(this.address);
              }
              if (flushedAt > 0 && Date.now() >= flushedAt + MbbSpec.UPLOAD_FLUSH_CONFIRM_MS) {
                // 100% 后没再等到 09 06：数据已写满，按「未确认成功」返回，
                // 让用户合盖几秒再开盖确认，而不是立刻宣称写入完成
                emit(0.99, I18n.t('stage.confirming'));
                this.flushUnconfirmed = true;
                completed = true;
                packet = new Uint8Array(0);
                this.trace('UPLOAD_FLUSH_SILENT 100% 后未再收到 09 06，按未确认成功返回');
                break;
              }
              if (Date.now() > flushUntil) {
                this.trace(`FLUSH_TIMEOUT_PROGRESS 停在 ${written}/${flushTotal}，静默超时`);
                const silent: ToneError = new ToneError(
                  I18n.f('toneErr.flushAborted', [`${ToneClient.transferRate(data.length, receivedAt - started)}`]), -98);
                silent.reason = ToneErrorReason.FLUSH_TIMEOUT;
                throw silent;
              }
            }
          }
        } else {
          packet = await this.awaitUploadPacket(isUploadPacket);
        }
      } catch (error) {
        if (receivedAll) {
          // 已经判定的具体结局（耳机重启 / 进度停在 X/Y）原样上抛，别被通用超时盖掉
          if (error instanceof ToneError && (error as ToneError).reason === ToneErrorReason.FLUSH_TIMEOUT) {
            throw error as Error;
          }
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
        /**
         * 这里直接选中目标槽位，再开始传数据——和参考实现（OpenFreebuds）一致：
         * 它先写 toneId、再传包，传完不再改动。
         *
         * 我们以前反过来：先写 0（取消选中）→ 传包 → 传完再选中 43。
         * 代价是任何一次「传完但选不中」都会让耳机回落到默认音；
         * 而且长音效拿不到 100% 擦写回执时，还得重连一次才能补选，
         * 而那时耳机往往正忙、连不上，最终表现为「写失败 + 变回默认音」。
         */
        try {
          await this.setTone(MbbSpec.TONE_CUSTOM_ID, true, before.volume, 1500, 1);
          preSelected = true;
          this.preselected = true;
        } catch (error) {
          // 耳机对这条命令不一定回执，选中结果不影响传输，最后回读时再确认
          this.trace(`TONE_PRESELECT_IGNORED ${ToneClient.messageOf(error)}`);
        }
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
        const windowAt: number = Date.now();
        const framesOut: Uint8Array[] = [];
        let retx: number = 0;
        for (let index = 0; index < 8; index++) {
          if (this.closed) {
            throw new CancelledError();
          }
          const at: number = offset + index * chunkSize;
          const missing: boolean = (bitmap & (1 << index)) === 0;
          if (missing && at < data.length) {
            retx++;
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
              const parts: Uint8Array[] = MbbProtocol.frames(ByteUtils.concat([
                ByteUtils.fromHex('0904ff'),
                offsetField,
                new Uint8Array([index]),
                chunk
              ]));
              for (let f = 0; f < parts.length; f++) {
                framesOut.push(parts[f]);
              }
              sentChunks++;
            }
          }
        }
        if (framesOut.length > 0) {
          await this.writeFrames(framesOut);
        }
        this.trace(`UPLOAD_CHUNKS sent=${sentChunks} offset=${offset}/${data.length} ` +
          `elapsed=${Date.now() - started}ms send=${Date.now() - windowAt}ms ` +
          `ackLag=${lastAckAt === 0 ? -1 : windowAt - lastAckAt}ms retx=${retx}`);
        lastAckAt = Date.now();
        // 传输阶段占 8%~50%：一个分包组是 8 个 chunk，按下一次要写的偏移估算
        const sentBytes: number = Math.min(data.length, offset + chunkSize * 8);
        emit(0.08 + 0.42 * (sentBytes / data.length), I18n.t('stage.transfer'));
      } else if (type === 5) {
        if (protocol === 2) {
          const totalField: Uint8Array | undefined = fields.get(1);
          const receivedField: Uint8Array | undefined = fields.get(2);
          const total: number = totalField !== undefined && totalField.length === 4
            ? ByteUtils.intBE(totalField) : 0;
          const progress: number = receivedField !== undefined && receivedField.length === 4
            ? ByteUtils.intBE(receivedField) : 0;
          if (total > 0) {
            flushTotal = total;
            written = progress;
            lastProgressAt = Date.now();
            this.trace(`UPLOAD_WRITE ${progress}/${total}`);
            // 写入阶段占 50%~95%：耳机的 total 是整包的两倍（收 + 校验写），单独一段
            emit(0.5 + 0.45 * (progress / total), I18n.t('stage.flash'));
            if (!receivedAll && progress >= data.length) {
              receivedAll = true;
              receivedAt = Date.now();
            }
            if (progress >= total && flushedAt === 0) {
              // 100% 先记时刻，不立刻收工：耳机可能还要几秒才补最终 09 06
              flushedAt = Date.now();
              this.trace('UPLOAD_FLUSH_100 等耳机最终确认');
              // 落盘已满，接下来只是等最终回执：进度往前顶一档，
              // 别让界面停在 95% 上显得像卡死
              emit(0.98, I18n.t('stage.flushing'));
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
        } else if (flushedAt > 0) {
          // 100% 之后收到的 09 06 才是最终确认；早到的那条只代表数据已收完
          completed = true;
          this.trace('UPLOAD_FLUSH_CONFIRMED 收到 09 06');
        } else {
          // 协议 2 的 type=6 表示整包数据已收完，耳机转入闪存擦写。
          // 擦写大包时可能几十秒不发任何进度，按普通空闲超时处理会误判失败。
          receivedAll = true;
          receivedAt = Date.now();
          lastProgressAt = Date.now();
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
      `rate=${Math.round(data.length / Math.max(1, elapsed))}KB/s chunk=${this.writeChunk} ` +
      `confirm=${this.flushUnconfirmed ? 'silent' : '09 06'}`);
    emit(0.97, I18n.t('stage.apply'));
    /**
     * 目标槽位在传输开始前就已经选中，所以这里只是「尽力确认」，不再是成败门槛：
     * 耳机写完闪存后随时可能收掉串口，补发不上也不影响它自己按已选中的槽位播放。
     * 只有真正的协议错误（格式、参数被拒）才继续上抛。
     */
    let status: ToneStatus =
      new ToneStatus(true, true, before.volume, MbbSpec.TONE_CUSTOM_ID, true);
    if (preSelected) {
      // 传输前已经选中：这里什么都不用发。
      // 真机上写完最后一块后耳机很快会收掉串口，再发一条只会撞 2901054，
      // 还会顺手记一次 15 秒冷却，把下一次写入也拖慢
      this.trace('TONE_ALREADY_SELECTED 传输前已选中，跳过收尾补发');
    } else {
      try {
        status = await this.confirmTone(before.volume);
      } catch (error) {
        if (error instanceof CancelledError) {
          throw error as Error;
        }
        // 其余一律不阻断：耳机擦写完成后会自己按已选中的槽位播放
        this.trace(`TONE_CONFIRM_IGNORED ${ToneClient.messageOf(error)}`);
      }
    }
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
   * 一段写入结束。
   *
   * 旧实现这里直接关 socket 并给全局冷却：耳机写闪存期间确实不能开始新传输，
   * 但「不能传」不等于「通道已失效」。现在通道留着，只记一个沉降期，
   * 下一次操作在沉降结束后直接复用，省掉重新建链的 3 秒。
   * 若耳机自己把通道收掉了，保活会在沉降期结束后立刻发现并降级为重连。
   */
  private retire(): void {
    this.retiredAt = Date.now();
    this.transferring = false;
    ToneClient.settleUntil = Date.now() + MbbSpec.SESSION_SETTLE_MS;
    // 音频一直没断开（系统不让断）时不能拿「音频自己回来」当擦写完的信号
    ToneClient.settleAudioWasDown = !this.audioLinked(this.address);
    Logger.info(MODULE, `TONE_SETTLED settle=${MbbSpec.SESSION_SETTLE_MS}ms ` +
      `audioDown=${ToneClient.settleAudioWasDown}`);
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
      if (Date.now() < ToneClient.settleUntil) {
        // 写完音效后的沉降期：耳机正在擦闪存，插一条查询会被当成中止信号
        this.trace('KEEPALIVE_SKIP settle');
        return;
      }
      this.send(ByteUtils.fromHex('2bb4010110'), true).catch((error: Error) => {
        this.trace(`KEEPALIVE_FAIL ${ToneClient.messageOf(error)}`);
        this.stopKeepAlive();
        this.broken = true;
        // 空闲期掉线是常态（合盖、耳机休眠），不设全局冷却：
        // 否则用户再打开盒子写入时会白等十几秒，而这条通道本来就没在传输
        Logger.info(MODULE, 'SESSION_DROPPED 热会话已断开');
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

  /** 数据阶段的实测速率（KB/s，整数）：放进错误提示，用户一眼能看出是不是链路慢 */
  private static transferRate(bytes: number, ms: number): number {
    if (ms <= 0) {
      return 0;
    }
    return Math.max(1, Math.round(bytes / ms));
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
      // 只有「主动关掉一条活着的链路」才需要等耳机收尾。
      // 链路已经断了（2901054）还等 1.2 秒纯属白耗——对端早就不在了
      if (!this.broken) {
        ToneClient.lastCloseAt = Date.now();
      }
    }
    this.clientSocket = -1;
    this.readListener = null;
  }

  /** 用户取消 / 页面退出 */
  close(): void {
    if (ToneClient.session === this) {
      ToneClient.session = null;
      ToneClient.cancelSweep();
    }
    this.closed = true;
    this.closeSocket();
    this.assembler.reset();
    this.received = [];
  }
}
