import { i18n } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../common/i18n/I18n';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'Language';
/** 使用简体中文的地区，其余地区一律 English */
const HANS_REGIONS: string[] = ['CN', 'HK', 'MO', 'TW'];

/**
 * 应用语言：每次启动按设备地区判定（幂等，不锁死首次结果）
 * 中国内地 / 香港 / 澳门 / 台湾 → 简体中文；其他地区 → English
 *
 * 之所以每次启动判定而不是只判定一次：用户修改系统地区后无需清数据，
 * 下次启动即生效；也不会把用户永久固定在首次启动时的语言上。
 */
export class LanguageService {
  public static apply(): void {
    try {
      const region: string = i18n.System.getSystemRegion().toUpperCase();
      const language: string = HANS_REGIONS.indexOf(region) >= 0 ? 'zh-Hans' : 'en-US';
      i18n.System.setAppPreferredLanguage(language);
      I18n.use(language);
      Logger.info(MODULE, `地区=${region} 应用语言=${language}`);
    } catch (error) {
      Logger.warn(MODULE, `设置应用语言失败 code=${(error as BusinessError).code}`);
    }
  }
}
