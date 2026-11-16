import { Metric, Palette } from '../common/constants/ThemeConstants';

/** 区块标题 */
@Component
export struct SectionTitle {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop sectionText: string = '';
  @Prop sectionHint: string = '';

  build() {
    Row() {
      Text(this.sectionText)
        .fontSize(Metric.SECTION_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TEXT_PRIMARY)
        .layoutWeight(1)
      if (this.sectionHint.length > 0) {
        Text(this.sectionHint)
          .fontSize(Metric.CAPTION_SIZE)
          .fontColor(Palette.TEXT_TERTIARY)
      }
    }
    .width('100%')
    .margin({ top: 4, bottom: 10 })
  }
}
