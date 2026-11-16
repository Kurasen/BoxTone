import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { Changelog, ChangelogEntry } from '../../common/constants/AppConstants';
import { GlassCard } from '../../components/GlassCard';

/** 更新日志（全屏浮层）：按版本列出更新内容 */
@Component
export struct ChangelogPage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  topInset: number = 0;
  onClose: () => void = () => {
  };

  build() {
    Column() {
      this.buildTopBar()

      Scroll() {
        Column({ space: 16 }) {
          ForEach(Changelog.ENTRIES, (entry: ChangelogEntry) => {
            GlassCard({ cardPadding: 16 }) {
              Row({ space: 8 }) {
                Text(entry.version)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Palette.TEXT_PRIMARY)
                Text(entry.note)
                  .fontSize(10)
                  .fontColor(Palette.TEXT_TERTIARY)
                  .layoutWeight(1)
              }
              .width('100%')
              .margin({ bottom: 10 })

              ForEach(entry.items, (item: string) => {
                Row({ space: 8 }) {
                  Circle()
                    .width(4)
                    .height(4)
                    .fill(Palette.ACCENT)
                    .margin({ top: 6 })
                  Text(item)
                    .fontSize(11)
                    .fontColor(Palette.TEXT_SECONDARY)
                    .lineHeight(18)
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .margin({ bottom: 6 })
              }, (item: string) => item)
            }
          }, (entry: ChangelogEntry) => entry.version)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: Metric.PAGE_PADDING,
          right: Metric.PAGE_PADDING,
          top: 4,
          bottom: 28
        })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    .backgroundColor(Palette.BG_TOP)
    .linearGradient({
      angle: 170,
      colors: [[Palette.BG_TOP, 0.0], [Palette.BG_END, 1.0]]
    })
  }

  @Builder
  buildTopBar() {
    Row({ space: 12 }) {
      Image($r('app.media.ic_chevron_right'))
        .width(18)
        .height(18)
        .fillColor(Palette.TEXT_PRIMARY)
        .rotate({ angle: 180 })
        .onClick(() => {
          this.onClose();
        })

      Column({ space: 3 }) {
        Text('更新日志')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text('版本更新记录')
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: Metric.PAGE_PADDING,
      right: Metric.PAGE_PADDING,
      top: 10,
      bottom: 14
    })
  }
}
