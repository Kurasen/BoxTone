import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ToneSpec } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { DateUtils } from '../common/utils/DateUtils';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { ToneEntry } from '../models/ToneModel';
import { BtSnapshot } from '../models/DeviceModel';
import { BluetoothService } from './BluetoothService';
import { SettingsService } from './SettingsService';
import { ToneRepositoryService } from './ToneRepositoryService';
import { WriteCompatibility } from './WriteCompatibility';
import { isToneError, ToneError, ToneErrorReason } from './bluetooth/ToneTypes';
import { WriteEngine } from './write/WriteEngine';
import { CommandOutcome, StepProgress, WriteOutcome } from './write/WriteTypes';

const MODULE: string = 'CaseWrite';

/** 写入结果码：1xxx 音效规格，2xxx 设备，3xxx 协议/传输 */
export class WriteCode {
  static readonly OK: number = 0;
  static readonly EMPTY_TONE: number = 1001;
  static readonly TOO_LONG: number = 1002;
  static readonly TOO_LARGE: number = 1003;
  static readonly FILE_MISSING: number = 1004;
  static readonly BLUETOOTH_OFF: number = 2001;
  static readonly NO_EARBUD: number = 2002;
  static readonly NOT_AUTHORIZED: number = 2003;
  static readonly PROTOCOL_UNVERIFIED: number = 3001;
  static readonly CONNECT_FAILED: number = 3002;
  static readonly WRITE_FAILED: number = 3003;
  static readonly FORMAT_REJECTED: number = 3004;
  static readonly NEARLINK_UNSUPPORTED: number = 2004;
  /** 本进程的蓝牙串口卡死：只能重启应用，没有对应的「下一步」文案（正文已经说清楚） */
  static readonly LINK_WEDGED: number = 3005;
  /** 连接请求挂起、耳机不回应：可以重试，不一定要重启 */
  static readonly LINK_STALLED: number = 3006;

  /**
   * 错误码对应的「下一步该做什么」，返回 i18n key。
   * 用户看不懂 2002 这类数字，弹窗要以这条建议为主体，错误码只用于反馈时定位。
   */
  static hintKey(code: number): string {
    switch (code) {
      case WriteCode.EMPTY_TONE:
        return 'write.hint.emptyTone';
      case WriteCode.TOO_LONG:
        return 'write.hint.tooLong';
      case WriteCode.TOO_LARGE:
        return 'write.hint.tooLarge';
      case WriteCode.FILE_MISSING:
        return 'write.hint.fileMissing';
      case WriteCode.BLUETOOTH_OFF:
        return 'write.hint.btOff';
      case WriteCode.NO_EARBUD:
        return 'write.hint.noEarbud';
      case WriteCode.NOT_AUTHORIZED:
        return 'write.hint.notAuthorized';
      case WriteCode.NEARLINK_UNSUPPORTED:
        return 'write.hint.nearLinkUnsupported';
      case WriteCode.PROTOCOL_UNVERIFIED:
        return 'write.hint.protocolUnverified';
      case WriteCode.CONNECT_FAILED:
        return 'write.hint.connectFailed';
      case WriteCode.WRITE_FAILED:
        return 'write.hint.writeFailed';
      case WriteCode.FORMAT_REJECTED:
        return 'write.hint.formatRejected';
      // 耳机拒绝串口：系统错误码直接透传上来，这里单独给一条动作
      case WriteCode.LINK_STALLED:
        return 'write.hint.linkStalled';
      case 2900099:
        return 'write.hint.serialRefused';
      // 耳机上报的传输中合盖（ToneStatusCodec.LID_CLOSED），透传上来的是耳机错误码
      case 109017:
        return 'write.hint.lidClosed';
      default:
        return '';
    }
  }
}

/** 失败归类：UI 据此区分结局（不支持不再提示重试） */
export class WriteReason {
  static readonly OK: string = 'ok';
  static readonly UNSUPPORTED: string = ToneErrorReason.UNSUPPORTED;
  static readonly FORMAT: string = ToneErrorReason.FORMAT;
  static readonly LINK: string = 'link';
  static readonly NEARLINK: string = 'nearlink';
  static readonly BLOCKED: string = 'blocked';
  /** 用户在传输开始前取消：不算失败，不记失败次数 */
  static readonly CANCELLED: string = ToneErrorReason.CANCELLED;
  /** 蓝牙串口卡死：界面给「重启应用」按钮 */
  static readonly WEDGED: string = ToneErrorReason.WEDGED;
  /** 耳机不回应连接：界面给「重试」与「重启应用」 */
  static readonly STALLED: string = ToneErrorReason.STALLED;
  static readonly OTHER: string = 'other';
}

