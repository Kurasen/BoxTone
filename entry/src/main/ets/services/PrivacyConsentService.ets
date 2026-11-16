import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { AppEvent, EventBus } from '../common/utils/EventBus';
import { Logger } from '../common/utils/Logger';
import { AppBootstrap } from './AppBootstrap';

const MODULE: string = 'PrivacyConsent';
const EVENT_PRIVACY_STATE_CHANGED: string = 'usual.event.PRIVACY_STATE_CHANGED';
const RESULT_AGREED: number = 1;

enum ConsentState {
  AGREED,
  DISAGREED,
  UNAVAILABLE
}

interface PrivacyStatePayload {
  resultType: number;
  appIndex: number;
}

/**
 * 隐私声明采用 AGC 隐私托管，首次启动由系统弹出标准化弹窗；
 * 应用自身不再弹窗，只负责在用户同意之后再初始化业务服务
 */
export class PrivacyConsentService {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private static started: boolean = false;

  public static start(context: common.UIAbilityContext): void {
    if (PrivacyConsentService.started) {
      return;
    }
    PrivacyConsentService.started = true;
    PrivacyConsentService.context = context;
    const state: ConsentState = PrivacyConsentService.query();
    Logger.info(MODULE, `隐私签署状态=${state}`);
    if (state === ConsentState.DISAGREED) {
      PrivacyConsentService.subscribe();
    } else {
      // 已同意，或未接入托管（本地调试 / 模拟器 / 未上架），照常启动
      PrivacyConsentService.ensureInit();
    }
  }

  public static stop(): void {
    const subscriber: commonEventManager.CommonEventSubscriber | undefined = PrivacyConsentService.subscriber;
    if (subscriber === undefined) {
      return;
    }
    PrivacyConsentService.subscriber = undefined;
    commonEventManager.unsubscribe(subscriber, (error: BusinessError) => {
      if (error) {
        Logger.exception(MODULE, '取消隐私事件订阅失败', error);
      }
    });
  }

  private static query(): ConsentState {
    try {
      const results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
      for (let i = 0; i < results.length; i++) {
        if (results[i].type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          return results[i].result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED
            ? ConsentState.AGREED : ConsentState.DISAGREED;
        }
      }
    } catch (error) {
      // 1006700003：应用未接入隐私托管，按无需托管处理
      Logger.warn(MODULE, '隐私管理服务不可用，跳过托管校验');
      return ConsentState.UNAVAILABLE;
    }
    return ConsentState.UNAVAILABLE;
  }

  private static subscribe(): void {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EVENT_PRIVACY_STATE_CHANGED]
    };
    commonEventManager.createSubscriber(info)
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        PrivacyConsentService.subscriber = subscriber;
        try {
          commonEventManager.subscribe(subscriber,
            (error: BusinessError, data: commonEventManager.CommonEventData) => {
              if (error) {
                Logger.exception(MODULE, '隐私签署事件回调异常', error);
                return;
              }
              const raw: string = data.data !== undefined ? data.data : '';
              if (raw.length === 0) {
                return;
              }
              try {
                const payload: PrivacyStatePayload = JSON.parse(raw) as PrivacyStatePayload;
                if (payload.resultType === RESULT_AGREED) {
                  PrivacyConsentService.ensureInit();
                }
              } catch (parseError) {
                Logger.exception(MODULE, '解析隐私签署事件失败', parseError as BusinessError);
              }
            });
        } catch (error) {
          Logger.exception(MODULE, '订阅隐私签署事件失败', error as BusinessError);
        }
      })
      .catch((error: BusinessError) => {
        Logger.exception(MODULE, '创建隐私事件订阅者失败', error);
      });
  }

  private static ensureInit(): void {
    const context: common.UIAbilityContext | undefined = PrivacyConsentService.context;
    if (context === undefined) {
      return;
    }
    AppBootstrap.init(context);
    // 页面可能先于同意完成构建，这里补一次刷新（统计与演示状态都依赖已初始化的服务）
    EventBus.emit(AppEvent.TONE_CHANGED, 1);
    EventBus.emit(AppEvent.PRIVACY_READY, 1);
  }
}
