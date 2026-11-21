import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { ToneSpec } from '../../common/constants/AppConstants';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { AppEvent, BusyState, EventBus } from '../../common/utils/EventBus';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { PrimaryButton } from '../../components/PrimaryButton';
import { SectionTitle } from '../../components/SectionTitle';
import { SpecRow } from '../../components/SpecRow';
import { StatPill } from '../../components/StatPill';
import { WaveformView } from '../../components/WaveformView';
import { ConvertOptions, ConvertResult, SourceAudio, SynthPreset, ToneEntry } from '../../models/ToneModel';
import { AudioConvertService } from '../../services/AudioConvertService';
import { AudioConvertTaskService } from '../../services/audio/ConvertTask';
import { AudioPlayService } from '../../services/AudioPlayService';
import { AudioSourceService } from '../../services/AudioSourceService';
import { BluetoothService } from '../../services/BluetoothService';
import { CaseWriteService,
  WriteCheck,
  WriteCode,
  WriteReason,
  WriteResult
} from '../../services/CaseWriteService';
import { ImportCancelledError, ImportControl, ImportProgressState } from '../../services/audio/ImportControl';
import { AppSettings, SettingsService } from '../../services/SettingsService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';
import { ToneSynthesizerService } from '../../services/ToneSynthesizerService';
import { NearLinkAlert } from '../../common/utils/NearLinkAlert';

const MODULE: string = 'TonePage';
/** 全段峰值缓存桶数：放大到 1 秒窗口时仍有足够细节 */
const FULL_PEAK_BUCKETS: number = 2048;
/** 每次绘制使用的桶数 */
const VIEW_PEAK_BUCKETS: number = 260;
/**
 * 波形最小可视窗口：保证「最大可截取时长」能完整落在视窗内，同时限制放大倍数。
 * 视窗随 ToneSpec.MAX_SECONDS 自动变化（上限调整后不必再单独改这里）。
 */
const MIN_VIEW_SPAN_MS: number = Math.ceil(ToneSpec.MAX_SECONDS * 1000) + 500;

