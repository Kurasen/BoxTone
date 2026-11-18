import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DeviceSupport, DeviceSupportLevel, DeviceVerdict, ToneSpec } from '../common/constants/AppConstants';
import { I18n } from '../common/i18n/I18n';
import { DateUtils } from '../common/utils/DateUtils';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { ToneEntry } from '../models/ToneModel';
import { BtSnapshot } from '../models/DeviceModel';
import { BluetoothService } from './BluetoothService';
import { ToneRepositoryService } from './ToneRepositoryService';
import { ToneClient, ToneError, ToneErrorReason, ToneProgress } from './bluetooth/ToneClient';
import { ToneStatus } from './bluetooth/MbbProtocol';

const MODULE: string = 'CaseWrite';
/** 写完音效后耳机要刷闪存，这段时间不接受新连接，恢复音频通道只能等冷却结束 */
const AUDIO_RESTORE_DELAY_MS: number = 16000;

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
}

/** 失败归类：UI 据此区分结局（不支持不再提示重试） */
export class WriteReason {
  static readonly OK: string = 'ok';
  static readonly UNSUPPORTED: string = ToneErrorReason.UNSUPPORTED;
  static readonly FORMAT: string = ToneErrorReason.FORMAT;
  static readonly LINK: string = 'link';
  static readonly NEARLINK: string = 'nearlink';
  static readonly BLOCKED: string = 'blocked';
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

/**
 * 开盒音写入
 *
 * 走华为耳机的 SPP（RFCOMM）控制通道，按 MBB 协议把音效包写到自定义槽位。
 * 流程：校验 → 建链 → 读当前状态 → 探测协议版本 → 分包传输 → 选中并确认。
 */
export class CaseWriteService {
  /** 上一次写入成功后安排的音频恢复定时器 */
  private static restoreTimer: number = -1;
  /** 是否有写入正在进行：期间不能再让音频连回来 */
  private static writing: boolean = false;
  /**
   * 上一次通过前置检查的目标设备。
   * 刚写完音效时我们主动恢复音频，A2DP 会经历 state=0 → 1 → 2 的空档，
   * 这段时间 getConnectedDevices 为空、系统虚拟化地址还可能让配对表出现重复项，
   * 用户连点两次都会被判「未连接到耳机」。用上一次的设备兜底即可。
   */
  private static lastDeviceId: string = '';

