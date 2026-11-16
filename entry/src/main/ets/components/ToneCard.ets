import { Palette } from '../common/constants/ThemeConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { FormatUtils } from '../common/utils/FormatUtils';
import { createEmptyTone, ToneEntry } from '../models/ToneModel';

/** 音效库条目卡片，点击展开操作区 */
@Component
export struct ToneCard {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop entry: ToneEntry = createEmptyTone();
  @Prop expanded: boolean = false;
  @Prop playing: boolean = false;
  @Prop writing: boolean = false;
  @Prop writingText: string = '写入中…';
  /** 有其他音效正在写入：本条的写入入口置灰锁定 */
  @Prop writeLocked: boolean = false;
  onToggle: () => void = () => {
  };
  onPlay: () => void = () => {
  };
  onWrite: () => void = () => {
  };
  onExport: () => void = () => {
  };
  onRename: () => void = () => {
  };
  onDelete: () => void = () => {
  };

  build() {
    Column() {
      Row({ space: 12 }) {
        Stack() {
          Circle()
            .width(40)
            .height(40)
            .fill(this.playing ? Palette.ACCENT_SOFT : Palette.FILL_FAINT)
          Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
            .width(16)
            .height(16)
            .fillColor(this.playing ? Palette.ACCENT : Palette.TEXT_SECONDARY)
        }
        .onClick(() => {
          this.onPlay();
        })

        Column({ space: 4 }) {
          Text(this.entry.name)
            .fontSize(15)
            .fontColor(Palette.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${FormatUtils.seconds(this.entry.durationMs)} · ${FormatUtils.bytes(this.entry.byteLength)} · ` +
            `${DateUtils.dateTime(this.entry.createdAt)}`)
            .fontSize(11)
            .fontColor(Palette.TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Image($r('app.media.ic_chevron_right'))
          .width(14)
          .height(14)
          .fillColor(Palette.TEXT_TERTIARY)
          .rotate({ angle: this.expanded ? 90 : 0 })
      }
      .width('100%')
      .onClick(() => {
        this.onToggle();
      })

      if (this.expanded) {
        Row({ space: 8 }) {
          WriteChip({
            chipText: this.writing ? this.writingText : (this.writeLocked ? '暂不可写' : '写入'),
            chipBusy: this.writing,
            chipLocked: this.writeLocked,
            onTap: (): void => {
              this.onWrite();
            }
          })
          ActionChip({
            chipText: '导出',
            chipColor: Palette.TEXT_SECONDARY,
            onTap: (): void => {
              this.onExport();
            }
          })
          ActionChip({
            chipText: '重命名',
            chipColor: Palette.TEXT_SECONDARY,
            onTap: (): void => {
              this.onRename();
            }
          })
          ActionChip({
            chipText: '删除',
            chipColor: Palette.DANGER,
            onTap: (): void => {
              this.onDelete();
            }
          })
        }
        .width('100%')
        .margin({ top: 14 })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(20)
    .backgroundColor(Palette.BG_CARD)
    .border({ width: 1, color: this.expanded ? 'rgba(78, 216, 255, 0.28)' : Palette.STROKE_SOFT })
  }
}

/** 写入耳机盒：主操作，强调色；写入进行中或被他条占用时置灰 */
@Component
struct WriteChip {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop chipText: string = '写入';
  @Prop chipBusy: boolean = false;
  @Prop chipLocked: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.chipText)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontColor(this.chipLocked ? Palette.TEXT_TERTIARY : (this.chipBusy ? Palette.TEXT_TERTIARY : Palette.ACCENT))
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(11)
      .backgroundColor(this.chipLocked ? Palette.BG_INPUT :
        (this.chipBusy ? Palette.FILL_FAINT : Palette.ACCENT_SOFT))
      .border({
        width: 1,
        color: this.chipLocked ? Palette.BG_INPUT :
          (this.chipBusy ? Palette.STROKE_SOFT : 'rgba(78, 216, 255, 0.32)')
      })
      .opacity(this.chipLocked ? 0.55 : 1)
      .enabled(!this.chipBusy && !this.chipLocked)
      .onClick(() => {
        if (!this.chipBusy && !this.chipLocked) {
          this.onTap();
        }
      })
  }
}

/** 次级操作 */
@Component
struct ActionChip {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop chipText: string = '';
  /** 留空时按当前外观取默认值 */
  @Prop chipColor: string = '';
  onTap: () => void = () => {
  };

  build() {
    Text(this.chipText)
      .fontSize(12)
      .fontColor(this.chipColor.length > 0 ? this.chipColor : Palette.TEXT_SECONDARY)
      .layoutWeight(1)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(11)
      .backgroundColor(Palette.FILL_FAINT)
      .onClick(() => {
        this.onTap();
      })
  }
}
