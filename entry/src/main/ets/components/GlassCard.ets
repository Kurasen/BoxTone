import { Metric, Palette } from '../common/constants/ThemeConstants';

/**
 * 毛玻璃卡片容器
 * 用法：GlassCard({ cardPadding: 16 }) { ... }
 */
@Component
export struct GlassCard {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @BuilderParam content: () => void = this.emptyBuilder;
  @Prop cardRadius: number = Metric.CARD_RADIUS;
  @Prop cardPadding: number = Metric.CARD_PADDING;
  /** 留空时按当前外观取默认值：字段默认值只在构造时求值，切换外观不会刷新 */
  @Prop cardBg: string = '';
  @Prop cardStroke: string = '';

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
    .backgroundColor(this.cardBg.length > 0 ? this.cardBg : Palette.BG_CARD)
    .border({ width: 1, color: this.cardStroke.length > 0 ? this.cardStroke : Palette.STROKE_SOFT })
  }
}
