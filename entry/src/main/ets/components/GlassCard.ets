import { Metric, Palette } from '../common/constants/ThemeConstants';

/**
 * 毛玻璃卡片容器
 * 用法：GlassCard({ cardPadding: 16 }) { ... }
 */
@Component
export struct GlassCard {
  @BuilderParam content: () => void = this.emptyBuilder;
  @Prop cardRadius: number = Metric.CARD_RADIUS;
  @Prop cardPadding: number = Metric.CARD_PADDING;
  @Prop cardBg: string = Palette.BG_CARD;
  @Prop cardStroke: string = Palette.STROKE_SOFT;

  @Builder
  emptyBuilder() {
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.cardPadding)
    .borderRadius(this.cardRadius)
    .backgroundColor(this.cardBg)
    .border({ width: 1, color: this.cardStroke })
  }
}
