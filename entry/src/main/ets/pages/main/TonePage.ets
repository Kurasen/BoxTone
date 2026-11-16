import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { ToneSpec } from '../../common/constants/AppConstants';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { AppEvent, EventBus } from '../../common/utils/EventBus';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { PrimaryButton } from '../../components/PrimaryButton';
import { SectionTitle } from '../../components/SectionTitle';
import { SpecRow } from '../../components/SpecRow';
import { StatPill } from '../../components/StatPill';
import { WaveformView } from '../../components/WaveformView';
import { ConvertOptions, ConvertResult, SourceAudio, SynthPreset, ToneEntry } from '../../models/ToneModel';
import { AudioConvertService } from '../../services/AudioConvertService';
import { AudioPlayService } from '../../services/AudioPlayService';
import { AudioSourceService } from '../../services/AudioSourceService';
import { AppSettings, SettingsService } from '../../services/SettingsService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';
import { ToneSynthesizerService } from '../../services/ToneSynthesizerService';

const MODULE: string = 'TonePage';

@Component
export struct TonePage {
  @State source: SourceAudio | undefined = undefined;
  @State peaks: number[] = [];
  @State startMs: number = 0;
  @State durationMs: number = 2000;
  @State gainDb: number = 0;
  @State fadeInMs: number = 40;
  @State fadeOutMs: number = 120;
  @State normalize: boolean = true;
  @State busy: boolean = false;
  @State playingSource: boolean = false;
  @State playingTone: boolean = false;
  @State preparing: boolean = false;
  @State savedName: string = '';

  /**
   * 转换结果缓存。
   *
   * 12 抽头 sinc 重采样一次要 1 秒以上（1.8s 素材约 1.4s），
   * 之前每次点试听、生成、导出都重算一遍，体感就是"点了半天才响"。
   * 参数没变时直接复用上一次结果，重复试听变成瞬时。
   */
  private cacheKey: string = '';
  private cached: ConvertResult | undefined = undefined;

  aboutToAppear(): void {
    const settings: AppSettings = SettingsService.get();
    this.durationMs = Math.min(ToneSpec.MAX_SECONDS * 1000, Math.max(300, settings.defaultDurationMs));
    this.gainDb = settings.defaultGainDb;
    this.normalize = settings.autoNormalize;
  }

  aboutToDisappear(): void {
    // 页面被销毁时别把全屏遮罩留在主界面上
    EventBus.emitText(AppEvent.BUSY_CHANGED, '');
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

  private sourceDurationText(): string {
    const current: SourceAudio | undefined = this.source;
    return current === undefined ? '' : FormatUtils.duration(current.durationMs);
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
    this.setBusy(true, '正在导入音频…');
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
        this.toast(`已导入 ${imported.name}，文件较长，只载入了开头一段`);
      } else {
        this.toast(`已导入 ${imported.name}`);
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      Logger.exception(MODULE, '导入失败', businessError);
      this.toast(businessError.message !== undefined ? businessError.message : '导入失败');
    } finally {
      this.setBusy(false);
      this.busy = false;
    }
  }

  private applySource(imported: SourceAudio): void {
    this.playingSource = false;
    this.playingTone = false;
    this.source = imported;
    const wave = AudioConvertService.buildPeaks(imported.pcm, 260);
    this.peaks = wave.peaks;
    this.startMs = 0;
    this.durationMs = Math.min(this.durationMs,
      Math.min(ToneSpec.MAX_SECONDS * 1000,
        Math.max(ToneSpec.MIN_SECONDS * 1000, imported.durationMs)));
    this.savedName = '';
    Logger.info(MODULE, `音源已就绪：${imported.name}，峰值 ${wave.peaks.length} 段`);
  }

