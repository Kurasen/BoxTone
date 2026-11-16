import { Palette } from '../common/constants/ThemeConstants';

/** 规格说明行：左标签 + 右数值 */
@Component
export struct SpecRow {
  @Prop specLabel: string = '';
  @Prop specValue: string = '';
  @Prop valueColor: string = Palette.TEXT_PRIMARY;
  showDivider: boolean = false;

  build() {
    Column() {
      Row() {
        Text(this.specLabel)
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .layoutWeight(1)
        Text(this.specValue)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.valueColor)
      }
      .width('100%')
      .height(34)

      if (this.showDivider) {
        Divider()
          .color('rgba(255, 255, 255, 0.05)')
          .strokeWidth(1)
      }
    }
    .width('100%')
  }
}
