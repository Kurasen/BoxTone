/**
 * 视觉设计令牌：深色沉浸主题
 * 颜色统一使用十六进制或 rgba，避免使用颜色名
 */

export class Palette {
  // 背景
  static readonly BG_TOP: string = '#070A10';
  static readonly BG_BOTTOM: string = '#0D1524';
  static readonly BG_CARD: string = 'rgba(255, 255, 255, 0.05)';
  static readonly BG_CARD_STRONG: string = 'rgba(255, 255, 255, 0.08)';
  static readonly BG_INPUT: string = 'rgba(255, 255, 255, 0.04)';

  // 描边
  static readonly STROKE: string = 'rgba(255, 255, 255, 0.10)';
  static readonly STROKE_SOFT: string = 'rgba(255, 255, 255, 0.06)';

  // 文本
  static readonly TEXT_PRIMARY: string = '#F2F6FB';
  static readonly TEXT_SECONDARY: string = '#9AA6B8';
  static readonly TEXT_TERTIARY: string = '#5E697B';

  // 品牌
  static readonly ACCENT: string = '#4ED8FF';
  static readonly ACCENT_DEEP: string = '#1FA8D8';
  static readonly ACCENT_SOFT: string = 'rgba(78, 216, 255, 0.14)';
  static readonly VIOLET: string = '#9B7BFF';
  static readonly VIOLET_SOFT: string = 'rgba(155, 123, 255, 0.14)';

  // 语义
  static readonly SUCCESS: string = '#43D6A0';
  static readonly SUCCESS_SOFT: string = 'rgba(67, 214, 160, 0.14)';
  static readonly WARNING: string = '#FFB84D';
  static readonly WARNING_SOFT: string = 'rgba(255, 184, 77, 0.14)';
  static readonly DANGER: string = '#FF6B7A';
  static readonly DANGER_SOFT: string = 'rgba(255, 107, 122, 0.14)';

  // 光斑
  static readonly HALO_CYAN: string = 'rgba(78, 216, 255, 0.18)';
  static readonly HALO_VIOLET: string = 'rgba(155, 123, 255, 0.16)';
  static readonly HALO_TEAL: string = 'rgba(31, 168, 216, 0.12)';
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
  static readonly BODY_SIZE: number = 13;
  static readonly CAPTION_SIZE: number = 11;
}
