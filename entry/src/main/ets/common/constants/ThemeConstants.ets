import { ThemeService } from '../../services/ThemeService';

/**
 * 视觉设计令牌：深色 / 浅色两套
 * 颜色统一使用十六进制或 rgba，避免使用颜色名；
 * 取值时按当前外观返回，切换外观后由组件重绘生效
 */

export class Palette {
  // 背景
  static get BG_TOP(): string {
    return ThemeService.isDark() ? '#070A10' : '#F4F7FC';
  }

  static get BG_BOTTOM(): string {
    return ThemeService.isDark() ? '#0D1524' : '#E8EFF9';
  }

  static get BG_END(): string {
    return ThemeService.isDark() ? '#0A1120' : '#DFE8F4';
  }

  static get BG_CARD(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.05)' : 'rgba(255, 255, 255, 0.72)';
  }

  static get BG_CARD_STRONG(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : 'rgba(255, 255, 255, 0.92)';
  }

  static get BG_INPUT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.04)' : 'rgba(15, 26, 46, 0.04)';
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

  // 描边
  static get STROKE(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.10)' : 'rgba(15, 26, 46, 0.12)';
  }

  static get STROKE_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.06)' : 'rgba(15, 26, 46, 0.08)';
  }

  // 文本
  static get TEXT_PRIMARY(): string {
    return ThemeService.isDark() ? '#F2F6FB' : '#182233';
  }

  static get TEXT_SECONDARY(): string {
    return ThemeService.isDark() ? '#9AA6B8' : '#5A6779';
  }

  static get TEXT_TERTIARY(): string {
    return ThemeService.isDark() ? '#5E697B' : '#8A96A8';
  }

  static get TEXT_FAINT(): string {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.22)' : 'rgba(94, 105, 123, 0.65)';
  }

  // 品牌
  static get ACCENT(): string {
    return ThemeService.isDark() ? '#4ED8FF' : '#0E9FC5';
  }

  static get ACCENT_DEEP(): string {
    return ThemeService.isDark() ? '#1FA8D8' : '#0B87A8';
  }

  static get ACCENT_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(78, 216, 255, 0.14)' : 'rgba(14, 159, 197, 0.12)';
  }

  static get ACCENT_LINE(): string {
    return ThemeService.isDark() ? 'rgba(78, 216, 255, 0.32)' : 'rgba(14, 159, 197, 0.32)';
  }

  static get VIOLET(): string {
    return ThemeService.isDark() ? '#9B7BFF' : '#7A5AF8';
  }

  static get VIOLET_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(155, 123, 255, 0.14)' : 'rgba(122, 90, 248, 0.12)';
  }

  // 语义
  static get SUCCESS(): string {
    return ThemeService.isDark() ? '#43D6A0' : '#0FA97C';
  }

  static get SUCCESS_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(67, 214, 160, 0.14)' : 'rgba(15, 169, 124, 0.12)';
  }

  static get WARNING(): string {
    return ThemeService.isDark() ? '#FFB84D' : '#C07A00';
  }

  static get WARNING_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 184, 77, 0.14)' : 'rgba(192, 122, 0, 0.12)';
  }

  static get DANGER(): string {
    return ThemeService.isDark() ? '#FF6B7A' : '#DE4A5E';
  }

  static get DANGER_SOFT(): string {
    return ThemeService.isDark() ? 'rgba(255, 107, 122, 0.14)' : 'rgba(222, 74, 94, 0.12)';
  }

  // 光斑
  static get HALO_CYAN(): string {
    return ThemeService.isDark() ? 'rgba(78, 216, 255, 0.22)' : 'rgba(14, 159, 197, 0.10)';
  }

  static get HALO_VIOLET(): string {
    return ThemeService.isDark() ? 'rgba(155, 123, 255, 0.18)' : 'rgba(122, 90, 248, 0.08)';
  }

  static get HALO_TEAL(): string {
    return ThemeService.isDark() ? 'rgba(31, 168, 216, 0.16)' : 'rgba(31, 168, 216, 0.07)';
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
  static readonly BODY_SIZE: number = 13;
  static readonly CAPTION_SIZE: number = 11;
}
