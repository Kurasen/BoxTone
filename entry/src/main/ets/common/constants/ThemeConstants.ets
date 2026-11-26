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
  static readonly START_WINDOW_LIGHT: string = '#E9EEF6';
  static readonly START_WINDOW_DARK: string = '#0A0B10';

  // 背景：深浅两色都由 AppBackdrop 的预渲染图绘制（media/bg_dark_aurora.png、media/bg_light_mist.png），
  // 这里的值用作图片加载前的底色，取自图片顶部 / 底部的均色。
  // BG_TOP 必须与 START_WINDOW_LIGHT/DARK、两份 start_window_background 一致
  static get BG_TOP(): string {
    return ThemeService.isDark() ? '#0A0B10' : '#E9EEF6';
  }

  static get BG_END(): string {
    return ThemeService.isDark() ? '#060608' : '#D5DBE8';
  }

  // 卡片：深色下比纯黑亮两档，浅色下纯白
  static get BG_CARD(): string {
    return ThemeService.isDark() ? '#222327' : '#FAFAFB';
  }

  /**
   * 通透卡片底色：只给 GlassCard 用，让背景光斑隐约透出来。
   * BG_CARD 还被弹窗、日志等实色区域使用，不能直接改成半透明
   */
  static get CARD_GLASS(): string {
    return ThemeService.isDark() ? 'rgba(34, 35, 39, 0.82)' : 'rgba(255, 255, 255, 0.55)';
  }

  /**
   * 雾面玻璃（浅色）：半透明白底 + 一圈亮白描边 + 大半径柔和投影，元素像浮在雾面上。
   * 深色下描边退回 STROKE_SOFT、不加投影，保持原来的样子。
   */
  static get GLASS_RIM(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.05)' : 'rgba(255, 255, 255, 0.85)';
  }

  /** 雾面次级按钮底色 */
  static get GLASS_BTN_FILL(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.05)' : 'rgba(255, 255, 255, 0.62)';
  }

  /** 雾面投影色（只在浅色下使用） */
  static get GLASS_SHADOW(): string {
    return 'rgba(62, 78, 120, 0.13)';
  }

  static get BG_INPUT(): string {
    return ThemeService.isDark() ? '#18191C' : '#EDF1F6';
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
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.10)' : '#D3D7DE';
  }

  static get STROKE_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.05)' : '#DFE2E8';
  }

  // 文本：主文字拉到最高对比，次要/三级也各提一档
  static get TEXT_PRIMARY(): string {
    return ThemeService.isDark() ? '#FFFFFF' : '#1B1F24';
  }

  static get TEXT_SECONDARY(): string {
    return ThemeService.isDark() ? '#B4BDCA' : '#4B5462';
  }

  static get TEXT_TERTIARY(): string {
    return ThemeService.isDark() ? '#8792A1' : '#545D6A';
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
   * 浅色下用天空蓝 #0EA5E9（比 ACCENT 深半档，保留天空蓝的观感；对比度约 2.8:1，只用于短标签，不用于正文），
   * 深色下直接用 ACCENT。
   */
  static get ACCENT_TEXT(): string {
    return ThemeService.isDark() ? '#38BDF8' : '#0EA5E9';
  }

  static get ACCENT_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(56, 189, 248, 0.16)' : 'rgba(56, 189, 248, 0.14)';
  }

  static get ACCENT_LINE(): string {
    return 'rgba(56, 189, 248, 0.38)';
  }

  /**
   * 控件配色规则（全应用统一，新增控件照此取色）：
   * 1. 浅底上的强调文字 / 图标一律用 ACCENT_TEXT；ACCENT 只用于填充（实心底、进度、波形、圆点）。
   * 2. 实心 ACCENT 底上的文字 / 图标一律用 ON_ACCENT。
   * 3. 动作胶囊（扫描、去连接、更换、选择、复制等）统一用 components/PillButton：中性玻璃底，语气只体现在文字颜色上。
   * 4. 选项胶囊（排序、筛选、反馈类型、外观、内置音效）：选中 = 实心 ACCENT + ON_ACCENT，
   *    未选中 = CHIP_IDLE 底 + CHIP_IDLE_STROKE 边 + TEXT_SECONDARY。
   * 5. 播放控件：未播放 = FILL_SOFT 底 + TEXT_SECONDARY 图标（无颜色）；播放中 = 实心 ACCENT + ON_ACCENT。
   * 总原则：只有「选中 / 正在进行」才上颜色（实心天空蓝），其余一律中性。
   */
  static get ON_ACCENT(): string {
    return '#05080E';
  }

  /** 未选中的胶囊底色：深色是淡白，浅色是半透明白（放在雾面背景和白卡片上都看得见） */
  static get CHIP_IDLE(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.06)' : 'rgba(255, 255, 255, 0.55)';
  }

  static get CHIP_IDLE_STROKE(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.07)' : 'rgba(30, 45, 80, 0.09)';
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
