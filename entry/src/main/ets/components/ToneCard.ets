import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';
import { DateUtils } from '../common/utils/DateUtils';
import { FormatUtils } from '../common/utils/FormatUtils';
import { createEmptyTone, ToneEntry } from '../models/ToneModel';

/** 音效库条目卡片，点击展开操作区 */
@Component
export struct ToneCard {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop entry: ToneEntry = createEmptyTone();
  /** 这条就是盒内当前生效的音效 */
  @Prop inCase: boolean = false;
  /** 批量选择模式：点卡片是勾选，不是展开 */
  @Prop selecting: boolean = false;
  @Prop selected: boolean = false;
  /** 正在写入这条音效：删除入口锁定 */
  @Prop deleteLocked: boolean = false;
  @Prop expanded: boolean = false;
  @Prop playing: boolean = false;
  @Prop writing: boolean = false;
  @Prop writingText: string = I18n.t('lib.writing');
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
  onShare: () => void = () => {
  };
  onRename: () => void = () => {
  };
  onDelete: () => void = () => {
  };
  onSelect: () => void = () => {
  };

  build() {
    Column() {
      Row({ space: 12 }) {
        Stack() {
          Circle()
            .width(40)
            .height(40)
            .fill(this.selected ? Palette.ACCENT : (this.playing ? Palette.ACCENT_SOFT : Palette.FILL_FAINT))
          if (this.selecting) {
            Image($r('app.media.ic_check'))
              .width(15)
              .height(15)
              .fillColor(this.selected ? '#05080E' : Palette.TEXT_TERTIARY)
          } else {
            Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(16)
              .height(16)
              .fillColor(this.playing ? Palette.ACCENT : Palette.TEXT_SECONDARY)
          }
        }
        .onClick(() => {
          if (this.selecting) {
            this.onSelect();
            return;
          }
          this.onPlay();
        })

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(this.entry.name)
              .fontSize(15)
              .fontColor(Palette.TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.inCase) {
              Text(I18n.t('card.inCase'))
                .fontSize(9)
                .fontColor(Palette.ACCENT_TEXT)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(999)
                .backgroundColor(Palette.ACCENT_SOFT)
            }
          }
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

        if (!this.selecting) {
          Image($r('app.media.ic_chevron_right'))
            .width(14)
            .height(14)
            .fillColor(Palette.TEXT_TERTIARY)
            .rotate({ angle: this.expanded ? 90 : 0 })
        }
      }
      .width('100%')
      .onClick(() => {
        if (this.selecting) {
          this.onSelect();
          return;
        }
        this.onToggle();
      })

      if (this.expanded) {
        // 五个操作：固定一行会挤爆窄屏，交给 wrap 自动换行
        Flex({ wrap: FlexWrap.Wrap }) {
          WriteChip({
            chipText: this.writing ? this.writingText :
              (this.writeLocked ? I18n.t('card.unavailable') : I18n.t('card.write')),
            chipBusy: this.writing,
            chipLocked: this.writeLocked,
            onTap: (): void => {
              this.onWrite();
            }
          })
          .margin({ right: 8, bottom: 8 })
          ActionChip({
            chipText: I18n.t('card.share'),
            chipColor: Palette.ACCENT_TEXT,
            onTap: (): void => {
              this.onShare();
            }
          })
          .margin({ right: 8, bottom: 8 })
          ActionChip({
            chipText: I18n.t('card.export'),
            chipColor: Palette.TEXT_SECONDARY,
            onTap: (): void => {
              this.onExport();
            }
          })
          .margin({ right: 8, bottom: 8 })
          ActionChip({
            chipText: I18n.t('card.rename'),
            chipColor: Palette.TEXT_SECONDARY,
            onTap: (): void => {
              this.onRename();
            }
          })
          .margin({ right: 8, bottom: 8 })
          ActionChip({
            chipText: this.deleteLocked ? I18n.t('card.deleteLocked') : I18n.t('card.delete'),
            chipColor: this.deleteLocked ? Palette.TEXT_TERTIARY : Palette.DANGER,
            chipLocked: this.deleteLocked,
            onTap: (): void => {
              this.onDelete();
            }
          })
          .margin({ right: 8, bottom: 8 })
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
  @Prop chipText: string = I18n.t('card.write');
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
      // 不再 layoutWeight：Flex 里平分会让五个按钮挤成一行，改成按文字宽度自适应
      .height(34)
      .padding({ left: 16, right: 16 })
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
  /** 锁定：置灰并吞掉点击（例如正在写入的音效不允许删除） */
  @Prop chipLocked: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.chipText)
      .fontSize(12)
      .fontColor(this.chipColor.length > 0 ? this.chipColor : Palette.TEXT_SECONDARY)
      .height(34)
      .padding({ left: 16, right: 16 })
      .textAlign(TextAlign.Center)
      .borderRadius(11)
      .backgroundColor(Palette.FILL_SOFT)
      .border({ width: 1, color: Palette.STROKE_SOFT })
      .opacity(this.chipLocked ? 0.45 : 1)
      .enabled(!this.chipLocked)
      .onClick(() => {
        if (!this.chipLocked) {
          this.onTap();
        }
      })
  }
}
