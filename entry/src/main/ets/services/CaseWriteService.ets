import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ToneSpec } from '../common/constants/AppConstants';
import { FormatUtils } from '../common/utils/FormatUtils';
import { Logger } from '../common/utils/Logger';
import { ToneEntry } from '../models/ToneModel';
import { BluetoothService } from './BluetoothService';
import { DemoService } from './DemoService';
import { ToneRepositoryService } from './ToneRepositoryService';
import { ToneClient, ToneError, ToneProgress } from './bluetooth/ToneClient';
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
}

function reject(code: number, message: string): WriteResult {
  const result: WriteResult = { ok: false, code: code, message: message };
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
      return CaseWriteService.checkFail(WriteCode.NO_EARBUD,
        '未连接到耳机。请先在「设备」页配对并连接耳机，写入时把双耳放入充电盒、打开盒盖');
    }
    const warn: string = '';

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

  /** 写入耳机盒 */
  public static async write(entry: ToneEntry, onProgress?: ToneProgress): Promise<WriteResult> {
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      return reject(check.code, check.message);
    }
    // 上一轮成功后安排的音频恢复必须撤销：它会在新一轮连接中途把 A2DP 连回来，
    // 耳机重新建立音频通道后串口传输会被掐断（日志里表现为连续 -1 后落在加密通道上）
    CaseWriteService.cancelPendingRestore();
    CaseWriteService.writing = true;
    const deviceId: string = check.deviceId;
    const startedAt: number = Date.now();
    const modelName: string = BluetoothService.getSnapshot().activeName;
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
          Logger.info(MODULE, `写入完成「${entry.name}」 槽位=${status.toneId} 音量=${status.volume} ` +
            `耗时=${Date.now() - startedAt}ms`);
          CaseWriteService.scheduleAudioRestore(deviceId);
          return {
            ok: true, code: WriteCode.OK,
            message: '已写入耳机盒。合盖 3 秒再开盖即可听到新音效；换下一段音效前也请先合盖再开盖，让耳机把上一段写完'
          };
        } catch (error) {
          failure = CaseWriteService.describeFailure(error);
          // 数据已经完整写进耳机、只差"选中"：重传 80KB 既慢又没必要，补一条命令即可
          if (attempt < 2 && CaseWriteService.dataAlreadyWritten(error)) {
            Logger.warn(MODULE, '音效数据已写入，改为只补发选中命令');
            if (onProgress !== undefined) {
              onProgress(0.97, '重新连接以应用音效');
            }
            const applied: WriteResult | null = await CaseWriteService.applyOnly(deviceId);
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
    try {
      await client.connect(deviceId);
      const status: ToneStatus = await client.applyCustom();
      Logger.info(MODULE, `补发选中成功 槽位=${status.toneId} 音量=${status.volume}`);
      CaseWriteService.scheduleAudioRestore(deviceId);
      return {
        ok: true, code: WriteCode.OK,
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

  private static describeFailure(error: Object): WriteResult {
    const toneError: ToneError = error as ToneError;
    const code: number = toneError.code !== undefined && toneError.code !== 0
      ? toneError.code : WriteCode.WRITE_FAILED;
    let message: string = toneError.message !== undefined && toneError.message.length > 0
      ? toneError.message : `写入失败（${code}），详见日志`;
    if (message === '已取消') {
      // 用户主动取消不会走到这里，链路断了才会，别把原因显示成"已取消"
      message = '写入被中断：耳机收回了串口，请合盖 3 秒后再开盖重试';
    }
    // 系统原生的 SPP 错误文案对用户没有意义，换成可执行的动作
    if (message.indexOf('SPP IO error') >= 0 || message.indexOf('BussinessError') >= 0) {
      message = '串口在传输中断开。耳机可能还在写入上一段音效，请合盖 3 秒后再开盖重试';
    }
    Logger.exception(MODULE, `写入失败 code=${code}：${message}`, error as BusinessError);
    return reject(WriteCode.WRITE_FAILED, message);
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
