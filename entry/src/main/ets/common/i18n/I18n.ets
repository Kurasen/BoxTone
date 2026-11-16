import { i18n } from '@kit.LocalizationKit';
import { EN_STRINGS, ZH_STRINGS } from './Strings';

/**
 * 运行时文案取值
 *
 * 语言由 LanguageService 在启动时判定并调用 use()；未调用时退回系统偏好语言。
 * 字典方式覆盖了模板插值、服务层提示等无法直接用 $r 的场景。
 */
export class I18n {
  private static english: boolean = false;
  private static initialized: boolean = false;

  public static use(language: string): void {
    I18n.english = !language.toLowerCase().startsWith('zh');
    I18n.initialized = true;
  }

  public static isEnglish(): boolean {
    if (!I18n.initialized) {
      I18n.use(I18n.preferredLanguage());
    }
    return I18n.english;
  }

  public static t(key: string): string {
    const table: Record<string, string> = I18n.isEnglish() ? EN_STRINGS : ZH_STRINGS;
    const text: string | undefined = table[key];
    if (text !== undefined) {
      return text;
    }
    const fallback: string | undefined = ZH_STRINGS[key];
    return fallback !== undefined ? fallback : key;
  }

  public static f(key: string, args: string[]): string {
    let text: string = I18n.t(key);
    for (let i = 0; i < args.length; i++) {
      text = text.replace(`{${i}}`, args[i]);
    }
    return text;
  }

  private static preferredLanguage(): string {
    try {
      const preferred: string = i18n.System.getAppPreferredLanguage();
      if (preferred.length > 0) {
        return preferred;
      }
    } catch (error) {
    }
    try {
      return i18n.System.getSystemLanguage();
    } catch (error) {
      return 'zh-Hans';
    }
  }
}
