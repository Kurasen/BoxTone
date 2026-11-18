import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'PrivacyLink';
/** AGC 隐私托管未生效时的公开声明链接（调试包、侧载安装、托管暂不可用） */
const FALLBACK_STATEMENT_URL: string =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2085446646178567424';

/**
 * 隐私声明由 AGC 隐私托管：链接优先来自隐私管理服务，
 * 托管未生效时回退到已发布的公开声明，保证应用内入口始终可用
 */
export class PrivacyLinkService {
  private static cachedUrl: string | undefined = undefined;
  private static fallbackLogged: boolean = false;

  /** 隐私声明链接：托管链接优先，取不到时返回公开声明兜底 */
  public static statementUrl(): string {
    if (PrivacyLinkService.cachedUrl !== undefined) {
      return PrivacyLinkService.cachedUrl;
    }
    let url: string = '';
    try {
      const info: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      const links: privacyManager.AppPrivacyLink[] = info.privacyInfo;
      for (let i = 0; i < links.length; i++) {
        if (links[i].type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK) {
          url = links[i].url;
          break;
        }
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 1006700003) {
        // 本地调试或未接入 AGC 隐私托管：没有链接属于正常状态，不按异常刷 ERROR
        Logger.warn(MODULE, '应用未接入隐私托管，使用公开声明兜底');
      } else {
        Logger.exception(MODULE, '读取托管隐私声明链接失败，使用公开声明兜底', businessError);
      }
    }
    // 只缓存托管结果：托管恢复后仍能切换到 AGC 下发的链接
    if (url.length > 0) {
      PrivacyLinkService.cachedUrl = url;
      return url;
    }
    if (!PrivacyLinkService.fallbackLogged) {
      PrivacyLinkService.fallbackLogged = true;
      Logger.info(MODULE, '使用内置公开声明链接');
    }
    return FALLBACK_STATEMENT_URL;
  }

  /** 打开隐私声明（托管优先，失败回退公开链接）；打开失败返回 false */
  public static async open(context: common.UIAbilityContext): Promise<boolean> {
    const url: string = PrivacyLinkService.statementUrl();
    if (url.length === 0) {
      return false;
    }
    try {
      await context.openLink(url);
      return true;
    } catch (error) {
      Logger.exception(MODULE, '打开隐私声明失败', error as BusinessError);
      return false;
    }
  }
}