/** 写入前置检查结果 */
export interface WriteCheck {
  ok: boolean;
  code: number;
  message: string;
  /** 非阻塞提醒：耳机未连接时告知需要入盒开盖，但允许继续尝试 */
  warn: string;
  deviceId: string;
}

export interface WriteResult {
  ok: boolean;
  code: number;
  message: string;
  /** 失败归类，见 WriteReason；成功时为 WriteReason.OK */
  reason: string;
  /** 一键复制用的结构化诊断信息，无需反馈时为空串 */
  diagnostic: string;
}

function reject(code: number, message: string, reason: string = WriteReason.OTHER,
  diagnostic: string = ''): WriteResult {
  const result: WriteResult = {
    ok: false, code: code, message: message, reason: reason, diagnostic: diagnostic
  };
  return result;
}

function accept(message: string): WriteResult {
  const result: WriteResult = {
    ok: true, code: WriteCode.OK, message: message, reason: WriteReason.OK, diagnostic: ''
  };
  return result;
}

/**
 * 开盒音写入（对页面的门面）。
 *
 * 这一层只做三件事：前置检查、读音效文件、把引擎的结果翻译成界面要的 WriteResult。
 * 建链、上传、重试、回滚、系统保护全部在 services/write/WriteEngine 里，
 * 对页面的接口与旧版完全一致，页面不需要改。
 */
export class CaseWriteService {
  /**
   * 上一次通过前置检查的目标设备。
   * 刚写完音效时 A2DP 会经历 state=0 → 1 → 2 的空档，这段时间 getConnectedDevices 为空，
   * 用户连点两次都会被判「未连接到耳机」。用上一次的设备兜底即可。
   */
  private static lastDeviceId: string = '';

  /** 是否正在写入或后台回滚（删除、备份等操作据此避让） */
  public static isBusy(): boolean {
    return WriteEngine.isBusy();
  }

  /** 指定音效是否正在被写入：写入期间不允许删除这一条 */
  public static isToneWriting(toneId: string): boolean {
    return WriteEngine.isWriting() && toneId.length > 0 && WriteEngine.activeToneId() === toneId;
  }

  /** 写入前置检查：音效规格 + 文件 + 耳机连接状态 */
  public static check(entry: ToneEntry): WriteCheck {
    const busy: WriteCheck | null = CaseWriteService.busyCheck();
    if (busy !== null) {
      return busy;
    }
    if (entry.byteLength <= 0 || entry.durationMs <= 0) {
      return CaseWriteService.checkFail(WriteCode.EMPTY_TONE, I18n.t('write.emptyTone'));
    }
    if (entry.durationMs > ToneSpec.MAX_SECONDS * 1000) {
      return CaseWriteService.checkFail(WriteCode.TOO_LONG,
        I18n.f('write.tooLong', [FormatUtils.seconds(entry.durationMs), `${ToneSpec.MAX_SECONDS}`]));
    }
    if (entry.byteLength > ToneSpec.MAX_BYTES) {
      return CaseWriteService.checkFail(WriteCode.TOO_LARGE,
        I18n.f('write.tooLarge', [FormatUtils.bytes(entry.byteLength), FormatUtils.bytes(ToneSpec.MAX_BYTES)]));
    }
    const link: WriteCheck = CaseWriteService.checkLink();
    if (!link.ok) {
      return link;
    }
    try {
      if (!fs.accessSync(ToneRepositoryService.pathOf(entry))) {
        return CaseWriteService.checkFail(WriteCode.FILE_MISSING, I18n.t('write.fileMissing'));
      }
    } catch (error) {
      Logger.exception(MODULE, '检查音效文件失败', error as BusinessError);
      return CaseWriteService.checkFail(WriteCode.FILE_MISSING, I18n.t('write.fileUnreadable'));
    }
    return link;
  }

  /** 恢复默认音的前置检查：只依赖设备连接状态 */
  public static checkRestore(): WriteCheck {
    return CaseWriteService.checkLink();
  }

  /** 只有用户自己发起的操作会挡住新的写入；后台回滚会被新操作直接放弃 */
  private static busyCheck(): WriteCheck | null {
    if (WriteEngine.isUserBusy()) {
      return CaseWriteService.checkFail(WriteCode.WRITE_FAILED, I18n.t('write.inProgress'));
    }
    return null;
  }

