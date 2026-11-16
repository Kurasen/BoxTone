import { Palette } from '../common/constants/ThemeConstants';

/** 次级按钮：描边 + 透明底 */
@Component
export struct GhostButton {
  @Prop ghostLabel: string = '';
  @Prop ghostEnabled: boolean = true;
  ghostIcon: Resource | undefined = undefined;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      if (this.ghostIcon !== undefined) {
        Image(this.ghostIcon)
          .width(15)
          .height(15)
          .fillColor(this.ghostEnabled ? Palette.TEXT_PRIMARY : Palette.TEXT_TERTIARY)
      }
      Text(this.ghostLabel)
        .fontSize(13)
        .fontColor(this.ghostEnabled ? Palette.TEXT_PRIMARY : Palette.TEXT_TERTIARY)
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
    .borderRadius(15)
    .backgroundColor('rgba(255, 255, 255, 0.05)')
    .border({ width: 1, color: Palette.STROKE })
    .enabled(this.ghostEnabled)
    .onClick(() => {
      if (this.ghostEnabled) {
        this.onTap();
      }
    })
  }
}
