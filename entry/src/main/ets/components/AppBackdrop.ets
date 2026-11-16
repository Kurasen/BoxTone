import { Palette } from '../common/constants/ThemeConstants';

/** 全应用统一的深色渐变背景：页面与弹层共用，避免弹层底色和页面不一致 */
@Component
export struct AppBackdrop {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 165,
          colors: [[Palette.BG_TOP, 0.0], [Palette.BG_BOTTOM, 0.62], [Palette.BG_END, 1.0]]
        })

      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['10%', '4%'],
          radius: 360,
          colors: [[Palette.HALO_CYAN, 0.0], ['rgba(78, 216, 255, 0.0)', 1.0]]
        })

      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['88%', '16%'],
          radius: 320,
          colors: [[Palette.HALO_VIOLET, 0.0], ['rgba(155, 123, 255, 0.0)', 1.0]]
        })

      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['4%', '74%'],
          radius: 380,
          colors: [[Palette.HALO_TEAL, 0.0], ['rgba(31, 168, 216, 0.0)', 1.0]]
        })
    }
    .width('100%')
    .height('100%')
  }
}
