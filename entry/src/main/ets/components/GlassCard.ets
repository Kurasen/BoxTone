import { Metric, Palette } from '../common/constants/ThemeConstants';
import { ThemeService } from '../services/ThemeService';

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
    // 浅色下白卡片贴着冷灰底，只靠描边会显得"糊"；加一层很窄的投影托起来。
    // 半径压到 6：大半径会把边缘柔化，反而更像没擦干净。
    // 深色纯黑底上投影不可见，直接给 0 省一次绘制。
    .shadow(ThemeService.isDark() ? {
      radius: 0,
      color: 'rgba(0, 0, 0, 0)'
    } : {
      radius: 6,
      color: 'rgba(23, 43, 77, 0.055)',
      offsetX: 0,
      offsetY: 1.5
    })
  }
}