  /** 写入前置检查：音效规格 + 文件 + 耳机连接状态 */
  public static check(entry: ToneEntry): WriteCheck {
    if (CaseWriteService.writing) {
      return CaseWriteService.checkFail(WriteCode.WRITE_FAILED, I18n.t('write.inProgress'));
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
        I18n.f('write.tooLarge',
          [FormatUtils.bytes(entry.byteLength), FormatUtils.bytes(ToneSpec.MAX_BYTES)]));
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

  /** 设备链路检查：权限、蓝牙开关、当前输出设备、星闪拦截 */
  private static checkLink(): WriteCheck {
    if (CaseWriteService.writing) {
      return CaseWriteService.checkFail(WriteCode.WRITE_FAILED, I18n.t('write.inProgress'));
    }
    const snapshot = BluetoothService.getSnapshot();
    if (!snapshot.authorized) {
      return CaseWriteService.checkFail(WriteCode.NOT_AUTHORIZED, I18n.t('write.noPermission'));
    }
    if (!snapshot.enabled) {
      return CaseWriteService.checkFail(WriteCode.BLUETOOTH_OFF, I18n.t('write.btOff'));
    }

    // 优先当前音频设备；A2DP 被系统占用/拒绝断开时，允许用户先在系统蓝牙中断开音频，
    // 再对唯一已配对的音频设备发起写入
    let deviceId: string = BluetoothService.activeAudioId();
    if (deviceId.length === 0) {
      if (snapshot.nearLinkName.length > 0) {
        return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
          CaseWriteService.nearLinkHint(snapshot.nearLinkName));
      }
      deviceId = BluetoothService.pairedAudioId();
      // 音频正在连回来的空档里两台兜底都可能取不到；上一次写过的设备仍在配对表就沿用
      if (deviceId.length === 0 && CaseWriteService.lastDeviceId.length > 0 &&
        CaseWriteService.isPaired(snapshot, CaseWriteService.lastDeviceId)) {
        deviceId = CaseWriteService.lastDeviceId;
        Logger.info(MODULE, `前置检查沿用上一次的设备 ${FormatUtils.maskAddress(deviceId)}`);
      }
    }
    if (deviceId.length === 0) {
      return CaseWriteService.checkFail(WriteCode.NO_EARBUD, I18n.t('write.noEarbud'));
    }
    // 星闪开关开启时，写入期间耳机可能自动切回星闪，先要求关闭开关
    if (snapshot.nearLinkEnabled) {
      const label: string = snapshot.activeName.length > 0 ? snapshot.activeName : snapshot.nearLinkName;
      return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
        CaseWriteService.nearLinkSwitchHint(label));
    }
    // 星闪链路没有对三方开放的串口通道：写入前置直接拦截，不给用户白等一次超时
    const viaNearLink: boolean = snapshot.nearLinkBtId.length > 0 &&
      snapshot.nearLinkBtId.toUpperCase() === deviceId.toUpperCase();
    if (viaNearLink) {
      return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
        CaseWriteService.nearLinkHint(snapshot.activeName.length > 0 ? snapshot.activeName : snapshot.nearLinkName));
    }
    // 型号来自固件，改名不影响；名称只在型号未识别时兜底。未命中只提醒，协议探测才是门槛
    const warn: string = CaseWriteService.compatWarn(deviceId, snapshot.activeName);
    CaseWriteService.lastDeviceId = deviceId;

    const ok: WriteCheck = {
      ok: true,
      code: WriteCode.OK,
      message: '',
      warn: warn,
      deviceId: deviceId
    };
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

  /** 未收录机型用中性串口提示，避免把非华为耳机误判成智慧音频占用 */
  private static isKnownHuawei(deviceId: string, activeName: string): boolean {
    return DeviceSupport.judge(BluetoothService.deviceModelOf(deviceId), [activeName]).level !==
      DeviceSupportLevel.UNKNOWN;
  }

  /** 型号优先、蓝牙名兜底的兼容性提醒；只提醒，不拦截 */
  private static compatWarn(deviceId: string, activeName: string): string {
    const hwModel: string = BluetoothService.deviceModelOf(deviceId);
    const verdict: DeviceVerdict = DeviceSupport.judge(hwModel, [activeName]);
    if (verdict.level === DeviceSupportLevel.VERIFIED) {
      return '';
    }
    if (verdict.level === DeviceSupportLevel.OFFICIAL) {
      return I18n.f('write.compatOfficial', [verdict.name, verdict.detail]);
    }
    const label: string = hwModel.length > 0
      ? I18n.f('write.compatHwModel', [hwModel]) :
      (activeName.length > 0 ? I18n.f('write.compatName', [activeName]) : I18n.t('write.compatGeneric'));
    return I18n.f('write.compatWarn', [label]);
  }

  /** 把本次会话查到的型号写进缓存，返回可用于日志/诊断的型号 */
  private static rememberModel(client: ToneClient, deviceId: string): string {
    const model: string = client.deviceModel;
    if (model.length > 0) {
      BluetoothService.noteDeviceModel(deviceId, model);
      Logger.info(MODULE, `DEVICE_MODEL ${model} id=${FormatUtils.maskAddress(deviceId)}`);
      return model;
    }
    return BluetoothService.deviceModelOf(deviceId);
  }

  /** 星闪连接的统一提示：盒音通道只支持经典蓝牙，给出可执行的切换指引 */
  public static nearLinkHint(name: string): string {
    const label: string = name.length > 0 ? name : I18n.t('write.nearLinkFallbackName');
    return I18n.f('write.nearLinkHint', [label]);
  }