@Component
export struct TonePage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State source: SourceAudio | undefined = undefined;
  @State peaks: number[] = [];
  /** 波形当前可视窗口（相对素材，毫秒） */
  @State viewStartMs: number = 0;
  @State viewSpanMs: number = 0;
  /** 全段峰值缓存，缩放时从这里聚合视窗柱形 */
  private fullPeaks: number[] = [];
  private waveWidth: number = 0;
  private pinchStartViewMs: number = 0;
  private pinchStartSpanMs: number = 0;
  private panStartViewMs: number = 0;
  @State startMs: number = 0;
  @State durationMs: number = 2000;
  @State gainDb: number = 0;
  @State fadeInMs: number = 40;
  @State fadeOutMs: number = 120;
  @State normalize: boolean = true;
  /** 自动增益开关：打开时按选区峰值自动设定增益，并锁定增益与归一化 */
  @State autoGain: boolean = false;
  @State busy: boolean = false;
  @State playingSource: boolean = false;
  @State playingTone: boolean = false;
  @State preparing: boolean = false;
  @State savedName: string = '';
  /** 生成后直接写入：进度与阶段，和音效库页保持同一套文案 */
  @State writing: boolean = false;
  @State writeRatio: number = 0;
  @State writeStage: string = '';

  /**
   * 转换结果缓存。
   *
   * 12 抽头 sinc 重采样一次要 1 秒以上（1.8s 素材约 1.4s），
   * 之前每次点试听、生成、导出都重算一遍，体感就是"点了半天才响"。
   * 参数没变时直接复用上一次结果，重复试听变成瞬时。
   */
  private cacheKey: string = '';
  private cached: ConvertResult | undefined = undefined;
  /** 用户设定的时长；起点右移被挤占后，拖回左侧时按这个值恢复 */
  private preferredDurationMs: number = 2000;
  /** 导入进度轮询计时器；-1 表示未运行 */
  private progressTimer: number = -1;
  /** 已展示过的最大进度：原生进度偶有回退，界面只允许单调向前 */
  private importProgressShown: number = 0;

  aboutToAppear(): void {
    const settings: AppSettings = SettingsService.get();
    this.durationMs = Math.min(ToneSpec.MAX_SECONDS * 1000, Math.max(300, settings.defaultDurationMs));
    this.preferredDurationMs = this.durationMs;
    this.gainDb = settings.defaultGainDb;
    this.normalize = settings.autoNormalize;
  }

  aboutToDisappear(): void {
    this.stopImportProgress();
    if (this.preparing) {
      ImportControl.cancel();
    }
    // 页面被销毁时别把全屏遮罩留在主界面上
    EventBus.emitText(AppEvent.BUSY_CHANGED, '');
    EventBus.resetBusy();
    AudioPlayService.stop().then(() => {
    }).catch((error: BusinessError) => {
      Logger.exception(MODULE, '释放播放资源失败', error);
    });
  }

  private abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private sourceName(): string {
    const current: SourceAudio | undefined = this.source;
    return current === undefined ? '' : current.name;
  }

  private sourceMeta(): string {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined) {
      return '';
    }
    return `${current.format} · ${FormatUtils.sampleRate(current.sampleRate)} · ` +
      `${FormatUtils.channelName(current.channels)} · ${FormatUtils.duration(current.durationMs)}`;
  }

  private sourceDurationMs(): number {
    const current: SourceAudio | undefined = this.source;
    return current === undefined ? 0 : current.durationMs;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  // ---------------- 导入 ----------------

  private async importAudio(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    ImportControl.begin();
    this.setBusy(true, I18n.t('tone.importing'));
    this.startImportProgress();
    // 先让遮罩画出来，选完文件后的复制 / 探测 / 解码可能要几秒
    await TonePage.yieldToUi();
    try {
      const imported: SourceAudio | null =
        await AudioSourceService.pickAndImport(this.abilityContext());
      if (imported === null) {
        return;
      }
      await AudioPlayService.stop();
      this.applySource(imported);
      if (imported.truncated) {
        this.toast(I18n.f('tone.importedTruncated', [imported.name]));
      } else {
        this.toast(I18n.f('tone.imported', [imported.name]));
      }
    } catch (error) {
      if (error instanceof ImportCancelledError) {
        Logger.info(MODULE, '用户取消导入');
        return;
      }
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE, '导入失败', businessError);
      this.toast(businessError.message !== undefined ? businessError.message : I18n.t('tone.importFailed'));
    } finally {
      this.stopImportProgress();
      ImportControl.finish();
      this.setBusy(false);
      this.busy = false;
    }
  }

  /** 导入期间的进度与剩余时间：原生解码有真实进度，探测/WAV 阶段退回不确定进度 */
  private startImportProgress(): void {
    this.stopImportProgress();
    this.importProgressShown = 0;
    this.progressTimer = setInterval((): void => {
      this.updateImportProgress();
    }, 250);
    this.updateImportProgress();
  }

  private stopImportProgress(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  private updateImportProgress(): void {
    const state: ImportProgressState = ImportControl.progress();
    if (!state.active) {
      const waiting: BusyState = {
        text: I18n.t('tone.importing'),
        detail: I18n.t('tone.importPreparing'),
        progress: -1,
        cancellable: true
      };
      EventBus.emitBusy(waiting);
      return;
    }
    let detail: string = I18n.t('tone.importDecoding');
    // 原生进度按实际时长算（见 audiodec 的 target），这里再做单调收敛与剩余时间平滑，
    // 避免解码器换帧时 progress 小幅回退、剩余时间跟着乱跳
    const raw: number = Math.max(0, Math.min(1, state.progress));
    const progress: number = Math.max(this.importProgressShown, raw);
    this.importProgressShown = progress;
    if (progress > 0.02 && state.elapsedMs > 500) {
      const remainMs: number = state.elapsedMs * (1 - progress) / progress;
      const seconds: number = Math.max(1, Math.min(600, Math.round(remainMs / 1000)));
      const percent: number = Math.min(99, Math.round(progress * 100));
      detail = `${percent}% · ${I18n.f('tone.importRemaining', [`${seconds}`])}`;
    }
    const decoding: BusyState = {
      text: I18n.t('tone.importing'),
      detail: detail,
      progress: progress > 0.02 ? progress : -1,
      cancellable: true
    };
    EventBus.emitBusy(decoding);
  }

  /**
   * 自动增益开关：
   * 打开后按当前选区峰值自动设定增益，并锁住增益滑块与峰值归一化开关；
   * 关闭后恢复手动调节（归一化保持关闭，用户可自行再开）。
   */
  private setAutoGain(enabled: boolean): void {
    this.autoGain = enabled;
    if (enabled) {
      // 自动增益按原电平计算，归一化必须让位，否则会被二次拉满
      this.normalize = false;
      this.refreshAutoGain(true);
    }
  }

  /**
   * 重新按当前选区峰值计算增益。
   * 参考 OpenFreebuds 的 peak_gain_db + “Set to the best volume”：
   * 先量峰值再换算 dB，而不是盲目拉满；峰值已经很高时改为衰减。
   * 留 0.9dB 余量给重采样过冲，避免写入后削顶。
   *
   * @param showToast 拖滑块时传 false，只在开关切换/导入完成时提示，避免每帧刷 toast
   */
  private refreshAutoGain(showToast: boolean): void {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined) {
      return;
    }
    const peak: number = AudioConvertService.peakAmplitude(current.pcm, this.startMs, this.durationMs);
    if (peak <= 0.0001) {
      if (showToast) {
        this.toast(I18n.t('tone.autoGainSilent'));
      }
      return;
    }
    const target: number = 0.9;
    const wanted: number = 20 * Math.log10(target / peak);
    const capped: boolean = wanted > 12;
    let db: number = Math.max(-12, Math.min(12, wanted));
    db = Math.round(db * 2) / 2;
    this.gainDb = db;
    if (showToast) {
      const signed: string = db > 0 ? `+${db}` : `${db}`;
      this.toast(I18n.f(capped ? 'tone.autoGainCapped' : 'tone.autoGainApplied', [signed]));
    }
  }

  private applySource(imported: SourceAudio): void {
    this.playingSource = false;
    this.playingTone = false;
    this.source = imported;
    this.fullPeaks = AudioConvertService.buildPeaks(imported.pcm, FULL_PEAK_BUCKETS).peaks;
    this.viewStartMs = 0;
    this.viewSpanMs = imported.durationMs;
    this.refreshViewPeaks();
    this.startMs = 0;
    this.durationMs = Math.min(this.durationMs,
      Math.min(ToneSpec.MAX_SECONDS * 1000,
        Math.max(ToneSpec.MIN_SECONDS * 1000, imported.durationMs)));
    this.preferredDurationMs = this.durationMs;
    this.savedName = '';
    if (this.autoGain) {
      this.refreshAutoGain(false);
    }
    Logger.info(MODULE, `音源已就绪：${imported.name}，峰值 ${this.fullPeaks.length} 段`);
  }

  private async usePreset(preset: SynthPreset): Promise<void> {
    this.busy = true;
    try {
      const pcm = ToneSynthesizerService.generate(preset.id);
      const synthSource: SourceAudio = {
        path: '',
        name: `${I18n.t(preset.nameKey)}${I18n.t('tone.builtinSuffix')}`,
        format: 'SYNTH / 48kHz',
        sampleRate: pcm.sampleRate,
        channels: pcm.channels,
        durationMs: pcm.frameCount * 1000 / pcm.sampleRate,
        truncated: false,
        pcm: pcm
      };
      await AudioPlayService.stop();
      this.applySource(synthSource);
      this.toast(I18n.f('tone.ready', [I18n.t(preset.nameKey)]));
    } catch (error) {
      Logger.exception(MODULE, '合成失败', error as BusinessError);
      this.toast(I18n.t('tone.synthFailed'));
    } finally {
      this.busy = false;
    }
  }

  // ---------------- 试听 ----------------

  private async playSource(): Promise<void> {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined || this.playingSource) {
      await AudioPlayService.stop();
      this.playingSource = false;
      return;
    }
    if (current.path.length === 0) {
      // 内置音色没有源文件，但合成 PCM 本身就是“原声”，按 48kHz 直接试听
      this.playingSource = true;
      this.playingTone = false;
      try {
        await AudioPlayService.playSourcePcm(current.pcm, (): void => {
          this.playingSource = false;
        });
      } catch (error) {
        this.playingSource = false;
        this.toast(I18n.t('tone.previewFailed'));
      }
      return;
    }
    this.playingSource = true;
    // 原声与盒音互斥：切到原声时把盒音的按钮一起熄灭
    this.playingTone = false;
    try {
      await AudioPlayService.playFile(current.path, (): void => {
        this.playingSource = false;
      });
    } catch (error) {
      this.playingSource = false;
      this.toast(I18n.t('tone.previewFailed'));
    }
  }

  private async playTone(): Promise<void> {
    if (this.playingTone) {
      await AudioPlayService.stop();
      this.playingTone = false;
      return;
    }
    const current: SourceAudio | undefined = this.source;
    if (current === undefined) {
      this.toast(I18n.t('tone.pickFirst'));
      return;
    }
    this.playingTone = true;
    // 原声与盒音互斥：切到盒音时把原声的按钮一起熄灭
    this.playingSource = false;
    try {
      let result: ConvertResult | undefined = this.cachedResult(current);
      if (result === undefined) {
        // 先让界面把"处理中"画出来，再执行这次耗时 1 秒以上的重采样
        this.setBusy(true, I18n.t('tone.generatingTone'));
        await TonePage.yieldToUi();
        result = await this.convertAndCache(current);
        this.setBusy(false);
      }
      if (!this.playingTone) {
        return;
      }
      const buffer: ArrayBuffer = result.buffer;
      await AudioPlayService.playRaw(buffer, (): void => {
        this.playingTone = false;
      });
    } catch (error) {
      this.setBusy(false);
      this.playingTone = false;
      Logger.exception(MODULE, '盒音试听失败', error as BusinessError);
      this.toast(I18n.t('tone.previewFailed'));
    }
  }

  /** 让出一次事件循环，让 @State 变化先落到界面上 */
  private static yieldToUi(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 16);
    });
  }

  private cacheSignature(current: SourceAudio): string {
    return `${current.path}|${current.name}|${current.pcm.frameCount}|${current.pcm.sampleRate}|` +
      `${this.startMs}|${this.durationMs}|${this.gainDb}|${this.fadeInMs}|${this.fadeOutMs}|${this.normalize}`;
  }

  private cachedResult(current: SourceAudio): ConvertResult | undefined {
    if (this.cached !== undefined && this.cacheKey === this.cacheSignature(current)) {
      return this.cached;
    }
    return undefined;
  }

  private async convertAndCache(current: SourceAudio): Promise<ConvertResult> {
    const result: ConvertResult = await AudioConvertTaskService.convertAsync(current.pcm, this.options());
    this.cacheKey = this.cacheSignature(current);
    this.cached = result;
    return result;
  }

  private options(): ConvertOptions {
    const options: ConvertOptions = {
      startMs: this.startMs,
      durationMs: this.durationMs,
      gainDb: this.gainDb,
      fadeInMs: this.fadeInMs,
      fadeOutMs: this.fadeOutMs,
      normalize: this.normalize
    };
    return options;
  }

  private currentName(): string {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined) {
      return I18n.t('tone.defaultName');
    }
    const base: string = current.name.replace(/\.[^.]+$/, '');
    return base.length > 0 ? base : I18n.t('tone.defaultName');
  }

  // ---------------- 生成 ----------------

  private async generateAndSave(): Promise<void> {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const result: ConvertResult = await this.prepareResult(current, I18n.t('tone.generating'));
      const entry: ToneEntry = ToneRepositoryService.save(this.currentName(), result, current.name);
      this.savedName = entry.name;
      EventBus.emit(AppEvent.TONE_CHANGED, 1);
      this.toast(I18n.f('tone.saved', [entry.name, FormatUtils.bytes(result.byteLength)]));
    } catch (error) {
      Logger.exception(MODULE, '生成失败', error as BusinessError);
      this.toast(I18n.t('tone.generateFailed'));
    } finally {
      this.setBusy(false);
      this.busy = false;
    }
  }

  private async generateAndExport(): Promise<void> {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const result: ConvertResult = await this.prepareResult(current, I18n.t('tone.generating'));
      const fileName: string = await ToneRepositoryService.exportBuffer(result.buffer,
        `${this.currentName()}-16k7`);
      if (fileName.length > 0) {
        this.toast(I18n.f('tone.exported', [fileName]));
      }
    } catch (error) {
      Logger.exception(MODULE, '导出失败', error as BusinessError);
      this.toast(I18n.t('tone.exportFailed'));
    } finally {
      this.setBusy(false);
      this.busy = false;
    }
  }

  /** 生成并保存，随后直接进入写入流程：写入前仍会做一次设备检查与确认 */
  private async generateAndWrite(): Promise<void> {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined || this.busy || this.writing) {
      return;
    }
    this.busy = true;
    try {
      const result: ConvertResult = await this.prepareResult(current, I18n.t('tone.generating'));
      const entry: ToneEntry = ToneRepositoryService.save(this.currentName(), result, current.name);
      this.savedName = entry.name;
      EventBus.emit(AppEvent.TONE_CHANGED, 1);
      await BluetoothService.refresh();
      const check: WriteCheck = CaseWriteService.check(entry);
      if (!check.ok) {
        if (check.code === WriteCode.NEARLINK_UNSUPPORTED) {
          this.toast(I18n.f('tone.saved', [entry.name, FormatUtils.bytes(result.byteLength)]));
          NearLinkAlert.show(this.getUIContext(), check.message);
          return;
        }
        this.getUIContext().showAlertDialog({
          title: I18n.t('tone.notWrittenTitle'),
          message: I18n.f('tone.notWrittenMessage', [entry.name, check.message]),
          confirm: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          }
        });
        return;
      }
      const writeHint: string = I18n.t('lib.writeHint');
      const hint: string = check.warn.length > 0 ? `${check.warn}\n${writeHint}` : writeHint;
      this.getUIContext().showAlertDialog({
        title: I18n.t('lib.writeTitle'),
        message: I18n.f('lib.writeMessage', [hint]),
        primaryButton: {
          value: I18n.t('common.cancel'),
          action: (): void => {
            this.toast(I18n.f('tone.saved', [entry.name, FormatUtils.bytes(result.byteLength)]));
          }
        },
        secondaryButton: {
          value: I18n.t('lib.startWrite'),
          fontColor: Palette.ACCENT,
          action: (): void => {
            this.runWrite(entry);
          }
        }
      });
    } catch (error) {
      Logger.exception(MODULE, '生成并写入失败', error as BusinessError);
      this.toast(I18n.t('tone.generateFailed'));
    } finally {
      this.setBusy(false);
      this.busy = false;
    }
  }

  private async runWrite(entry: ToneEntry): Promise<void> {
    this.writing = true;
    this.writeRatio = 0;
    this.writeStage = I18n.t('lib.stageConnect');
    await this.setKeepScreenOn(true);
    try {
      const result: WriteResult = await CaseWriteService.write(entry,
        (ratio: number, stage: string): void => {
          this.writeRatio = Math.round(ratio * 100);
          this.writeStage = stage;
        });
      if (result.ok) {
        this.writeRatio = 100;
        this.getUIContext().showAlertDialog({
          title: I18n.t('lib.writeDone'),
          message: I18n.f('lib.writeDoneMessage', [result.message]),
          confirm: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          }
        });
      } else {
        this.showWriteFailure(result);
      }
    } catch (error) {
      Logger.exception(MODULE, '写入异常', error as BusinessError);
      this.toast(I18n.t('lib.writeFailed'));
    } finally {
      this.writing = false;
      this.writeStage = '';
      this.writeRatio = 0;
      // 直接写入后音效库的「盒内」标记与列表需要立即跟上
      EventBus.emit(AppEvent.TONE_CHANGED, 1);
      await this.setKeepScreenOn(false);
      BluetoothService.refresh().then(() => {
      }).catch((error: BusinessError) => {
        Logger.warn(MODULE, `刷新蓝牙状态失败 code=${error.code}`);
      });
    }
  }

  /** 写入失败：不支持/格式被拒引导反馈，其余失败给一段可执行的重试说明 */
  private showWriteFailure(result: WriteResult): void {
    const needReport: boolean = result.reason === WriteReason.UNSUPPORTED ||
      result.reason === WriteReason.FORMAT;
    this.getUIContext().showAlertDialog({
      title: needReport ? I18n.t('lib.unsupportedTitle') : I18n.t('lib.writeIncomplete'),
      message: `${result.message}\n\n${I18n.f('lib.errorCode', [`${result.code}`])}`,
      primaryButton: {
        value: I18n.t('common.ok'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.viewLog'),
        fontColor: Palette.ACCENT,
        action: (): void => {
          EventBus.emit(AppEvent.OPEN_LOG, 1);
        }
      }
    });
  }

  /** 擦写阶段可能持续几十秒，熄屏后应用被挂起会掐断串口 */
  private async setKeepScreenOn(on: boolean): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.abilityContext();
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowKeepScreenOn(on);
    } catch (error) {
      Logger.warn(MODULE, `设置屏幕常亮失败 on=${on} code=${(error as BusinessError).code}`);
    }
  }

  /** 缓存未命中时先亮出遮罩再算，避免点下去到出结果之间界面像死了一样 */
  private async prepareResult(current: SourceAudio, text: string): Promise<ConvertResult> {
    const hit: ConvertResult | undefined = this.cachedResult(current);
    if (hit !== undefined) {
      return hit;
    }
    this.setBusy(true, text);
    await TonePage.yieldToUi();
    const result: ConvertResult = await this.convertAndCache(current);
    this.setBusy(false);
    return result;
  }

  /** 全屏遮罩由 Index 统一绘制（能盖住状态栏），页面只负责发指令 */
  private setBusy(busy: boolean, text: string = ''): void {
    this.preparing = busy;
    EventBus.emitText(AppEvent.BUSY_CHANGED, busy ? text : '');
    if (!busy) {
      EventBus.resetBusy();
    }
  }

  // ---------------- UI ----------------

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildSourceCard()
        this.buildPresetSection()
        this.buildWaveCard()
        this.buildParamCard()
        this.buildSpecCard()
        this.buildActions()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Metric.PAGE_PADDING,
        right: Metric.PAGE_PADDING,
        top: 8,
        bottom: Metric.CONTENT_BOTTOM_INSET
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  buildHeader() {
    Column({ space: 6 }) {
      Text(I18n.t('tone.title'))
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(I18n.t('tone.subtitle'))
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 4 })
  }

  @Builder
  buildSourceCard() {
    if (this.source === undefined) {
      Column({ space: 10 }) {
        Stack() {
          Circle()
            .width(56)
            .height(56)
            .fill(Palette.ACCENT_SOFT)
          Image($r('app.media.ic_upload'))
            .width(24)
            .height(24)
            .fillColor(Palette.ACCENT_TEXT)
        }
        Text(I18n.t('tone.importTitle'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.t('tone.importDesc'))
          .fontSize(11)
          .fontColor(Palette.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .lineHeight(17)
      }
      .width('100%')
      .padding({ top: 26, bottom: 26 })
      .alignItems(HorizontalAlign.Center)
      .borderRadius(Metric.CARD_RADIUS)
      .backgroundColor(Palette.BG_INPUT)
      .border({ width: 1, color: 'rgba(78, 216, 255, 0.24)', style: BorderStyle.Dashed })
      .onClick(() => {
        this.importAudio();
      })
    } else {
      GlassCard({ cardPadding: 16 }) {
        Row({ space: 12 }) {
          Stack() {
            Circle()
              .width(42)
              .height(42)
              .fill(Palette.ACCENT_SOFT)
            Image($r('app.media.ic_tab_tone'))
              .width(20)
              .height(20)
              .fillColor(Palette.ACCENT_TEXT)
          }

          Column({ space: 4 }) {
            Text(this.sourceName())
              .fontSize(14)
              .fontColor(Palette.TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.sourceMeta())
              .fontSize(10)
              .fontColor(Palette.TEXT_TERTIARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(I18n.t('tone.replace'))
            .fontSize(11)
            .fontColor(Palette.ACCENT_TEXT)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(999)
            .backgroundColor(Palette.ACCENT_SOFT)
            .onClick(() => {
              this.importAudio();
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          PreviewChip({
            chipLabel: I18n.t('tone.original'),
            active: this.playingSource,
            onTap: (): void => {
              this.playSource();
            }
          })
          PreviewChip({
            chipLabel: I18n.t('tone.caseTone'),
            active: this.playingTone,
            busy: this.preparing,
            onTap: (): void => {
              this.playTone();
            }
          })
        }
        .width('100%')
        .margin({ top: 14 })
      }
    }
  }

  @Builder
  buildPresetSection() {
    SectionTitle({ sectionText: I18n.t('tone.presets'), sectionHint: I18n.t('tone.presetsHint') })

    Scroll() {
      Row({ space: 8 }) {
        ForEach(ToneSynthesizerService.PRESETS, (preset: SynthPreset) => {
          Column({ space: 3 }) {
            Text(I18n.t(preset.nameKey))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_PRIMARY)
            Text(I18n.t(preset.descKey))
              .fontSize(9)
              .fontColor(Palette.TEXT_TERTIARY)
              .maxLines(1)
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(16)
          .backgroundColor(Palette.BG_CARD)
          .border({ width: 1, color: Palette.STROKE_SOFT })
          .onClick(() => {
            this.usePreset(preset);
          })
        }, (preset: SynthPreset) => preset.id)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  buildWaveCard() {
    GlassCard({ cardPadding: 16 }) {
      Row() {
        Text(this.source === undefined ? I18n.t('tone.noSource') : I18n.t('tone.waveTitle'))
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .layoutWeight(1)
        if (this.source !== undefined) {
          StatPill({
            pillText: `${FormatUtils.seconds(this.durationMs)} / ${FormatUtils.seconds(this.sourceDurationMs())}`,
            pillTone: 'accent',
            compact: true
          })
        }
      }
      .width('100%')
      .margin({ bottom: 12 })

      Stack() {
        WaveformView({
          peaks: this.peaks,
          startRatio: this.startRatio(),
          endRatio: this.endRatio(),
          viewStartRatio: this.viewStartRatio(),
          viewEndRatio: this.viewEndRatio(),
          hasSelection: this.peaks.length > 0,
          waveHeight: 88
        })
      }
      .width('100%')
      .onAreaChange((oldValue: Area, newValue: Area): void => {
        this.waveWidth = newValue.width as number;
      })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture({ fingers: 2 })
            .onActionStart((): void => {
              this.pinchStartViewMs = this.viewStartMs;
              this.pinchStartSpanMs = this.viewSpanMs;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.zoomWave(event.scale, event.pinchCenterX);
            }),
          PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
            .onActionStart((): void => {
              this.panStartViewMs = this.viewStartMs;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.panWave(event.offsetX);
            }),
          PanGesture({ fingers: 2, distance: 5 })
            .onActionStart((): void => {
              this.panStartViewMs = this.viewStartMs;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.panWave(event.offsetX);
            }),
          TapGesture({ count: 2 })
            .onAction((): void => {
              this.resetWaveView();
            })
        )
      )

      Row() {
        Text(FormatUtils.seconds(this.viewStartMs))
          .fontSize(9)
          .fontColor(Palette.TEXT_TERTIARY)
        Blank()
        Text(FormatUtils.seconds(this.viewStartMs + this.viewSpanMs))
          .fontSize(9)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.peaks.length > 0) {
        Text(I18n.t('tone.waveZoomHint'))
          .fontSize(9)
          .fontColor(Palette.TEXT_TERTIARY)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })
      }
    }
  }

  @Builder
  buildParamCard() {
    GlassCard({ cardPadding: 16 }) {
      SliderBlock({
        blockLabel: I18n.t('tone.start'),
        blockText: FormatUtils.seconds(this.startMs),
        blockValue: this.startMs,
        blockMax: this.maxStartMs(),
        onValue: (value: number): void => {
          const total: number = this.sourceDurationMs();
          const remain: number = Math.max(ToneSpec.MIN_SECONDS * 1000, total - value);
          this.startMs = value;
          // 起点右移挤占时长时先压缩，拖回左侧再恢复用户原本设定的时长，
          // 避免「动一下起点、时长就永久变成 0.2s」这种手感
          if (this.durationMs > remain) {
            this.durationMs = remain;
          } else if (this.durationMs < this.preferredDurationMs) {
            this.durationMs = Math.min(this.preferredDurationMs, remain);
          }
          this.ensureSelectionVisible();
        },
        onValueEnd: (value: number): void => {
          if (this.autoGain) {
            this.refreshAutoGain(false);
          }
        }
      })

      SliderBlock({
        blockLabel: I18n.t('tone.duration'),
        blockText: FormatUtils.seconds(this.durationMs),
        blockValue: this.durationMs,
        blockMin: ToneSpec.MIN_SECONDS * 1000,
        blockMax: this.durationMaxMs(),
        onValue: (value: number): void => {
          this.durationMs = value;
          this.preferredDurationMs = value;
          this.ensureSelectionVisible();
        },
        onValueEnd: (value: number): void => {
          if (this.autoGain) {
            this.refreshAutoGain(false);
          }
        }
      })

      SliderBlock({
        blockLabel: I18n.t('tone.gain'),
        blockText: FormatUtils.gain(this.gainDb),
        blockValue: this.gainDb,
        blockMin: -12,
        blockMax: 12,
        blockStep: 0.5,
        blockEnabled: !this.autoGain,
        blockToggle: true,
        blockToggleValue: this.autoGain,
        onToggle: (isOn: boolean): void => {
          this.setAutoGain(isOn);
        },
        onValue: (value: number): void => {
          this.gainDb = value;
        }
      })

      Row({ space: 24 }) {
        ToggleBlock({
          blockLabel: I18n.t('tone.normalize'),
          blockOn: this.normalize,
          blockEnabled: !this.autoGain,
          onSwitch: (isOn: boolean): void => {
            if (this.autoGain) {
              return;
            }
            this.normalize = isOn;
            // 与音效生成入口放在一起，同时作为下次进入的默认值持久化
            SettingsService.setAutoNormalize(isOn);
          }
        })
        ToggleBlock({
          blockLabel: I18n.t('tone.fade'),
          blockOn: this.fadeInMs > 0,
          onSwitch: (isOn: boolean): void => {
            this.fadeInMs = isOn ? 40 : 0;
            this.fadeOutMs = isOn ? 120 : 0;
          }
        })
      }
      .width('100%')
      .margin({ top: 6 })
    }
  }

  @Builder
  buildSpecCard() {
    GlassCard({ cardPadding: 18 }) {
      Row() {
        Text(I18n.t('tone.outputSpec'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        StatPill({
          pillText: this.isCompliant() ? I18n.t('tone.compliant') : I18n.t('tone.overLimit'),
          pillTone: this.isCompliant() ? 'success' : 'danger',
          compact: true
        })
      }
      .width('100%')
      .margin({ bottom: 6 })

      SpecRow({ specLabel: I18n.t('tone.codec'), specValue: 'Signed 16-bit PCM', showDivider: true })
      SpecRow({ specLabel: I18n.t('tone.channels'), specValue: I18n.t('tone.channelsValue'), showDivider: true })
      SpecRow({ specLabel: I18n.t('tone.sampleRate'), specValue: '16700 Hz', showDivider: true })
      SpecRow({ specLabel: I18n.t('tone.fileFormat'), specValue: I18n.t('tone.fileFormatValue'), showDivider: true })
      SpecRow({
        specLabel: I18n.t('tone.outputSize'),
        specValue: I18n.f('tone.byteCount', [`${AudioConvertService.estimateBytes(this.durationMs)}`]),
        valueColor: Palette.ACCENT
      })

      Text(I18n.f('tone.sizeRule', [`${ToneSpec.BYTES_PER_SECOND}`, `${ToneSpec.MAX_SECONDS}`,
        `${ToneSpec.MAX_BYTES}`]))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .margin({ top: 8 })
    }
  }

  @Builder
  buildActions() {
    Column({ space: 10 }) {
      if (this.writing) {
        Column({ space: 6 }) {
          Row() {
            Text(this.writeStage.length > 0 ? this.writeStage : I18n.t('lib.writingStage'))
              .fontSize(11)
              .fontColor(Palette.ACCENT_TEXT)
              .layoutWeight(1)
            Text(`${this.writeRatio}%`)
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
          }
          .width('100%')

          Progress({ value: this.writeRatio, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color(Palette.ACCENT)
            .backgroundColor(Palette.FILL_SOFT)
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      }

      PrimaryButton({
        btnLabel: I18n.t('tone.saveAndWriteButton'),
        btnEnabled: this.source !== undefined && !this.writing,
        btnLoading: this.busy || this.writing,
        btnIcon: $r('app.media.ic_check'),
        onTap: (): void => {
          this.generateAndWrite();
        }
      })

      GhostButton({
        ghostLabel: I18n.t('tone.saveButton'),
        ghostEnabled: this.source !== undefined && !this.writing,
        ghostIcon: $r('app.media.ic_add'),
        onTap: (): void => {
          this.generateAndSave();
        }
      })

      GhostButton({
        ghostLabel: I18n.t('tone.exportButton'),
        ghostEnabled: this.source !== undefined && !this.writing,
        ghostIcon: $r('app.media.ic_upload'),
        onTap: (): void => {
          this.generateAndExport();
        }
      })

      Text(I18n.t('tone.writeHint'))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 2 })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  private startRatio(): number {
    const total: number = this.sourceDurationMs();
    if (total <= 0) {
      return 0;
    }
    return Math.min(1, this.startMs / total);
  }

  private viewStartRatio(): number {
    const total: number = this.sourceDurationMs();
    return total <= 0 ? 0 : Math.min(1, this.viewStartMs / total);
  }

  private viewEndRatio(): number {
    const total: number = this.sourceDurationMs();
    return total <= 0 ? 1 : Math.min(1, (this.viewStartMs + this.viewSpanMs) / total);
  }

  /** 从全段峰值缓存聚合出当前视窗的柱形 */
  private refreshViewPeaks(): void {
    const total: number = this.sourceDurationMs();
    if (total <= 0 || this.fullPeaks.length === 0) {
      this.peaks = [];
      return;
    }
    const minSpan: number = Math.min(MIN_VIEW_SPAN_MS, total);
    const span: number = Math.max(minSpan, Math.min(this.viewSpanMs > 0 ? this.viewSpanMs : total, total));
    const start: number = Math.max(0, Math.min(this.viewStartMs, total - span));
    this.viewSpanMs = span;
    this.viewStartMs = start;

    const cacheLength: number = this.fullPeaks.length;
    const from: number = start / total * cacheLength;
    const to: number = (start + span) / total * cacheLength;
    // 缓存分辨率不足时（放到 1 秒窗口只剩个位数桶）按比例展开到固定柱数，
    // 否则放大后柱子会变得又粗又少，看起来像没数据
    const rawCount: number = Math.max(1, Math.floor(to - from));
    const count: number = Math.min(VIEW_PEAK_BUCKETS, rawCount);
    const bucketSpan: number = (to - from) / count;
    const out: number[] = [];
    for (let b = 0; b < count; b++) {
      const bucketStart: number = Math.floor(from + b * bucketSpan);
      const bucketEnd: number = Math.min(cacheLength,
        Math.max(bucketStart + 1, Math.floor(from + (b + 1) * bucketSpan)));
      let localMax: number = 0;
      for (let i = bucketStart; i < bucketEnd; i++) {
        if (this.fullPeaks[i] > localMax) {
          localMax = this.fullPeaks[i];
        }
      }
      out.push(localMax);
    }
    if (out.length < VIEW_PEAK_BUCKETS) {
      const expanded: number[] = [];
      for (let i = 0; i < VIEW_PEAK_BUCKETS; i++) {
        const source: number = Math.min(out.length - 1,
          Math.floor(i * out.length / VIEW_PEAK_BUCKETS));
        expanded.push(out[source]);
      }
      this.peaks = expanded;
      return;
    }
    this.peaks = out;
  }

  /** 双指捏合：以捏合中心为锚点缩放 */
  private zoomWave(scale: number, centerX: number): void {
    const total: number = this.sourceDurationMs();
    if (total <= 0 || scale <= 0) {
      return;
    }
    const width: number = this.waveWidth > 0 ? this.waveWidth : 300;
    const centerRatio: number = Math.max(0, Math.min(1, centerX / width));
    const baseSpan: number = this.pinchStartSpanMs > 0 ? this.pinchStartSpanMs : this.viewSpanMs;
    const baseStart: number = this.pinchStartViewMs;
    const minSpan: number = Math.min(MIN_VIEW_SPAN_MS, total);
    const nextSpan: number = Math.max(minSpan, Math.min(baseSpan / scale, total));
    const centerMs: number = baseStart + centerRatio * baseSpan;
    const nextStart: number = Math.max(0,
      Math.min(centerMs - centerRatio * nextSpan, total - nextSpan));
    this.viewStartMs = nextStart;
    this.viewSpanMs = nextSpan;
    this.refreshViewPeaks();
  }

  /** 双指拖动：按当前视窗宽度换算水平位移 */
  private panWave(offsetX: number): void {
    const total: number = this.sourceDurationMs();
    if (total <= 0) {
      return;
    }
    const width: number = this.waveWidth > 0 ? this.waveWidth : 300;
    const span: number = this.viewSpanMs > 0 ? this.viewSpanMs : total;
    const delta: number = -offsetX / width * span;
    this.viewStartMs = Math.max(0, Math.min(this.panStartViewMs + delta, total - span));
    this.refreshViewPeaks();
  }

  /** 双击恢复全段视图 */
  private resetWaveView(): void {
    const total: number = this.sourceDurationMs();
    if (total <= 0) {
      return;
    }
    this.viewStartMs = 0;
    this.viewSpanMs = total;
    this.refreshViewPeaks();
  }

  /** 选区被微调挤出视窗时，把视图移回选区中心 */
  private ensureSelectionVisible(): void {
    const total: number = this.sourceDurationMs();
    if (total <= 0 || this.viewSpanMs <= 0) {
      return;
    }
    const selectionEnd: number = Math.min(total, this.startMs + this.durationMs);
    if (this.startMs >= this.viewStartMs &&
      selectionEnd <= this.viewStartMs + this.viewSpanMs) {
      return;
    }
    const span: number = Math.min(this.viewSpanMs, total);
    const center: number = (this.startMs + selectionEnd) / 2;
    this.viewStartMs = Math.max(0, Math.min(center - span / 2, total - span));
    this.refreshViewPeaks();
  }

  private endRatio(): number {
    const total: number = this.sourceDurationMs();
    if (total <= 0) {
      return 0;
    }
    return Math.min(1, (this.startMs + this.durationMs) / total);
  }

  private maxStartMs(): number {
    return Math.max(0, this.sourceDurationMs() - ToneSpec.MIN_SECONDS * 1000);
  }

  /** 时长上限：既不超过盒端规格，也不超过当前起点之后的素材长度 */
  private durationMaxMs(): number {
    const total: number = this.sourceDurationMs();
    if (total <= 0) {
      return ToneSpec.MAX_SECONDS * 1000;
    }
    const remain: number = total - this.startMs;
    return Math.min(ToneSpec.MAX_SECONDS * 1000,
      Math.max(ToneSpec.MIN_SECONDS * 1000, remain));
  }

  private isCompliant(): boolean {
    return this.durationMs <= ToneSpec.MAX_SECONDS * 1000 &&
      AudioConvertService.estimateBytes(this.durationMs) <= ToneSpec.MAX_BYTES;
  }
}

/** 预览按钮：播放态需要跟随状态刷新，@Builder 按值传参不会刷新，故独立成组件 */
@Component
struct PreviewChip {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop chipLabel: string = '';
  @Prop active: boolean = false;
  @Prop busy: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 6 }) {
      Image(this.active ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
        .width(11)
        .height(11)
        .fillColor(this.active ? '#05080E' : Palette.TEXT_SECONDARY)
      Text(this.busy ? I18n.t('common.processing') : this.chipLabel)
        .fontSize(12)
        .fontColor(this.active ? '#05080E' : Palette.TEXT_SECONDARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.active ? Palette.ACCENT : Palette.FILL_FAINT)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 滑块行：数值文案与滑块位置需要随状态刷新 */
@Component
struct SliderBlock {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop blockLabel: string = '';
  @Prop blockText: string = '';
  @Prop blockValue: number = 0;
  @Prop blockMin: number = 0;
  @Prop blockMax: number = 100;
  @Prop blockStep: number = 10;
  @Prop blockEnabled: boolean = true;
  /** 在数值左侧内嵌一个开关（增益行的“自动”） */
  @Prop blockToggle: boolean = false;
  @Prop blockToggleValue: boolean = false;
  onToggle: (isOn: boolean) => void = () => {
  };
  onValue: (value: number) => void = () => {
  };
  /** 松手/点击轨道后触发，用于自动增益这类不适合每帧重算的逻辑 */
  onValueEnd: (value: number) => void = () => {
  };

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.blockLabel)
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .layoutWeight(1)
        if (this.blockToggle) {
          Text(I18n.t('tone.autoGain'))
            .fontSize(10)
            .fontColor(this.blockToggleValue ? Palette.ACCENT_TEXT : Palette.TEXT_TERTIARY)
            .margin({ right: 3 })
          Toggle({ type: ToggleType.Switch, isOn: this.blockToggleValue })
            .width(40)
            .height(22)
            .selectedColor(Palette.ACCENT)
            .margin({ right: 8 })
            .onChange((next: boolean) => {
              this.onToggle(next);
            })
        }
        Text(this.blockText)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.blockEnabled ? Palette.ACCENT_TEXT : Palette.TEXT_TERTIARY)
      }
      .width('100%')

      Slider({
        value: this.blockValue,
        min: this.blockMin,
        max: this.blockMax,
        step: this.blockStep,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .trackColor(Palette.FILL_SOFT)
        .selectedColor(Palette.ACCENT)
        .blockColor('#FFFFFF')
        .enabled(this.blockEnabled)
        .opacity(this.blockEnabled ? 1 : 0.4)
        .onChange((next: number, mode: SliderChangeMode) => {
          const value: number = Math.round(next * 10) / 10;
          this.onValue(value);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onValueEnd(value);
          }
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }
}

/** 开关行：开关状态需要随状态刷新 */
@Component
struct ToggleBlock {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop blockLabel: string = '';
  @Prop blockOn: boolean = false;
  @Prop blockEnabled: boolean = true;
  onSwitch: (isOn: boolean) => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      Text(this.blockLabel)
        .fontSize(12)
        .fontColor(this.blockEnabled ? Palette.TEXT_SECONDARY : Palette.TEXT_TERTIARY)
      Toggle({ type: ToggleType.Switch, isOn: this.blockOn })
        .selectedColor(Palette.ACCENT)
        .enabled(this.blockEnabled)
        .opacity(this.blockEnabled ? 1 : 0.4)
        .onChange((next: boolean) => {
          this.onSwitch(next);
        })
    }
  }
}
