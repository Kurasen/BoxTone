import { Palette } from '../common/constants/ThemeConstants';
import { ThemeService } from '../services/ThemeService';

/**
 * 全应用统一的背景
 *
 * 深色（极光）：预渲染图 media/bg_dark_aurora.png，近黑底 + 顶部左青右紫两道高斯柔光，带 ±1 级抖动。
 *   不用 linearGradient / radialGradient 现场画：近黑色可用的亮度级很少，渐变会一级一级地跳，
 *   顶部出现一圈圈色阶、下半屏出现横带，线性衰减的光斑边缘还会留一道弧线（用户看到的「印子」）。
 *   抖动只有预渲染图能做。图片 432×936，用最近邻插值拉伸，保留抖动噪点不被平滑掉。
 * 浅色（雾面）：预渲染图 media/bg_light_mist.png，蓝灰底 + 两团亮雾、两团蓝灰雾，同样带抖动。
 *   雾面底比纯白暗，白色半透明卡片和按钮靠亮边与柔和投影浮起来，大面积不刺眼。
 */
@Component
export struct AppBackdrop {
  @StorageProp('themeEpoch') themeEpoch: number = 0;

  build() {
    Stack() {
      // 同步解码：避免首帧先露出纯色底、图片随后才弹出来；最近邻插值保留抖动噪点
      Image(ThemeService.isDark() ? $r('app.media.bg_dark_aurora') : $r('app.media.bg_light_mist'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        .interpolation(ImageInterpolation.None)
        .syncLoad(true)
        .draggable(false)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG_TOP)
  }
}
