import { Palette } from '../common/constants/ThemeConstants';

/** 动作胶囊的语气 */
export enum PillTone {
  /** 强调：主要的次级操作（扫描、去连接、更换、选择、复制） */
  ACCENT = 0,
  /** 中性：辅助操作（全选、取消） */
  NEUTRAL = 1,
  /** 危险：删除、停止 */
  DANGER = 2
}

/**
 * 动作胶囊：全应用的小号操作按钮都用它，保证字号、内边距、圆角、配色一致。
 * 选中态的「选项胶囊」不用它，规则见 Palette 里的控件配色说明。
 */
@Component
export struct PillButton {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop pillText: string = '';
  @Prop pillTone: PillTone = PillTone.ACCENT;
  @Prop pillEnabled: boolean = true;
  onTap: () => void = () => {
  };

  private textColor(): string {
    if (this.pillTone === PillTone.DANGER) {
      return Palette.DANGER;
    }
    if (this.pillTone === PillTone.NEUTRAL) {
      return Palette.TEXT_SECONDARY;
    }
    return Palette.ACCENT_TEXT;
  }

  build() {
    Text(this.pillText)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.textColor())
      .maxLines(1)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      // 底色统一中性玻璃，不用淡色底；语气只靠文字颜色区分
      .backgroundColor(Palette.CHIP_IDLE)
      .border({ width: 1, color: Palette.CHIP_IDLE_STROKE })
      .opacity(this.pillEnabled ? 1 : 0.45)
      .clickEffect(this.pillEnabled ? { level: ClickEffectLevel.LIGHT, scale: 0.95 } : null)
      .onClick(() => {
        if (this.pillEnabled) {
          this.onTap();
        }
      })
  }
}
