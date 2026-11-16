import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'PrivacyLink';

/**
 * 隐私声明由 AGC 隐私托管：链接来自隐私管理服务，应用内不再内置声明正文，
 * 避免系统弹窗与应用内文本出现两套版本
 */
export class PrivacyLinkService {
  private static cachedUrl: string | undefined = undefined;

  /** 托管隐私声明链接；未配置或隐私管理服务不可用时返回空串 */
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
      Logger.exception(MODULE, '读取托管隐私声明链接失败', error as BusinessError);
    }
    // 只缓存成功结果：调试安装或服务暂不可用时留给下次重试
    if (url.length > 0) {
      PrivacyLinkService.cachedUrl = url;
    }
    return url;
  }

  /** 打开托管隐私声明；无链接或打开失败返回 false */
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