  /** 星闪开关未关闭的提示：写入前必须关闭开关，避免耳机在写入期间切回星闪 */
  public static nearLinkSwitchHint(name: string): string {
    const label: string = name.length > 0 ? name : I18n.t('write.nearLinkFallbackName');
    return I18n.f('write.nearLinkSwitchHint', [label]);
  }

  /** 写入耳机盒 */
  public static async write(entry: ToneEntry, onProgress?: ToneProgress): Promise<WriteResult> {
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      return reject(check.code, check.message, WriteReason.BLOCKED);
    }
    // 上一轮成功后安排的音频恢复必须撤销：它会在新一轮连接中途把 A2DP 连回来，
    // 耳机重新建立音频通道后串口传输会被掐断（日志里表现为连续 -1 后落在加密通道上）
    CaseWriteService.cancelPendingRestore();
    CaseWriteService.writing = true;
    const deviceId: string = check.deviceId;
    const startedAt: number = Date.now();
    const modelName: string = BluetoothService.getSnapshot().activeName;
    const linkMode: string = BluetoothService.getSnapshot().nearLinkName.length > 0 ? 'nearlink' : 'bt';
    Logger.info(MODULE, `开始写入「${entry.name}」 ${entry.durationMs}ms / ${entry.byteLength} 字节 → ` +
      `${FormatUtils.maskAddress(deviceId)} 机型=${modelName.length > 0 ? modelName : '未知'}`);

    let pcm: Uint8Array = new Uint8Array(0);
    try {
      pcm = new Uint8Array(ToneRepositoryService.readBuffer(entry));
    } catch (error) {
      CaseWriteService.writing = false;
      Logger.exception(MODULE, '读取音效文件失败', error as BusinessError);
      return reject(WriteCode.FILE_MISSING, I18n.t('write.fileUnreadable'));
    }
    if (pcm.length === 0 || pcm.length % 2 !== 0) {
      CaseWriteService.writing = false;
      Logger.warn(MODULE, `音效数据格式不正确 length=${pcm.length}`);
      return reject(WriteCode.EMPTY_TONE, I18n.t('write.dataIncomplete'));
    }