  /**
   * 找不到可写入的耳机。
   * 刚写完一条时耳机在刷闪存、A2DP 会断开一阵，这时报「未连接耳机」会让用户以为掉线了，
   * 保存窗口内改成告诉用户还要等多久。只改提示、不额外拦截。
   */
  private static noEarbudFail(): WriteCheck {
    const leftMs: number = BluetoothService.caseSettlingLeftMs();
    if (leftMs > 0) {
      return CaseWriteService.checkFail(WriteCode.NO_EARBUD,
        I18n.f('write.caseSettling', [`${Math.max(1, Math.ceil(leftMs / 1000))}`]));
    }
    return CaseWriteService.checkFail(WriteCode.NO_EARBUD, I18n.t('write.noEarbud'));
  }

  /** 设备链路检查：权限、蓝牙开关、当前输出设备、星闪拦截 */
  private static checkLink(): WriteCheck {
    const busy: WriteCheck | null = CaseWriteService.busyCheck();
    if (busy !== null) {
      return busy;
    }
    const snapshot: BtSnapshot = BluetoothService.getSnapshot();
    if (!snapshot.authorized) {
      return CaseWriteService.checkFail(WriteCode.NOT_AUTHORIZED, I18n.t('write.noPermission'));
    }
    if (!snapshot.enabled) {
      return CaseWriteService.checkFail(WriteCode.BLUETOOTH_OFF, I18n.t('write.btOff'));
    }

    // 优先当前音频设备；A2DP 被系统占用/拒绝断开时，允许对唯一已配对的音频设备发起写入
    let deviceId: string = BluetoothService.activeAudioId();
    if (deviceId.length === 0) {
      if (snapshot.nearLinkName.length > 0) {
        return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
          WriteCompatibility.nearLinkHint(snapshot.nearLinkName));
      }
      deviceId = BluetoothService.pairedAudioId();
      // 音频正在连回来的空档里两种兜底都可能取不到；上一次写过的设备仍在配对表、且此刻连着就沿用
      if (deviceId.length === 0 && CaseWriteService.lastDeviceId.length > 0 &&
        CaseWriteService.isPaired(snapshot, CaseWriteService.lastDeviceId)) {
        if (!BluetoothService.isAudioConnected(CaseWriteService.lastDeviceId)) {
          return CaseWriteService.noEarbudFail();
        }
        deviceId = CaseWriteService.lastDeviceId;
        Logger.info(MODULE, `前置检查沿用上一次的设备 ${FormatUtils.maskAddress(deviceId)}`);
      }
    }
    if (deviceId.length === 0) {
      return CaseWriteService.noEarbudFail();
    }
    // 星闪开关开启时，写入期间耳机可能自动切回星闪，先要求关闭开关
    if (snapshot.nearLinkEnabled) {
      const label: string = snapshot.activeName.length > 0 ? snapshot.activeName : snapshot.nearLinkName;
      return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED, WriteCompatibility.nearLinkSwitchHint(label));
    }
    // 星闪链路没有对三方开放的串口通道：写入前置直接拦截，不给用户白等一次超时
    const viaNearLink: boolean = snapshot.nearLinkBtId.length > 0 &&
      snapshot.nearLinkBtId.toUpperCase() === deviceId.toUpperCase();
    if (viaNearLink) {
      return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
        WriteCompatibility.nearLinkHint(snapshot.activeName.length > 0 ? snapshot.activeName : snapshot.nearLinkName));
    }
    // 型号来自固件，改名不影响；名称只在型号未识别时兜底。未命中只提醒，协议探测才是门槛
    const warn: string = WriteCompatibility.compatWarn(deviceId, snapshot.activeName);
    CaseWriteService.lastDeviceId = deviceId;
    const ok: WriteCheck = { ok: true, code: WriteCode.OK, message: '', warn: warn, deviceId: deviceId };
    return ok;
  }

  private static checkFail(code: number, message: string): WriteCheck {
    const check: WriteCheck = { ok: false, code: code, message: message, warn: '', deviceId: '' };
    return check;
  }

  /** 地址是否仍在配对表里（系统返回的大小写不一致，按忽略大小写比较） */
  private static isPaired(snapshot: BtSnapshot, address: string): boolean {
    const target: string = address.toUpperCase();
    for (let i = 0; i < snapshot.pairedDevices.length; i++) {
      if (snapshot.pairedDevices[i].deviceId.toUpperCase() === target) {
        return true;
      }
    }
    return false;
  }

  /**
   * 目标设备的蓝牙名。
   * 刚启动时音频刚连上、快照还没刷新，activeName 可能是空的（2026-11-26 19:55 真机：机型=未知，
   * 于是按「非华为耳机」给了中性提示）。这时退回配对表里同一地址的名字。
   */
  private static deviceName(deviceId: string): string {
    const snapshot: BtSnapshot = BluetoothService.getSnapshot();
    if (snapshot.activeName.length > 0) {
      return snapshot.activeName;
    }
    const target: string = deviceId.toUpperCase();
    for (let i = 0; i < snapshot.pairedDevices.length; i++) {
      if (snapshot.pairedDevices[i].deviceId.toUpperCase() === target) {
        return snapshot.pairedDevices[i].name;
      }
    }
    return '';
  }

  private static neutralFor(deviceId: string): boolean {
    return !WriteCompatibility.isKnownHuawei(deviceId, CaseWriteService.deviceName(deviceId));
  }

  // ---------------------------------------------------------------- 写入

  /** 写入耳机盒 */
  public static async write(entry: ToneEntry, onProgress?: StepProgress): Promise<WriteResult> {
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      return reject(check.code, check.message, WriteReason.BLOCKED);
    }
    const deviceId: string = check.deviceId;
    const modelName: string = CaseWriteService.deviceName(deviceId);
    Logger.info(MODULE, `开始写入「${entry.name}」 ${entry.durationMs}ms / ${entry.byteLength} 字节 → ` +
      `${FormatUtils.maskAddress(deviceId)} 机型=${modelName.length > 0 ? modelName : '未知'}`);

    let pcm: Uint8Array = new Uint8Array(0);
    try {
      pcm = new Uint8Array(ToneRepositoryService.readBuffer(entry));
    } catch (error) {
      Logger.exception(MODULE, '读取音效文件失败', error as BusinessError);
      return reject(WriteCode.FILE_MISSING, I18n.t('write.fileUnreadable'));
    }
    if (pcm.length === 0 || pcm.length % 2 !== 0) {
      Logger.warn(MODULE, `音效数据格式不正确 length=${pcm.length}`);
      return reject(WriteCode.EMPTY_TONE, I18n.t('write.dataIncomplete'));
    }

    try {
      const outcome: WriteOutcome = await WriteEngine.write(deviceId, entry.id, pcm,
        CaseWriteService.neutralFor(deviceId), onProgress);
      Logger.info(MODULE, `写入完成「${entry.name}」 槽位=${outcome.status.toneId} 音量=${outcome.status.volume} ` +
        `耗时=${outcome.elapsedMs}ms 含等待=${outcome.settleWaitMs}ms 轮次=${outcome.attempts} via=${outcome.via} ` +
        `后台=${outcome.backgrounded}`);
      // 协议不会回读槽位内容，只能在本机记住盒内是哪一条
      SettingsService.setLastWrittenTone(entry.id);
      if (outcome.via === 'apply-only') {
        return accept(I18n.t('write.successApplyOnly'));
      }
      return accept(outcome.flushConfirmed ? I18n.t('write.success') : I18n.t('write.successUnconfirmed'));
    } catch (error) {
      return CaseWriteService.describeFailure(error as Object, entry, deviceId, modelName);
    }
  }

  /**
   * 恢复默认开盒音：把耳机从自定义槽位切回出厂提示音。
   * 只发查询与「选中默认」两条命令，不上传音频，通常几秒内完成。
   */
  public static async restoreDefault(): Promise<WriteResult> {
    const link: WriteCheck = CaseWriteService.checkLink();
    if (!link.ok) {
      Logger.warn(MODULE, `恢复默认前置检查未通过 code=${link.code}：${link.message}`);
      return reject(link.code, link.message, WriteReason.BLOCKED);
    }
    const deviceId: string = link.deviceId;
    const modelName: string = CaseWriteService.deviceName(deviceId);
    Logger.info(MODULE, `开始恢复默认开盒音 → ${FormatUtils.maskAddress(deviceId)} ` +
      `机型=${modelName.length > 0 ? modelName : '未知'}`);
    try {
      const outcome: CommandOutcome = await WriteEngine.restoreDefault(deviceId, CaseWriteService.neutralFor(deviceId));
      Logger.info(MODULE, `恢复默认完成 槽位=${outcome.status.toneId} 音量=${outcome.status.volume}`);
      // 盒内已切回出厂提示音，本机标记同步清空
      SettingsService.setLastWrittenTone('');
      return accept(I18n.t('write.restoreSuccess'));
    } catch (error) {
      return CaseWriteService.describeRestoreFailure(error as Object, deviceId, modelName);
    }
  }

  /**
   * 切换盒端内置提示音：只发「选中」命令，不写闪存，几秒内完成。
   * 失败不影响已经写进去的自定义音效，随时可以再切回来。
   */
  public static async selectBuiltIn(id: number, label: string): Promise<WriteResult> {
    const link: WriteCheck = CaseWriteService.checkLink();
    if (!link.ok) {
      Logger.warn(MODULE, `切换内置音效前置检查未通过 code=${link.code}：${link.message}`);
      return reject(link.code, link.message, WriteReason.BLOCKED);
    }
    const deviceId: string = link.deviceId;
    const modelName: string = CaseWriteService.deviceName(deviceId);
    Logger.info(MODULE, `切换内置音效 id=${id}（${label}） → ${FormatUtils.maskAddress(deviceId)}`);
    try {
      const outcome: CommandOutcome = await WriteEngine.selectBuiltIn(deviceId, CaseWriteService.neutralFor(deviceId),
        id);
      Logger.info(MODULE, `已切换到内置音效 id=${outcome.status.toneId} 音量=${outcome.status.volume}`);
      // 盒内已不是自定义音效：清空「盒内音效」标记
      SettingsService.setLastWrittenTone('');
      return accept(I18n.f('write.builtinSuccess', [label]));
    } catch (error) {
      const toneError: ToneError = CaseWriteService.asToneError(error as Object);
      const message: string = toneError.message.length > 0 ? toneError.message : I18n.t('write.builtinFailed');
      const mapped: string = CaseWriteService.reasonOf(toneError);
      const reason: string = mapped.length > 0 ? mapped : WriteReason.OTHER;
      Logger.warn(MODULE, `切换内置音效失败 code=${toneError.code} reason=${reason}：${message}`);
      const code: number = reason === WriteReason.WEDGED ? WriteCode.LINK_WEDGED :
        (reason === WriteReason.STALLED ? WriteCode.LINK_STALLED :
          (toneError.code !== 0 ? toneError.code : WriteCode.WRITE_FAILED));
      return reject(code, message, reason,
        CaseWriteService.buildDiagnostic(null, deviceId, modelName, toneError));
    }
  }

  // ---------------------------------------------------------------- 失败翻译

  /**
   * 引擎归类 → 界面归类：
   * 音频断不开按链路问题（保留重试）；耳机够不着（多半盒盖合着）按前置拦截，不计失败写入、不显示错误码。
   */
  private static reasonOf(toneError: ToneError): string {
    if (toneError.reason === ToneErrorReason.AUDIO_HELD) {
      return WriteReason.LINK;
    }
    if (toneError.reason === ToneErrorReason.UNREACHABLE) {
      return WriteReason.BLOCKED;
    }
    return toneError.reason;
  }

  private static asToneError(error: Object): ToneError {
    if (isToneError(error)) {
      return error as ToneError;
    }
    const text: string = (error as Error).message !== undefined ? (error as Error).message : '';
    return new ToneError(text, (error as BusinessError).code !== undefined ? (error as BusinessError).code : 0);
  }

  private static describeFailure(error: Object, entry: ToneEntry, deviceId: string, modelName: string): WriteResult {
    const toneError: ToneError = CaseWriteService.asToneError(error);
    if (toneError.reason === ToneErrorReason.CANCELLED) {
      Logger.info(MODULE, `用户取消写入「${entry.name}」`);
      return reject(toneError.code, I18n.t('wp.cancelled'), WriteReason.CANCELLED);
    }
    // 音频断不开归到链路问题：保留可执行的重试指引
    let reason: string = CaseWriteService.reasonOf(toneError);
    let code: number = toneError.code !== 0 ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message.length > 0 ? toneError.message : I18n.f('write.failedWith', [`${code}`]);
    if (reason === WriteReason.WEDGED) {
      code = WriteCode.LINK_WEDGED;
    } else if (reason === WriteReason.STALLED) {
      code = WriteCode.LINK_STALLED;
    } else if (reason === WriteReason.UNSUPPORTED) {
      // 不支持的机型是终端结局：不引导重试，只引导反馈
      code = WriteCode.PROTOCOL_UNVERIFIED;
    } else if (reason === WriteReason.FORMAT) {
      code = WriteCode.FORMAT_REJECTED;
    } else if ((reason.length === 0 || reason === WriteReason.LINK) && WriteEngine.isLinkFailure(toneError)) {
      const snapshot: BtSnapshot = BluetoothService.getSnapshot();
      const nearLinkConnected: boolean = snapshot.nearLinkName.length > 0;
      reason = nearLinkConnected ? WriteReason.NEARLINK : WriteReason.LINK;
      if (nearLinkConnected) {
        message = WriteCompatibility.nearLinkHint(snapshot.activeName.length > 0 ? snapshot.activeName :
          snapshot.nearLinkName);
      }
    }
    if (code === -99) {
      // 用户主动取消不会走到这里，链路断了才会，别把原因显示成「已取消」
      message = I18n.t('write.interrupted');
    }
    // 系统原生的 SPP 错误文案对用户没有意义，换成可执行的动作
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = I18n.t('write.sppError');
    }
    Logger.error(MODULE, `写入失败 code=${code}${reason.length > 0 ? ` reason=${reason}` : ''}：${message}`);
    return reject(code, message, reason.length > 0 ? reason : WriteReason.OTHER,
      CaseWriteService.buildDiagnostic(entry, deviceId, modelName, toneError));
  }

  private static describeRestoreFailure(error: Object, deviceId: string, modelName: string): WriteResult {
    const toneError: ToneError = CaseWriteService.asToneError(error);
    // 音频通道断不开：界面上仍按链路问题给出重试入口
    const mapped: string = CaseWriteService.reasonOf(toneError);
    const reason: string = mapped.length > 0 ? mapped : WriteReason.OTHER;
    let code: number = toneError.code !== 0 ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message.length > 0 ? toneError.message :
      I18n.f('write.restoreFailedWith', [`${code}`]);
    if (reason === WriteReason.WEDGED) {
      code = WriteCode.LINK_WEDGED;
    } else if (reason === WriteReason.STALLED) {
      code = WriteCode.LINK_STALLED;
    } else if (reason === WriteReason.UNSUPPORTED) {
      code = WriteCode.PROTOCOL_UNVERIFIED;
    } else if (code === -99) {
      message = I18n.t('write.restoreInterrupted');
    }
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = I18n.t('write.restoreSppError');
    }
    Logger.error(MODULE, `恢复默认音失败 code=${code} reason=${reason}：${message}`);
    return reject(code, message, reason, CaseWriteService.buildDiagnostic(null, deviceId, modelName, toneError));
  }

  /** 结构化诊断文本：覆盖未验证机型的全部关键现场，一键复制后可直接发给开发者 */
  private static buildDiagnostic(entry: ToneEntry | null, deviceId: string, modelName: string,
    toneError: ToneError): string {
    const reason: string = toneError.reason;
    const snapshot: BtSnapshot = BluetoothService.getSnapshot();
    const lines: string[] = [];
    lines.push(I18n.t('write.diagHeader'));
    lines.push(I18n.f('write.diagTime', [DateUtils.dateTime(Date.now())]));
    const hwModel: string = BluetoothService.deviceModelOf(deviceId);
    lines.push(I18n.f('write.diagModel', [hwModel.length > 0 ? hwModel : I18n.t('write.diagUnknown')]));
    lines.push(I18n.f('write.diagBtName',
      [modelName.length > 0 ? modelName : I18n.t('write.diagUnknownName'), FormatUtils.maskAddress(deviceId)]));
    lines.push(I18n.f('write.diagLink',
      [snapshot.nearLinkName.length > 0 ? I18n.t('write.diagNearLink') : I18n.t('write.diagClassic')]));
    if (entry !== null) {
      lines.push(I18n.f('write.diagTone', [entry.name, `${entry.durationMs}`, `${entry.byteLength}`]));
    } else {
      lines.push(I18n.t('write.diagAction'));
    }
    lines.push(I18n.f('write.diagResult', [`code=${toneError.code}${reason.length > 0 ? ` reason=${reason}` : ''}`]));
    if (toneError.diagnostic.length > 0) {
      lines.push(I18n.f('write.diagDetail', [toneError.diagnostic]));
    }
    lines.push(I18n.t('write.diagFooter'));
    return lines.join('\n');
  }
}
