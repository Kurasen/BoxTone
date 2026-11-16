import { Palette } from '../common/constants/ThemeConstants';

/** 空状态占位 */
@Component
export struct EmptyView {
  emptyIcon: Resource = $r('app.media.ic_tab_tone');
  @Prop emptyTitle: string = '';
  @Prop emptyDesc: string = '';

  build() {
    Column({ space: 10 }) {
      Stack() {
        Circle()
          .width(64)
          .height(64)
          .fill('rgba(255, 255, 255, 0.04)')
        Image(this.emptyIcon)
          .width(26)
          .height(26)
          .fillColor(Palette.TEXT_TERTIARY)
      }

      Text(this.emptyTitle)
        .fontSize(14)
        .fontColor(Palette.TEXT_SECONDARY)

      if (this.emptyDesc.length > 0) {
        Text(this.emptyDesc)
          .fontSize(12)
          .fontColor(Palette.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      }
    }
    .width('100%')
    .padding({ top: 28, bottom: 28 })
    .alignItems(HorizontalAlign.Center)
  }
}