    // 链路级失败（串口被耳机收回）自动重来一次：耳机收尾后通常还能再用
    let attempt: number = 0;
    let failure: WriteResult = reject(WriteCode.WRITE_FAILED,
      I18n.f('write.failedWith', [`${WriteCode.WRITE_FAILED}`]));
    try {
      while (attempt < 2) {
        attempt++;
        // 上一条热会话还活着就直接复用，省掉 3 秒建链
        const client: ToneClient = ToneClient.acquire(deviceId, true);
        client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId, modelName));
        try {
          if (onProgress !== undefined) {
            const cooling: number = ToneClient.cooldownLeft();
            onProgress(0.02, attempt > 1 ? I18n.t('write.stageReconnect') :
              (cooling > 0 ? I18n.t('write.stageWaitReady') : I18n.t('write.stageConnect')));
            if (cooling > 0) {
              Logger.info(MODULE, `耳机仍在收尾上一段写入，等待 ${cooling}ms`);
            }
          }
          await client.connect(deviceId);
          if (client.isSecureLink()) {
            Logger.warn(MODULE, '当前走的是加密串口通道，大包传输可能被耳机中断');
          }
          const status: ToneStatus = await client.upload(pcm, (ratio: number, stage: string): void => {
            if (onProgress !== undefined) {
              onProgress(ratio, stage);
            }
          });
          const hwModel: string = CaseWriteService.rememberModel(client, deviceId);
          Logger.info(MODULE, `写入完成「${entry.name}」 槽位=${status.toneId} 音量=${status.volume} ` +
            `耗时=${Date.now() - startedAt}ms`);
          Logger.info(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `audio=${client.audioGateState} result=ok bytes=${pcm.length}`);
          CaseWriteService.scheduleAudioRestore(deviceId);
          return {
            ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
            message: I18n.t('write.success')
          };
        } catch (error) {
          const hwModel: string = CaseWriteService.rememberModel(client, deviceId);
          // 会被自动重试的链路失败不算「写入失败」，日志按 warn 记，
          // 否则诊断日志头部会堆一串其实已经自己恢复的 [E]
          const willRetry: boolean = attempt < 2 && CaseWriteService.isLinkFailure(error);
          failure = CaseWriteService.describeFailure(error, entry, deviceId, modelName, willRetry);
          Logger.warn(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `audio=${client.audioGateState} result=fail code=${failure.code} reason=${failure.reason}`);
          // 数据已经完整写进耳机、只差"选中"：重传 80KB 既慢又没必要，补一条命令即可
          if (attempt < 2 && CaseWriteService.dataAlreadyWritten(error)) {
            Logger.warn(MODULE, '音效数据已写入，改为只补发选中命令');
            if (onProgress !== undefined) {
              onProgress(0.97, I18n.t('write.stageApplyOnly'));
            }
            const applied: WriteResult | null = await CaseWriteService.applyOnly(deviceId);
            if (applied !== null) {
              Logger.info(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
                `btName=${modelName.length > 0 ? modelName : '未知'} ` +
                `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
                `result=ok via=apply-only`);
            }
            return applied !== null ? applied : failure;
          }
          if (willRetry) {
            Logger.warn(MODULE, `串口在传输中断开，准备重试一次 code=${client.errorCode}`);
            if (onProgress !== undefined) {
              onProgress(0.02, I18n.t('write.stageLinkRetry'));
            }
            await CaseWriteService.pause(1200);
            continue;
          }
          return failure;
        } finally {
          client.release();
        }
      }
      return failure;
    } finally {
      CaseWriteService.writing = false;
    }
  }

  /**
   * 恢复默认开盒音：把耳机从自定义槽位切回出厂提示音。
   * 只发查询与“选中默认”两条命令，不上传音频，通常几秒内完成。
   */
  public static async restoreDefault(): Promise<WriteResult> {
    const link: WriteCheck = CaseWriteService.checkLink();
    if (!link.ok) {
      Logger.warn(MODULE, `恢复默认前置检查未通过 code=${link.code}：${link.message}`);
      return reject(link.code, link.message, WriteReason.BLOCKED);
    }
    CaseWriteService.cancelPendingRestore();
    CaseWriteService.writing = true;
    const deviceId: string = link.deviceId;
    const modelName: string = BluetoothService.getSnapshot().activeName;
    const linkMode: string = BluetoothService.getSnapshot().nearLinkName.length > 0 ? 'nearlink' : 'bt';
    Logger.info(MODULE, `开始恢复默认开盒音 → ${FormatUtils.maskAddress(deviceId)} ` +
      `机型=${modelName.length > 0 ? modelName : '未知'}`);

    let attempt: number = 0;
    let failure: WriteResult = reject(WriteCode.WRITE_FAILED, I18n.t('write.restoreFailed'));
    try {
      while (attempt < 2) {
        attempt++;
        // 上一条热会话还活着就直接复用，省掉 3 秒建链
        const client: ToneClient = ToneClient.acquire(deviceId, true);
        client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId, modelName));
        try {
          await client.connect(deviceId);
          const status: ToneStatus = await client.restoreDefault();
          const hwModel: string = CaseWriteService.rememberModel(client, deviceId);
          Logger.info(MODULE, `恢复默认完成 槽位=${status.toneId} 音量=${status.volume}`);
          Logger.info(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `audio=${client.audioGateState} result=ok action=restore`);
          CaseWriteService.scheduleAudioRestore(deviceId);
          return {
            ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
            message: I18n.t('write.restoreSuccess')
          };
        } catch (error) {
          const hwModel: string = CaseWriteService.rememberModel(client, deviceId);
          failure = CaseWriteService.describeRestoreFailure(error, deviceId, modelName);
          Logger.warn(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `audio=${client.audioGateState} result=fail action=restore code=${failure.code} reason=${failure.reason}`);
          if (attempt < 2 && CaseWriteService.isLinkFailure(error)) {
            Logger.warn(MODULE, `恢复默认音链路中断，准备重试一次 code=${client.errorCode}`);
            await CaseWriteService.pause(1200);
            continue;
          }
          return failure;
        } finally {
          client.release();
        }
      }
      return failure;
    } finally {
      CaseWriteService.writing = false;
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
    CaseWriteService.cancelPendingRestore();
    CaseWriteService.writing = true;
    const deviceId: string = link.deviceId;
    const modelName: string = BluetoothService.getSnapshot().activeName;
    const linkMode: string = BluetoothService.getSnapshot().nearLinkName.length > 0 ? 'nearlink' : 'bt';
    Logger.info(MODULE, `切换内置音效 id=${id}（${label}） → ${FormatUtils.maskAddress(deviceId)}`);
    let attempt: number = 0;
    let failure: WriteResult = reject(WriteCode.WRITE_FAILED, I18n.t('write.builtinFailed'));
    try {
      while (attempt < 2) {
        attempt++;
        // 上一条热会话还活着就直接复用，省掉 3 秒建链
        const client: ToneClient = ToneClient.acquire(deviceId, true);
        client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId, modelName));
        try {
          await client.connect(deviceId);
          const status: ToneStatus = await client.selectBuiltIn(id);
          Logger.info(MODULE, `已切换到内置音效 id=${status.toneId} 音量=${status.volume}`);
          Logger.info(MODULE, `DEVICE_MATRIX hwModel=${BluetoothService.deviceModelOf(deviceId)} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `audio=${client.audioGateState} result=ok action=tone id=${status.toneId}`);
          CaseWriteService.scheduleAudioRestore(deviceId);
          return {
            ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
            message: I18n.f('write.builtinSuccess', [label])
          };
        } catch (error) {
          const toneError: ToneError = error as ToneError;
          const message: string = toneError.message !== undefined && toneError.message.length > 0
            ? toneError.message : I18n.t('write.builtinFailed');
          const reason: string = toneError.reason !== undefined && toneError.reason.length > 0
            ? toneError.reason : WriteReason.OTHER;
          Logger.warn(MODULE, `切换内置音效失败 code=${toneError.code} reason=${reason}：${message}`);
          failure = reject(toneError.code !== undefined && toneError.code !== 0
            ? toneError.code : WriteCode.WRITE_FAILED, message, reason,
            CaseWriteService.buildDiagnostic(null, deviceId, modelName, error));
          if (attempt < 2 && CaseWriteService.isLinkFailure(error)) {
            await CaseWriteService.pause(1200);
            continue;
          }
          return failure;
        } finally {
          client.release();
        }
      }
      return failure;
    } finally {
      CaseWriteService.writing = false;
    }
  }

  private static describeRestoreFailure(error: Object, deviceId: string,
    modelName: string): WriteResult {
    const toneError: ToneError = error as ToneError;
    const declaredReason: string = toneError.reason !== undefined ? toneError.reason : '';
    // 音频通道断不开：界面上仍按链路问题给出重试入口，但不再自动整包重传
    let reason: string = declaredReason === ToneErrorReason.AUDIO_HELD ? WriteReason.LINK :
      (declaredReason.length > 0 ? declaredReason : WriteReason.OTHER);
    let code: number = toneError.code !== undefined && toneError.code !== 0
      ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message !== undefined && toneError.message.length > 0
      ? toneError.message : I18n.f('write.restoreFailedWith', [`${code}`]);
    if (reason === WriteReason.UNSUPPORTED) {
      code = WriteCode.PROTOCOL_UNVERIFIED;
    } else if (code === -99) {
      message = I18n.t('write.restoreInterrupted');
    }
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = I18n.t('write.restoreSppError');
    }
    Logger.exception(MODULE, `恢复默认音失败 code=${code} reason=${reason}：${message}`,
      error as BusinessError);
    return reject(code, message, reason,
      CaseWriteService.buildDiagnostic(null, deviceId, modelName, error));
  }

  private static pause(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 音效包是否已经完整落盘，只是"选中"没发出去 */
  private static dataAlreadyWritten(error: Object): boolean {
    return (error as ToneError).reason === ToneErrorReason.DATA_WRITTEN;
  }

  /** 重连一次，只补发选中命令 */
  private static async applyOnly(deviceId: string): Promise<WriteResult | null> {
    const client: ToneClient = ToneClient.acquire(deviceId, true);
    client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId,
      BluetoothService.getSnapshot().activeName));
    try {
      await client.connect(deviceId);
      const status: ToneStatus = await client.applyCustom();
      Logger.info(MODULE, `补发选中成功 槽位=${status.toneId} 音量=${status.volume}`);
      CaseWriteService.scheduleAudioRestore(deviceId);
      return {
        ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
        message: I18n.t('write.successApplyOnly')
      };
    } catch (error) {
      Logger.warn(MODULE, `补发选中失败：${(error as ToneError).message}`);
      return null;
    } finally {
      client.release();
    }
  }

  /** 链路级失败（而非耳机拒绝）：这类失败值得自动重试 */
  private static isLinkFailure(error: Object): boolean {
    const toneError: ToneError = error as ToneError;
    const reason: string = toneError.reason !== undefined ? toneError.reason : '';
    if (reason === ToneErrorReason.FLUSH_TIMEOUT || reason === ToneErrorReason.DATA_WRITTEN ||
      reason === ToneErrorReason.CANCELLED || reason === ToneErrorReason.AUDIO_HELD) {
      return false;
    }
    if (reason === ToneErrorReason.LINK || reason === ToneErrorReason.ACK_TIMEOUT) {
      return true;
    }
    const code: number = toneError.code !== undefined ? toneError.code : 0;
    return code === 2901054 || code === 2900099 || code === 2900001 || code === 2900003;
  }

  private static describeFailure(error: Object, entry: ToneEntry, deviceId: string,
    modelName: string, willRetry: boolean = false): WriteResult {
    const toneError: ToneError = error as ToneError;
    const declaredReason: string = toneError.reason !== undefined ? toneError.reason : '';
    // 音频断不开归到链路问题：保留可执行的重试指引，但不会触发自动整包重传
    let reason: string = declaredReason === ToneErrorReason.AUDIO_HELD ? WriteReason.LINK : declaredReason;
    let code: number = toneError.code !== undefined && toneError.code !== 0
      ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message !== undefined && toneError.message.length > 0
      ? toneError.message : I18n.f('write.failedWith', [`${code}`]);
    if (reason === WriteReason.UNSUPPORTED) {
      // 不支持的机型是终端结局：不引导重试，只引导反馈
      code = WriteCode.PROTOCOL_UNVERIFIED;
    } else if (reason === WriteReason.FORMAT) {
      code = WriteCode.FORMAT_REJECTED;
    } else if ((reason.length === 0 || reason === WriteReason.LINK) && CaseWriteService.isLinkFailure(error)) {
      const linkSnapshot: BtSnapshot = BluetoothService.getSnapshot();
      const nearLinkConnected: boolean = linkSnapshot.nearLinkName.length > 0;
      reason = nearLinkConnected ? WriteReason.NEARLINK : WriteReason.LINK;
      if (nearLinkConnected) {
        message = CaseWriteService.nearLinkHint(
          linkSnapshot.activeName.length > 0 ? linkSnapshot.activeName : linkSnapshot.nearLinkName);
      }
    }
    if (code === -99) {
      // 用户主动取消不会走到这里，链路断了才会，别把原因显示成"已取消"
      message = I18n.t('write.interrupted');
    }
    // 系统原生的 SPP 错误文案对用户没有意义，换成可执行的动作
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = I18n.t('write.sppError');
    }
    if (willRetry) {
      // 马上就会自动重试，别在诊断日志里留一条其实已经恢复的 [E]
      Logger.warn(MODULE,
        `写入中断，准备重试 code=${code}${reason.length > 0 ? ` reason=${reason}` : ''}：${message}`);
    } else {
      Logger.exception(MODULE,
        `写入失败 code=${code}${reason.length > 0 ? ` reason=${reason}` : ''}：${message}`,
        error as BusinessError);
    }
    return reject(code, message, reason.length > 0 ? reason : WriteReason.OTHER,
      CaseWriteService.buildDiagnostic(entry, deviceId, modelName, error));
  }

  /** 结构化诊断文本：覆盖未验证机型的全部关键现场，一键复制后可直接发给开发者 */
  private static buildDiagnostic(entry: ToneEntry | null, deviceId: string, modelName: string,
    error: Object): string {
    const toneError: ToneError = error as ToneError;
    const reason: string = toneError.reason !== undefined ? toneError.reason : '';
    const linkSnapshot: BtSnapshot = BluetoothService.getSnapshot();
    const lines: string[] = [];
    lines.push(I18n.t('write.diagHeader'));
    lines.push(I18n.f('write.diagTime', [DateUtils.dateTime(Date.now())]));
    const hwModel: string = BluetoothService.deviceModelOf(deviceId);
    lines.push(I18n.f('write.diagModel', [hwModel.length > 0 ? hwModel : I18n.t('write.diagUnknown')]));
    lines.push(I18n.f('write.diagBtName',
      [modelName.length > 0 ? modelName : I18n.t('write.diagUnknownName'), FormatUtils.maskAddress(deviceId)]));
    lines.push(I18n.f('write.diagLink',
      [linkSnapshot.nearLinkName.length > 0 ? I18n.t('write.diagNearLink') : I18n.t('write.diagClassic')]));
    if (entry !== null) {
      lines.push(I18n.f('write.diagTone',
        [entry.name, `${entry.durationMs}`, `${entry.byteLength}`]));
    } else {
      lines.push(I18n.t('write.diagAction'));
    }
    lines.push(I18n.f('write.diagResult', [`code=${toneError.code !== undefined ? toneError.code : 0}` +
      `${reason.length > 0 ? ` reason=${reason}` : ''}`]));
    const extra: string = toneError.diagnostic !== undefined ? toneError.diagnostic : '';
    if (extra.length > 0) {
      lines.push(I18n.f('write.diagDetail', [extra]));
    }
    lines.push(I18n.t('write.diagFooter'));
    return lines.join('\n');
  }

  /** 撤销待执行的音频恢复 */
  private static cancelPendingRestore(): void {
    if (CaseWriteService.restoreTimer >= 0) {
      clearTimeout(CaseWriteService.restoreTimer);
      CaseWriteService.restoreTimer = -1;
      Logger.info(MODULE, '已取消待执行的音频恢复');
    }
  }

  /** 写入过程中断开了音频通道，成功后延迟重连，尽力恢复听歌状态 */
  private static scheduleAudioRestore(deviceId: string): void {
    CaseWriteService.cancelPendingRestore();
    CaseWriteService.restoreTimer = setTimeout(() => {
      CaseWriteService.restoreTimer = -1;
      if (CaseWriteService.writing) {
        Logger.info(MODULE, '有新的写入在进行，跳过音频恢复');
        return;
      }
      // 耳机常在闪存写完后自己把 A2DP 连回来，这时再 connect 只会多弹一次系统横幅
      if (BluetoothService.isAudioConnected(deviceId)) {
        Logger.info(MODULE, `音频通道已自行恢复，跳过重连 ${FormatUtils.maskAddress(deviceId)}`);
        return;
      }
      BluetoothService.connect(deviceId).then(() => {
        Logger.info(MODULE, `已恢复音频通道 ${FormatUtils.maskAddress(deviceId)} ` +
          `session=${ToneClient.hasSession() ? 'held' : 'closed'}`);
      }).catch((error: BusinessError) => {
        Logger.info(MODULE, `恢复音频通道失败（不影响音效）code=${error.code} ` +
          `session=${ToneClient.hasSession() ? 'held' : 'closed'}`);
      });
    }, AUDIO_RESTORE_DELAY_MS);
  }
}