  private async usePreset(preset: SynthPreset): Promise<void> {
    this.busy = true;
    try {
      const pcm = ToneSynthesizerService.generate(preset.id);
      const synthSource: SourceAudio = {
        path: '',
        name: `${preset.name}（内置音色）`,
        format: 'SYNTH / 48kHz',
        sampleRate: pcm.sampleRate,
        channels: pcm.channels,
        durationMs: pcm.frameCount * 1000 / pcm.sampleRate,
        truncated: false,
        pcm: pcm
      };
      await AudioPlayService.stop();
      this.applySource(synthSource);
      this.toast(`${preset.name} 已就绪`);
    } catch (error) {
      Logger.exception(MODULE, '合成失败', error as BusinessError);
      this.toast('生成音色失败');
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
      // 内置音色没有源文件，直接试听转换后的结果
      await this.playTone();
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
      this.toast('试听失败');
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
      this.toast('请先导入音频或选择内置音色');
      return;
    }
    this.playingTone = true;
    // 原声与盒音互斥：切到盒音时把原声的按钮一起熄灭
    this.playingSource = false;
    try {
      let result: ConvertResult | undefined = this.cachedResult(current);
      if (result === undefined) {
        // 先让界面把"处理中"画出来，再执行这次耗时 1 秒以上的重采样
        this.setBusy(true, '正在生成盒音…');
        await TonePage.yieldToUi();
        result = this.convertAndCache(current);
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
      this.toast('试听失败');
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

  private convertAndCache(current: SourceAudio): ConvertResult {
    const result: ConvertResult = AudioConvertService.convert(current.pcm, this.options());
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
      return '开盖音效';
    }
    const base: string = current.name.replace(/\.[^.]+$/, '');
    return base.length > 0 ? base : '开盖音效';
  }

  // ---------------- 生成 ----------------

  private async generateAndSave(): Promise<void> {
    const current: SourceAudio | undefined = this.source;
    if (current === undefined || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const result: ConvertResult = await this.prepareResult(current, '正在生成…');
      const entry: ToneEntry = ToneRepositoryService.save(this.currentName(), result, current.name);
      this.savedName = entry.name;
      EventBus.emit(AppEvent.TONE_CHANGED, 1);
      this.toast(`已保存「${entry.name}」${FormatUtils.bytes(result.byteLength)}`);
    } catch (error) {
      Logger.exception(MODULE, '生成失败', error as BusinessError);
      this.toast('生成失败，请查看日志');
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
      const result: ConvertResult = await this.prepareResult(current, '正在生成…');
      const fileName: string = await ToneRepositoryService.exportBuffer(result.buffer,
        `${this.currentName()}-16k7`);
      if (fileName.length > 0) {
        this.toast(`已导出 ${fileName}`);
      }
    } catch (error) {
      Logger.exception(MODULE, '导出失败', error as BusinessError);
      this.toast('导出失败，请查看日志');
    } finally {
      this.setBusy(false);
      this.busy = false;
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
    const result: ConvertResult = this.convertAndCache(current);
    this.setBusy(false);
    return result;
  }

  /** 全屏遮罩由 Index 统一绘制（能盖住状态栏），页面只负责发指令 */
  private setBusy(busy: boolean, text: string = ''): void {
    this.preparing = busy;
    EventBus.emitText(AppEvent.BUSY_CHANGED, busy ? text : '');
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
      Text('音效')
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('按充电盒解码规格生成无文件头原始波形')
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
            .fillColor(Palette.ACCENT)
        }
        Text('导入音频素材')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text('支持 MP3 / M4A / AAC / FLAC / OGG / WAV 等主流格式\n导入后自动转成 16700Hz 单声道，只需截取其中一段')
          .fontSize(11)
          .fontColor(Palette.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .lineHeight(17)
      }
      .width('100%')
      .padding({ top: 26, bottom: 26 })
      .alignItems(HorizontalAlign.Center)
      .borderRadius(Metric.CARD_RADIUS)
      .backgroundColor('rgba(255, 255, 255, 0.03)')
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
              .fillColor(Palette.ACCENT)
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

          Text('更换')
            .fontSize(11)
            .fontColor(Palette.ACCENT)
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
            chipLabel: '原声',
            active: this.playingSource,
            onTap: (): void => {
              this.playSource();
            }
          })
          PreviewChip({
            chipLabel: '盒音 16.7kHz',
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
    SectionTitle({ sectionText: '内置音色', sectionHint: '点选即可生成' })

    Scroll() {
      Row({ space: 8 }) {
        ForEach(ToneSynthesizerService.PRESETS, (preset: SynthPreset) => {
          Column({ space: 3 }) {
            Text(preset.name)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT_PRIMARY)
            Text(preset.desc)
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
        Text(this.source === undefined ? '尚未导入音频' : '波形与裁剪区间')
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

      WaveformView({
        peaks: this.peaks,
        startRatio: this.startRatio(),
        endRatio: this.endRatio(),
        hasSelection: this.peaks.length > 0,
        waveHeight: 88
      })

      Row() {
        Text('0.0s')
          .fontSize(9)
          .fontColor(Palette.TEXT_TERTIARY)
        Blank()
        Text(this.sourceDurationText())
          .fontSize(9)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .width('100%')
      .margin({ top: 8 })
    }
  }

  @Builder
  buildParamCard() {
    GlassCard({ cardPadding: 16 }) {
      SliderBlock({
        blockLabel: '起始位置',
        blockText: FormatUtils.seconds(this.startMs),
        blockValue: this.startMs,
        blockMax: this.maxStartMs(),
        onValue: (value: number): void => {
          this.startMs = value;
          // 起点后移后剩余素材变短，时长跟着收，避免选区超出素材
          const maxDuration: number = this.durationMaxMs();
          if (this.durationMs > maxDuration) {
            this.durationMs = maxDuration;
          }
        }
      })

      SliderBlock({
        blockLabel: '时长',
        blockText: FormatUtils.seconds(this.durationMs),
        blockValue: this.durationMs,
        blockMin: ToneSpec.MIN_SECONDS * 1000,
        blockMax: this.durationMaxMs(),
        onValue: (value: number): void => {
          this.durationMs = value;
        }
      })

      SliderBlock({
        blockLabel: '增益',
        blockText: FormatUtils.gain(this.gainDb),
        blockValue: this.gainDb,
        blockMin: -12,
        blockMax: 12,
        blockStep: 0.5,
        onValue: (value: number): void => {
          this.gainDb = value;
        }
      })

      Row({ space: 24 }) {
        ToggleBlock({
          blockLabel: '峰值归一化',
          blockOn: this.normalize,
          onSwitch: (isOn: boolean): void => {
            this.normalize = isOn;
          }
        })
        ToggleBlock({
          blockLabel: '首尾淡入淡出',
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
        Text('输出规格')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
          .layoutWeight(1)
        StatPill({
          pillText: this.isCompliant() ? '符合盒端规格' : '超出限制',
          pillTone: this.isCompliant() ? 'success' : 'danger',
          compact: true
        })
      }
      .width('100%')
      .margin({ bottom: 6 })

      SpecRow({ specLabel: '编码', specValue: 'Signed 16-bit PCM', showDivider: true })
      SpecRow({ specLabel: '声道', specValue: 'Mono 单通道', showDivider: true })
      SpecRow({ specLabel: '采样率', specValue: '16700 Hz', showDivider: true })
      SpecRow({ specLabel: '文件格式', specValue: 'RAW 无文件头', showDivider: true })
      SpecRow({
        specLabel: '输出大小',
        specValue: `${AudioConvertService.estimateBytes(this.durationMs)} 字节`,
        valueColor: Palette.ACCENT
      })

      Text(`1 秒 = ${ToneSpec.BYTES_PER_SECOND} 字节，上限 ${ToneSpec.MAX_SECONDS} 秒 / ` +
        `${ToneSpec.MAX_BYTES} 字节`)
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .margin({ top: 8 })
    }
  }

  @Builder
  buildActions() {
    Column({ space: 10 }) {
      PrimaryButton({
        btnLabel: '生成并保存到音效库',
        btnEnabled: this.source !== undefined,
        btnLoading: this.busy,
        btnIcon: $r('app.media.ic_check'),
        onTap: (): void => {
          this.generateAndSave();
        }
      })

      GhostButton({
        ghostLabel: '导出 RAW 文件',
        ghostEnabled: this.source !== undefined,
        ghostIcon: $r('app.media.ic_upload'),
        onTap: (): void => {
          this.generateAndExport();
        }
      })

      Text('写入只需在「音效库」点写入：双耳入盒开盖，通过蓝牙直接下发到充电盒')
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
      Text(this.busy ? '处理中…' : this.chipLabel)
        .fontSize(12)
        .fontColor(this.active ? '#05080E' : Palette.TEXT_SECONDARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.active ? Palette.ACCENT : 'rgba(255, 255, 255, 0.05)')
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 滑块行：数值文案与滑块位置需要随状态刷新 */
@Component
struct SliderBlock {
  @Prop blockLabel: string = '';
  @Prop blockText: string = '';
  @Prop blockValue: number = 0;
  @Prop blockMin: number = 0;
  @Prop blockMax: number = 100;
  @Prop blockStep: number = 10;
  onValue: (value: number) => void = () => {
  };

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.blockLabel)
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .layoutWeight(1)
        Text(this.blockText)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.ACCENT)
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
        .trackColor('rgba(255, 255, 255, 0.08)')
        .selectedColor(Palette.ACCENT)
        .blockColor('#FFFFFF')
        .onChange((next: number, mode: SliderChangeMode) => {
          this.onValue(Math.round(next * 10) / 10);
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }
}

/** 开关行：开关状态需要随状态刷新 */
@Component
struct ToggleBlock {
  @Prop blockLabel: string = '';
  @Prop blockOn: boolean = false;
  onSwitch: (isOn: boolean) => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      Text(this.blockLabel)
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
      Toggle({ type: ToggleType.Switch, isOn: this.blockOn })
        .selectedColor(Palette.ACCENT)
        .onChange((next: boolean) => {
          this.onSwitch(next);
        })
    }
  }
}
