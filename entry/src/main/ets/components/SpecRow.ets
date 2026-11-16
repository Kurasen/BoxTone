import { Palette } from '../common/constants/ThemeConstants';

/** 规格说明行：左标签 + 右数值 */
@Component
export struct SpecRow {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop specLabel: string = '';
  @Prop specValue: string = '';
  /** 留空时按当前外观取默认值 */
  @Prop valueColor: string = '';
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
          .fontColor(this.valueColor.length > 0 ? this.valueColor : Palette.TEXT_PRIMARY)
      }
      .width('100%')
      .height(34)

      if (this.showDivider) {
        Divider()
          .color(Palette.FILL_FAINT)
          .strokeWidth(1)
      }
    }
    .width('100%')
  }
}
