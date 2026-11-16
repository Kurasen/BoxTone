import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';

/** 主操作按钮：品牌渐变 + 按压反馈 */
@Component
export struct PrimaryButton {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop btnLabel: string = '';
  @Prop btnEnabled: boolean = true;
  @Prop btnLoading: boolean = false;
  btnIcon: Resource | undefined = undefined;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      if (this.btnIcon !== undefined) {
        Image(this.btnIcon)
          .width(16)
          .height(16)
          .fillColor(this.btnEnabled ? '#05080E' : Palette.TEXT_TERTIARY)
      }
      Text(this.btnLoading ? I18n.t('common.processing') : this.btnLabel)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.btnEnabled ? '#05080E' : Palette.TEXT_TERTIARY)
    }
    .width('100%')
    .height(50)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .linearGradient({
      angle: 100,
      colors: [['#5BE0FF', 0.0], ['#8F7BFF', 1.0]]
    })
    .shadow({ radius: 22, color: 'rgba(78, 216, 255, 0.26)', offsetY: 8 })
    .opacity(this.btnEnabled ? 1.0 : 0.38)
    .enabled(this.btnEnabled && !this.btnLoading)
    .onClick(() => {
      if (this.btnEnabled && !this.btnLoading) {
        this.onTap();
      }
    })
  }
}
