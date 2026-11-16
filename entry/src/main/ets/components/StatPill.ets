import { Palette } from '../common/constants/ThemeConstants';

/** 胶囊标签，用于状态与规格提示 */
@Component
export struct StatPill {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop pillText: string = '';
  /** accent | success | warning | danger | muted */
  @Prop pillTone: string = 'muted';
  compact: boolean = false;

  private textColor(): string {
    if (this.pillTone === 'accent') {
      return Palette.ACCENT;
    }
    if (this.pillTone === 'success') {
      return Palette.SUCCESS;
    }
    if (this.pillTone === 'warning') {
      return Palette.WARNING;
    }
    if (this.pillTone === 'danger') {
      return Palette.DANGER;
    }
    return Palette.TEXT_SECONDARY;
  }

  private bgColor(): string {
    if (this.pillTone === 'accent') {
      return Palette.ACCENT_SOFT;
    }
    if (this.pillTone === 'success') {
      return Palette.SUCCESS_SOFT;
    }
    if (this.pillTone === 'warning') {
      return Palette.WARNING_SOFT;
    }
    if (this.pillTone === 'danger') {
      return Palette.DANGER_SOFT;
    }
    return Palette.STROKE_SOFT;
  }

  build() {
    Text(this.pillText)
      .fontSize(this.compact ? 10 : 11)
      .fontColor(this.textColor())
      .padding({
        left: this.compact ? 7 : 9,
        right: this.compact ? 7 : 9,
        top: this.compact ? 3 : 4,
        bottom: this.compact ? 3 : 4
      })
      .borderRadius(999)
      .backgroundColor(this.bgColor())
  }
}
