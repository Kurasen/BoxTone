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
    // 默认用半透明底色，透出背景光斑；调用方指定 cardBg（如强调色提示卡）时用指定色
    .backgroundColor(this.cardBg.length > 0 ? this.cardBg : Palette.CARD_GLASS)
    // 浅色雾面：一圈亮白描边 + 大半径柔和投影，卡片像浮在雾面上；深色下保持细描边、不加投影
    .border({ width: 1, color: this.cardStroke.length > 0 ? this.cardStroke : Palette.GLASS_RIM })
    .shadow(ThemeService.isDark() ? {
      radius: 0,
      color: 'rgba(0, 0, 0, 0)'
    } : {
      radius: 28,
      color: Palette.GLASS_SHADOW,
      offsetX: 0,
      offsetY: 8
    })
  }
}
