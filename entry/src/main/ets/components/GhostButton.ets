import { Palette } from '../common/constants/ThemeConstants';
import { ThemeService } from '../services/ThemeService';

/** 次级按钮：胶囊形；浅色下是雾面白底 + 亮边 + 柔和投影，深色下是描边 + 透明底 */
@Component
export struct GhostButton {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
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
    .borderRadius(23)
    .backgroundColor(Palette.GLASS_BTN_FILL)
    .border({ width: 1, color: ThemeService.isDark() ? Palette.STROKE : Palette.GLASS_RIM })
    .shadow(ThemeService.isDark() ? {
      radius: 0,
      color: 'rgba(0, 0, 0, 0)'
    } : {
      radius: 14,
      color: 'rgba(62, 78, 120, 0.10)',
      offsetX: 0,
      offsetY: 4
    })
    // 按压回弹：系统点击动效，不可点时关闭
    .clickEffect(this.ghostEnabled ? { level: ClickEffectLevel.LIGHT, scale: 0.97 } : null)
    .enabled(this.ghostEnabled)
    .onClick(() => {
      if (this.ghostEnabled) {
        this.onTap();
      }
    })
  }
}
