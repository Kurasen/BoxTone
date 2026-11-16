import { Palette } from '../common/constants/ThemeConstants';

/**
 * 波形可视化
 * 采用 Canvas 绘制，峰值数组由 AudioConvertService.buildPeaks 提供
 */
@Component
export struct WaveformView {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop @Watch('onDataChange') peaks: number[] = [];
  @Prop @Watch('onDataChange') startRatio: number = 0;
  @Prop @Watch('onDataChange') endRatio: number = 1;
  @Prop @Watch('onDataChange') hasSelection: boolean = false;
  @Prop waveHeight: number = 92;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private painter: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;

  private onDataChange(): void {
    this.render();
  }

  private render(): void {
    if (!this.isReady) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.painter;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const selStart: number = Math.max(0, Math.min(1, this.startRatio)) * w;
    const selEnd: number = Math.max(0, Math.min(1, this.endRatio)) * w;
    if (this.hasSelection && selEnd > selStart + 0.5) {
      ctx.fillStyle = 'rgba(78, 216, 255, 0.10)';
      ctx.fillRect(selStart, 0, selEnd - selStart, h);
      ctx.fillStyle = 'rgba(78, 216, 255, 0.55)';
      ctx.fillRect(selStart, 0, 1.5, h);
      ctx.fillRect(selEnd - 1.5, 0, 1.5, h);
    }

    ctx.fillStyle = 'rgba(128, 142, 160, 0.16)';
    ctx.fillRect(0, h / 2 - 0.5, w, 1);

    const count: number = this.peaks.length;
    if (count === 0) {
      return;
    }
    const slot: number = w / count;
    const barWidth: number = Math.max(1, slot * 0.6);
    for (let i = 0; i < count; i++) {
      let amp: number = this.peaks[i];
      if (amp < 0.05) {
        amp = 0.05;
      }
      const barHeight: number = Math.max(2, amp * (h - 8));
      const x: number = i * slot + (slot - barWidth) / 2;
      const center: number = i * slot + slot / 2;
      const selected: boolean = this.hasSelection && center >= selStart && center <= selEnd;
      ctx.fillStyle = selected ? Palette.ACCENT : 'rgba(128, 142, 160, 0.40)';
      ctx.fillRect(x, (h - barHeight) / 2, barWidth, barHeight);
    }
  }

  build() {
    Canvas(this.painter)
      .width('100%')
      .height(this.waveHeight)
      .onReady(() => {
        this.isReady = true;
        this.render();
      })
  }
}
