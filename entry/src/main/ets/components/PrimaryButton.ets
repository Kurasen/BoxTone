import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';

/** 主操作按钮：青→紫品牌渐变 + 按压反馈（全应用只有主按钮用这组渐变，其余强调色统一用 Palette.ACCENT） */
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
          .fillColor(this.btnEnabled ? Palette.ON_ACCENT : Palette.TEXT_TERTIARY)
      }
      Text(this.btnLoading ? I18n.t('common.processing') : this.btnLabel)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.btnEnabled ? Palette.ON_ACCENT : Palette.TEXT_TERTIARY)
    }
    .width('100%')
    .height(50)
    .justifyContent(FlexAlign.Center)
    // 胶囊形，与次级按钮、标签统一
    .borderRadius(25)
    .linearGradient({
      angle: 100,
      colors: [['#5BE0FF', 0.0], ['#8F7BFF', 1.0]]
    })
    .shadow({ radius: 22, color: 'rgba(78, 216, 255, 0.26)', offsetY: 8 })
    // 按压回弹：系统点击动效，按下轻微缩小、松手弹回；不可点时关闭
    .clickEffect(this.btnEnabled && !this.btnLoading ? { level: ClickEffectLevel.LIGHT, scale: 0.97 } : null)
    .opacity(this.btnEnabled ? 1.0 : 0.38)
    .enabled(this.btnEnabled && !this.btnLoading)
    .onClick(() => {
      if (this.btnEnabled && !this.btnLoading) {
        this.onTap();
      }
    })
  }
}
