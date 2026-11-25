import { ThemeService } from '../../services/ThemeService';

/**
 * 视觉设计令牌：深色 / 浅色两套
 * 颜色统一使用十六进制或 rgba，避免使用颜色名；
 * 取值时按当前外观返回，切换外观后由组件重绘生效
 */

export class Palette {
  /**
   * 系统启动页底色：必须与 resources/base 和 resources/dark 下的
   * start_window_background 保持一致，首页的启动衔接遮罩用它接住启动页
   */
  static readonly START_WINDOW_LIGHT: string = '#F1F4F8';
  static readonly START_WINDOW_DARK: string = '#000000';

  // 背景：深色纯黑，浅色冷灰（比纯白深一档，白卡片才有地方浮起来）
  static get BG_TOP(): string {
    return ThemeService.isDark() ? '#000000' : '#F1F4F8';
  }

  static get BG_BOTTOM(): string {
    return ThemeService.isDark() ? '#04070B' : '#E8EDF3';
  }

  static get BG_END(): string {
    return ThemeService.isDark() ? '#000000' : '#E3E9F0';
  }

  // 卡片：深色下比纯黑亮两档，浅色下纯白
  static get BG_CARD(): string {
    return ThemeService.isDark() ? '#191C23' : '#FFFFFF';
  }

  static get BG_CARD_STRONG(): string {
    return ThemeService.isDark() ? '#23272F' : '#FFFFFF';
  }

  static get BG_INPUT(): string {
    return ThemeService.isDark() ? '#101216' : '#EDF1F6';
  }

  // 叠加层（分隔线、置灰填充、玻璃按钮等）
  static get FILL_FAINT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.05)' : 'rgba(15, 26, 46, 0.05)';
  }

  static get FILL_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : 'rgba(15, 26, 46, 0.06)';
  }

  static get GLASS_BTN(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.12)' : 'rgba(15, 26, 46, 0.10)';
  }

  // 描边：卡片界面的"框"靠它立住；浅色下描边加深，边缘才不发虚
  static get STROKE(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.14)' : '#D0D8E3';
  }

  static get STROKE_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.09)' : '#DDE4ED';
  }

  // 文本：主文字拉到最高对比，次要/三级也各提一档
  static get TEXT_PRIMARY(): string {
    return ThemeService.isDark() ? '#FFFFFF' : '#0F1318';
  }

  static get TEXT_SECONDARY(): string {
    return ThemeService.isDark() ? '#B4BDCA' : '#4B5462';
  }

  static get TEXT_TERTIARY(): string {
    return ThemeService.isDark() ? '#8792A1' : '#6D7784';
  }

  static get TEXT_FAINT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.30)' : 'rgba(70, 80, 96, 0.6)';
  }

  // 全屏遮罩上的文字
  // 遮罩本身固定是深色（rgba(5,8,14,0.62)，不跟随主题，否则系统选择器弹出时会露亮边），
  // 所以这里的文字也必须固定用浅色：跟着主题走的话，浅色主题下会得到深灰文字压在深遮罩上。
  static get OVERLAY_TEXT(): string {
    return '#F2F6FB';
  }

  static get OVERLAY_TEXT_SUB(): string {
    return 'rgba(242, 246, 251, 0.68)';
  }

  /** 遮罩上的次级按钮底色 */
  static get OVERLAY_CHIP(): string {
    return 'rgba(255, 255, 255, 0.16)';
  }

  // 品牌：统一用天空蓝，深浅两种外观下都保持同一个蓝
  static get ACCENT(): string {
    return '#38BDF8';
  }

  /**
   * 浅色背景上的强调文字/图标。
   * 天空蓝压在纯白上对比度只有 2.3:1，字会发飘，所以浅色下压深一档到 #0EA5E9（仍是同一个色相），
   * 深色下直接用 ACCENT。
   */
  static get ACCENT_TEXT(): string {
    return ThemeService.isDark() ? '#38BDF8' : '#0EA5E9';
  }

  static get ACCENT_DEEP(): string {
    return '#0EA5E9';
  }

  static get ACCENT_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(56, 189, 248, 0.16)' : 'rgba(56, 189, 248, 0.14)';
  }

  static get ACCENT_LINE(): string {
    return 'rgba(56, 189, 248, 0.38)';
  }

  static get VIOLET(): string {
    return ThemeService.isDark() ? '#A78BFA' : '#8B5CF6';
  }

  static get VIOLET_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(167, 139, 250, 0.16)' : 'rgba(139, 92, 246, 0.12)';
  }

  // 语义
  static get SUCCESS(): string {
    return ThemeService.isDark() ? '#43D6A0' : '#0B7A5A';
  }

  static get SUCCESS_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(67, 214, 160, 0.14)' : 'rgba(15, 169, 124, 0.12)';
  }

  static get WARNING(): string {
    return ThemeService.isDark() ? '#FFB84D' : '#8A5600';
  }

  static get WARNING_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 184, 77, 0.14)' : 'rgba(192, 122, 0, 0.12)';
  }

  static get DANGER(): string {
    return ThemeService.isDark() ? '#FF6B7A' : '#C7354A';
  }

  static get DANGER_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 107, 122, 0.14)' : 'rgba(222, 74, 94, 0.12)';
  }

  // 光斑：纯黑底上大面积色斑会显脏，压到几乎察觉不到，只留一丝冷调
  static get HALO_CYAN(): string {
    return ThemeService.isDark() ? 'rgba(56, 189, 248, 0.05)' : 'rgba(56, 189, 248, 0.04)';
  }

  static get HALO_VIOLET(): string {
    return ThemeService.isDark() ? 'rgba(167, 139, 250, 0.035)' : 'rgba(139, 92, 246, 0.03)';
  }

  static get HALO_TEAL(): string {
    return ThemeService.isDark() ? 'rgba(56, 189, 248, 0.03)' : 'rgba(56, 189, 248, 0.025)';
  }

  // 系统半模态（关于面板）
  static get SHEET_TINT(): string {
    return ThemeService.isDark() ? 'rgba(13, 21, 36, 0.55)' : 'rgba(250, 252, 255, 0.65)';
  }

  static get SHEET_MASK(): string {
    return ThemeService.isDark() ? 'rgba(7, 10, 16, 0.30)' : 'rgba(15, 23, 42, 0.18)';
  }
}

export class Metric {
  static readonly PAGE_PADDING: number = 18;
  /** 悬浮底栏占位高度，内容需预留 */
  static readonly CONTENT_BOTTOM_INSET: number = 108;
  static readonly CARD_RADIUS: number = 22;
  static readonly CARD_PADDING: number = 16;
  static readonly GAP: number = 12;
  static readonly TITLE_SIZE: number = 27;
  static readonly SECTION_SIZE: number = 14;
  static readonly CAPTION_SIZE: number = 11;
}
