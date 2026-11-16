import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DeviceSupport, DeviceSupportLevel, DeviceVerdict, ToneSpec } from '../common/constants/AppConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { ToneEntry } from '../models/ToneModel';
import { BtSnapshot } from '../models/DeviceModel';
import { BluetoothService } from './BluetoothService';
import { DemoService } from './DemoService';
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

  /** 写入前置检查：音效规格 + 文件 + 耳机连接状态 */
  public static check(entry: ToneEntry): WriteCheck {
    if (DemoService.isActive()) {
      return CaseWriteService.checkFail(WriteCode.NO_EARBUD,
        '演示模式使用模拟耳机，不会写入真实设备。退出演示并连接耳机后再试');
    }
    if (CaseWriteService.writing) {
      return CaseWriteService.checkFail(WriteCode.WRITE_FAILED, '正在写入，请等待当前任务完成');
    }
    if (entry.byteLength <= 0 || entry.durationMs <= 0) {
      return CaseWriteService.checkFail(WriteCode.EMPTY_TONE, '音效数据为空，请重新生成');
    }
    if (entry.durationMs > ToneSpec.MAX_SECONDS * 1000) {
      return CaseWriteService.checkFail(WriteCode.TOO_LONG,
        `时长 ${FormatUtils.seconds(entry.durationMs)} 超过充电盒上限 ${ToneSpec.MAX_SECONDS} 秒`);
    }
    if (entry.byteLength > ToneSpec.MAX_BYTES) {
      return CaseWriteService.checkFail(WriteCode.TOO_LARGE,
        `文件 ${FormatUtils.bytes(entry.byteLength)} 超过上限 ${FormatUtils.bytes(ToneSpec.MAX_BYTES)}`);
    }

    const snapshot = BluetoothService.getSnapshot();
    if (!snapshot.authorized) {
      return CaseWriteService.checkFail(WriteCode.NOT_AUTHORIZED, '未授予蓝牙权限，无法写入耳机');
    }
    if (!snapshot.enabled) {
      return CaseWriteService.checkFail(WriteCode.BLUETOOTH_OFF, '蓝牙未开启，请先打开蓝牙');
    }

    // 写入必须先连上耳机：串口通道要在已建立的 ACL 上才稳定，
    // 未连接时直接给出提示，避免用户以为点了没反应
    const deviceId: string = BluetoothService.activeAudioId();
    if (deviceId.length === 0) {
      if (snapshot.nearLinkName.length > 0) {
        return CaseWriteService.checkFail(WriteCode.NEARLINK_UNSUPPORTED,
          CaseWriteService.nearLinkHint(snapshot.nearLinkName));
      }
      return CaseWriteService.checkFail(WriteCode.NO_EARBUD,
        '未连接到耳机。请先在「设备」页配对并连接耳机，写入时把双耳放入充电盒、打开盒盖');
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

    try {
      if (!fs.accessSync(ToneRepositoryService.pathOf(entry))) {
        return CaseWriteService.checkFail(WriteCode.FILE_MISSING, '音效文件已被删除，请重新生成');
      }
    } catch (error) {
      Logger.exception(MODULE, '检查音效文件失败', error as BusinessError);
      return CaseWriteService.checkFail(WriteCode.FILE_MISSING, '音效文件不可读，请重新生成');
    }

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
      return `当前设备「${verdict.name}」${verdict.detail}：` +
        '协议探测会判断是否可用，可能被盒子拒绝（不会损坏设备）。';
    }
    const label: string = hwModel.length > 0
      ? `当前设备型号「${hwModel}」` : (activeName.length > 0 ? `当前设备「${activeName}」` : '当前设备');
    return `${label}不在已验证机型列表：盒音自定义为实验性功能，可能被盒子拒绝（不会损坏设备）。` +
      '写入时会自动记录耳机型号，之后按型号比对。';
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
    const label: string = name.length > 0 ? `「${name}」` : '耳机';
    return `${label}当前通过星闪方式连接。盒音写入只支持经典蓝牙通道：` +
      '请在设备页和系统「星闪和蓝牙」设置中把耳机切换为经典蓝牙连接（关闭星闪音频）后，再进行数据写入操作。';
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
      return reject(WriteCode.FILE_MISSING, '音效文件不可读，请重新生成');
    }
    if (pcm.length === 0 || pcm.length % 2 !== 0) {
      CaseWriteService.writing = false;
      Logger.warn(MODULE, `音效数据格式不正确 length=${pcm.length}`);
      return reject(WriteCode.EMPTY_TONE, '音效数据不完整，请重新生成');
    }

    // 链路级失败（串口被耳机收回）自动重来一次：耳机收尾后通常还能再用
    let attempt: number = 0;
    let failure: WriteResult = reject(WriteCode.WRITE_FAILED, '写入失败');
    try {
      while (attempt < 2) {
        attempt++;
        const client: ToneClient = new ToneClient(true);
        client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId, modelName));
        try {
          if (onProgress !== undefined) {
            const cooling: number = ToneClient.cooldownLeft();
            onProgress(0.02, attempt > 1 ? '重新连接耳机' : (cooling > 0 ? '等待耳机就绪' : '连接耳机'));
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
            `result=ok bytes=${pcm.length}`);
          CaseWriteService.scheduleAudioRestore(deviceId);
          return {
            ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
            message: '已写入耳机盒。合盖 3 秒再开盖即可听到新音效；换下一段音效前也请先合盖再开盖，让耳机把上一段写完'
          };
        } catch (error) {
          const hwModel: string = CaseWriteService.rememberModel(client, deviceId);
          failure = CaseWriteService.describeFailure(error, entry, deviceId, modelName);
          Logger.warn(MODULE, `DEVICE_MATRIX hwModel=${hwModel.length > 0 ? hwModel : '未知'} ` +
            `btName=${modelName.length > 0 ? modelName : '未知'} ` +
            `id=${FormatUtils.maskAddress(deviceId)} protocol=${client.protocolUsed} link=${linkMode} ` +
            `result=fail code=${failure.code} reason=${failure.reason}`);
          // 数据已经完整写进耳机、只差"选中"：重传 80KB 既慢又没必要，补一条命令即可
          if (attempt < 2 && CaseWriteService.dataAlreadyWritten(error)) {
            Logger.warn(MODULE, '音效数据已写入，改为只补发选中命令');
            if (onProgress !== undefined) {
              onProgress(0.97, '重新连接以应用音效');
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
          const linkBroken: boolean = CaseWriteService.isLinkFailure(error);
          if (attempt < 2 && linkBroken) {
            Logger.warn(MODULE, `串口在传输中断开，准备重试一次 code=${client.errorCode}`);
            if (onProgress !== undefined) {
              onProgress(0.02, '链路中断，正在重连');
            }
            await CaseWriteService.pause(1200);
            continue;
          }
          return failure;
        } finally {
          client.close();
        }
      }
      return failure;
    } finally {
      CaseWriteService.writing = false;
    }
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
    const message: string = (error as ToneError).message;
    return message !== undefined && message.indexOf('音效已写入') >= 0;
  }

  /** 重连一次，只补发选中命令 */
  private static async applyOnly(deviceId: string): Promise<WriteResult | null> {
    const client: ToneClient = new ToneClient(true);
    client.setNeutralHints(!CaseWriteService.isKnownHuawei(deviceId,
      BluetoothService.getSnapshot().activeName));
    try {
      await client.connect(deviceId);
      const status: ToneStatus = await client.applyCustom();
      Logger.info(MODULE, `补发选中成功 槽位=${status.toneId} 音量=${status.volume}`);
      CaseWriteService.scheduleAudioRestore(deviceId);
      return {
        ok: true, code: WriteCode.OK, reason: WriteReason.OK, diagnostic: '',
        message: '已写入耳机盒。合盖 3 秒再开盖即可听到新音效'
      };
    } catch (error) {
      Logger.warn(MODULE, `补发选中失败：${(error as ToneError).message}`);
      return null;
    } finally {
      client.close();
    }
  }

  /** 链路级失败（而非耳机拒绝）：这类失败值得自动重试 */
  private static isLinkFailure(error: Object): boolean {
    const toneError: ToneError = error as ToneError;
    const message: string = toneError.message !== undefined ? toneError.message : '';
    const code: number = toneError.code !== undefined ? toneError.code : 0;
    if (code === 2901054 || code === 2900099 || code === 2900001 || code === 2900003) {
      return true;
    }
    return message.indexOf('连接已中断') >= 0 || message.indexOf('回执超时') >= 0;
  }

  private static describeFailure(error: Object, entry: ToneEntry, deviceId: string,
    modelName: string): WriteResult {
    const toneError: ToneError = error as ToneError;
    const declaredReason: string = toneError.reason !== undefined ? toneError.reason : '';
    let reason: string = declaredReason;
    let code: number = toneError.code !== undefined && toneError.code !== 0
      ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message !== undefined && toneError.message.length > 0
      ? toneError.message : `写入失败（${code}），详见日志`;
    if (reason === WriteReason.UNSUPPORTED) {
      // 不支持的机型是终端结局：不引导重试，只引导反馈
      code = WriteCode.PROTOCOL_UNVERIFIED;
    } else if (reason === WriteReason.FORMAT) {
      code = WriteCode.FORMAT_REJECTED;
    } else if (reason.length === 0 && CaseWriteService.isLinkFailure(error)) {
      const linkSnapshot: BtSnapshot = BluetoothService.getSnapshot();
      const nearLinkConnected: boolean = linkSnapshot.nearLinkName.length > 0;
      reason = nearLinkConnected ? WriteReason.NEARLINK : WriteReason.LINK;
      if (nearLinkConnected) {
        message = CaseWriteService.nearLinkHint(
          linkSnapshot.activeName.length > 0 ? linkSnapshot.activeName : linkSnapshot.nearLinkName);
      }
    }
    if (message === '已取消') {
      // 用户主动取消不会走到这里，链路断了才会，别把原因显示成"已取消"
      message = '写入被中断：耳机收回了串口，请合盖 3 秒后再开盖重试';
    }
    // 系统原生的 SPP 错误文案对用户没有意义，换成可执行的动作
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = '串口在传输中断开。耳机可能还在写入上一段音效，请合盖 3 秒后再开盖重试';
    }
    Logger.exception(MODULE,
      `写入失败 code=${code}${reason.length > 0 ? ` reason=${reason}` : ''}：${message}`,
      error as BusinessError);
    return reject(code, message, reason.length > 0 ? reason : WriteReason.OTHER,
      CaseWriteService.buildDiagnostic(entry, deviceId, modelName, error));
  }

  /** 结构化诊断文本：覆盖未验证机型的全部关键现场，一键复制后可直接发给开发者 */
  private static buildDiagnostic(entry: ToneEntry, deviceId: string, modelName: string,
    error: Object): string {
    const toneError: ToneError = error as ToneError;
    const reason: string = toneError.reason !== undefined ? toneError.reason : '';
    const linkSnapshot: BtSnapshot = BluetoothService.getSnapshot();
    const lines: string[] = [];
    lines.push('【盒音工坊 诊断信息】');
    lines.push(`时间：${DateUtils.dateTime(Date.now())}`);
    const hwModel: string = BluetoothService.deviceModelOf(deviceId);
    lines.push(`型号：${hwModel.length > 0 ? hwModel : '未识别'}`);
    lines.push(`蓝牙名：${modelName.length > 0 ? modelName : '未知'}（${FormatUtils.maskAddress(deviceId)}）`);
    lines.push(`链路：${linkSnapshot.nearLinkName.length > 0 ? '星闪（尝试经典蓝牙写入）' : '经典蓝牙'}`);
    lines.push(`音效：${entry.name} ${entry.durationMs}ms / ${entry.byteLength} 字节`);
    lines.push(`结果：code=${toneError.code !== undefined ? toneError.code : 0}` +
      `${reason.length > 0 ? ` reason=${reason}` : ''}`);
    const extra: string = toneError.diagnostic !== undefined ? toneError.diagnostic : '';
    if (extra.length > 0) {
      lines.push(`详情：${extra}`);
    }
    lines.push('请把以上内容连同日志反馈给开发者，谢谢');
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
        Logger.info(MODULE, `已恢复音频通道 ${FormatUtils.maskAddress(deviceId)}`);
      }).catch((error: BusinessError) => {
        Logger.info(MODULE, `恢复音频通道失败（不影响音效）code=${error.code}`);
      });
    }, AUDIO_RESTORE_DELAY_MS);
  }
}
