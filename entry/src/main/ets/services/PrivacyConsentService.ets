import { bundleManager, common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { AppEvent, EventBus } from '../common/utils/EventBus';
import { Logger } from '../common/utils/Logger';
import { AppBootstrap } from './AppBootstrap';

const MODULE: string = 'PrivacyConsent';
const EVENT_PRIVACY_STATE_CHANGED: string = 'usual.event.PRIVACY_STATE_CHANGED';
const RESULT_AGREED: number = 1;
/** 应用未接入隐私托管（本地调试 / AGC 后台未配置） */
const CODE_NOT_INTEGRATED: number = 1006700003;
/** 系统内部错误：可延迟重试 */
const CODE_INTERNAL: number = 1006700001;
/** 服务扩展连接失败：可延迟重试 */
const CODE_SERVICE_DOWN: number = 1006700002;
/** 冷启动时 AppGallery 隐私服务可能还没连上，拉不起来时隔这么久重试一次 */
const RETRY_DELAY_MS: number = 600;
/** 最多尝试次数：首次失败重试一次 */
const MAX_ATTEMPTS: number = 2;

/**
 * 隐私签署状态。
 * 用字符串枚举，日志里直接打印取值，避免自定义序号与系统接口的 0/1 结果值混在一起看反。
 */
enum ConsentState {
  AGREED = '已同意',
  DISAGREED = '未同意',
  /** 查询不到：应用未接入托管，或隐私服务尚未就绪 */
  UNAVAILABLE = '不可用'
}

interface PrivacyStatePayload {
  resultType: number;
  appIndex: number;
}

/**
 * 隐私声明采用 AGC 隐私托管（全模式），由系统标准化弹窗征得同意，应用内不自绘任何隐私界面。
 *
 * 时序（同意前不读取任何个人信息）：
 * 1. onCreate → start()：只查一次签署状态、订阅签署事件，**不初始化业务**；
 * 2. 首页首帧只渲染渐变背景与占位（Index 的 privacyGate），不读文件、不连设备；
 * 3. onPageShow → settle()：窗口就绪后拉起系统弹窗，同意即放行；
 * 4. 放行是业务初始化的唯一入口（markCleared → AppBootstrap.init），拒绝则退出应用。
 *
 * 关于「本地包为什么没有弹窗」：隐私托管由云侧识别应用，只有从应用市场安装（含邀请测试）
 * 的包才会弹。hdc 侧载的 debug / release 包一律报 1006700003，属正常现象，
 * 因此侧载包放行、市场包从严（见 mustEnforce）。
 */
export class PrivacyConsentService {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private static started: boolean = false;
  /**
   * 正在进行的征询：并发调用复用同一个 Promise，完成后清空。
   */
  private static pending: Promise<boolean> | undefined = undefined;
  /**
   * 本次进程内隐私闸门是否已放行（已同意，或确认无从征询）。
   * 这是「能不能读文件 / 连设备」的唯一判据：AppBootstrap 的初始化标记
   * 与界面是否渲染都不代表用户已经同意过。
   */
  private static cleared: boolean = false;
  /**
   * 判定为「该征询但征询不了」：首页渲染重试页，而不是静默放行、也不是直接退出。
   * 与 cleared 互斥，retry() 会清掉它重新走一次。
   */
  private static blocked: boolean = false;

  public static start(context: common.UIAbilityContext): void {
    // 每次 onCreate 都刷新 context：Ability 重建后旧引用可能已失效
    PrivacyConsentService.context = context;
    if (PrivacyConsentService.started) {
      return;
    }
    PrivacyConsentService.started = true;
    PrivacyConsentService.blocked = false;

    const state: ConsentState = PrivacyConsentService.query('启动');
    if (state === ConsentState.AGREED) {
      PrivacyConsentService.markCleared('启动时已同意');
    }
    if (!PrivacyConsentService.cleared) {
      // 系统托管可能比应用晚一步就绪，不订阅的话用户在弹窗里点「同意」应用感知不到
      PrivacyConsentService.subscribe();
    }
  }

  /**
   * 隐私征询：页面已上屏后调用（Index.onPageShow）。onCreate 阶段窗口尚未就绪，
   * 系统弹窗拉不起来；aboutToAppear 又早于首帧，会看到「占位一闪就被弹窗盖住」。
   *
   * 不做超时兜底：requestAppPrivacyConsent 的语义就是「等用户读完再操作」，
   * 超时只会把读得慢的用户误判成拒绝。
   *
   * @returns 用户是否已同意；false 表示拒绝、系统故障或已进入重试态（用 isBlocked 区分）
   */
  public static settle(): Promise<boolean> {
    if (PrivacyConsentService.cleared) {
      return Promise.resolve(true);
    }
    if (PrivacyConsentService.pending === undefined) {
      PrivacyConsentService.pending = PrivacyConsentService.requestConsent().finally((): void => {
        PrivacyConsentService.pending = undefined;
      });
    }
    return PrivacyConsentService.pending;
  }

  /**
   * 重试页的「重试」：清掉阻断标记重新征询。
   * 市场包报 1006700003 多半是签名/托管配置没被识别，重试通常无效但可让用户自己再试一次；
   * 系统内部错误（1006700001/2）重试则大概率能恢复。
   */
  public static retry(): Promise<boolean> {
    PrivacyConsentService.blocked = false;
    PrivacyConsentService.pending = undefined;
    return PrivacyConsentService.settle();
  }

  /** 是否处于「该征询但征询不了」的重试态：页面据此渲染重试而不是直接退出 */
  public static isBlocked(): boolean {
    return PrivacyConsentService.blocked;
  }

  /**
   * 隐私闸门是否已放行。
   * 页面用它决定要不要做「读文件 / 连设备」这类重活：
   * 系统弹窗还没处理完时解码音频、扫音效库，等于在用户同意前处理数据。
   */
  public static isCleared(): boolean {
    return PrivacyConsentService.cleared;
  }

  /**
   * 标记放行：业务初始化与界面切换的唯一入口。
   * 只在「未放行 → 放行」的瞬间触发，重复调用无副作用。
   */
  private static markCleared(reason: string): void {
    if (PrivacyConsentService.cleared) {
      return;
    }
    PrivacyConsentService.cleared = true;
    PrivacyConsentService.blocked = false;
    Logger.dev(MODULE, `隐私闸门放行（${reason}）`);
    // 先初始化再广播：页面收到 PRIVACY_CLEARED 时读到的就是准备好的数据
    PrivacyConsentService.ensureInit(reason);
    EventBus.emit(AppEvent.PRIVACY_CLEARED, 1);
  }

  /**
   * 拉起系统标准化隐私弹窗。内部吞掉异常，不会 reject。
   *
   * 错误码分流（官方建议：不同错误码不同策略，1006700003 不建议连续重试）：
   * - 1006700001 系统内部错误 / 1006700002 服务连接失败 → 有限次延迟重试，仍失败进重试页；
   * - 1006700003 未接入 → 侧载包属正常（云侧没有托管配置，本来就弹不出来），放行；
   *   市场包则是签名/托管配置没被识别，绝不能当作「没接入」放行，进重试页；
   * - 其他未知错误 → 进重试页。
   *
   * 关键：只有「确定无法征询」才放行，判定不了一律不放行。
   */
  private static async requestConsent(): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = PrivacyConsentService.context;
    if (context === undefined) {
      Logger.warn(MODULE, '缺少 context，无法征询');
      PrivacyConsentService.blocked = true;
      return false;
    }
    // 系统可能在首页上屏这段时间已经自动弹过弹窗并完成了签署，先复查一次再决定要不要拉，
    // 否则会出现用户刚同意完又被弹一次的情况
    if (PrivacyConsentService.query('复查') === ConsentState.AGREED) {
      Logger.dev(MODULE, '复查签署状态：已同意，跳过主动征询');
      PrivacyConsentService.markCleared('系统已自动完成签署');
      return true;
    }
    Logger.dev(MODULE, '拉起系统隐私弹窗');
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      try {
        const result: privacyManager.ConsentResult = await privacyManager.requestAppPrivacyConsent(context);
        const agreed: boolean = PrivacyConsentService.isAgreed(result.results);
        Logger.dev(MODULE, `系统隐私弹窗结果=${agreed ? '同意' : '未同意'}`);
        if (agreed) {
          PrivacyConsentService.markCleared('弹窗同意');
        }
        return agreed;
      } catch (error) {
        const err: BusinessError = error as BusinessError;
        if (err.code === CODE_NOT_INTEGRATED) {
          if (!PrivacyConsentService.mustEnforce()) {
            // 侧载包（hdc 装的 debug / release 自测包）：云侧无托管配置，无从征询
            Logger.dev(MODULE, '侧载包未接入隐私托管，放行');
            PrivacyConsentService.markCleared('侧载包未接入隐私托管');
            return true;
          }
          Logger.warn(MODULE, `市场分发包未识别到隐私托管 code=${err.code}，进入重试页`);
          PrivacyConsentService.blocked = true;
          return false;
        }
        if ((err.code === CODE_INTERNAL || err.code === CODE_SERVICE_DOWN) && attempt < MAX_ATTEMPTS) {
          Logger.dev(MODULE, `隐私服务未就绪 code=${err.code}，${RETRY_DELAY_MS}ms 后重试`);
          await PrivacyConsentService.delay(RETRY_DELAY_MS);
          continue;
        }
        // 系统故障与未知错误都不放行：宁可让用户重试，也不能在未同意时进入业务
        Logger.warn(MODULE, `拉起系统隐私弹窗失败 code=${err.code} ${err.message}，进入重试页`);
        PrivacyConsentService.blocked = true;
        return false;
      }
    }
    PrivacyConsentService.blocked = true;
    return false;
  }

  /**
   * 是否必须征询：只有「从应用市场安装」的包才强制。
   *
   * 隐私托管由云侧按应用识别，hdc 侧载包一律拿不到配置（1006700003）——
   * 一刀切「拉不起来就阻断」会让本地包彻底不可用。
   * 反过来，市场包报 1006700003 说明签名证书或托管配置没被识别，
   * 常见于升级后偶现，属于必须拦截的合规漏洞。
   *
   * 两个信号相与，避免单一信号误判：
   * - installSource：市场安装时是市场包名，侧载是 unknown，预置是 pre-installed；
   * - appDistributionType：写在签名 profile 里，自签的 release 包也可能是 app_gallery。
   */
  private static mustEnforce(): boolean {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const source: string = info.appInfo.installSource;
      if (source.length === 0 || source === 'unknown' || source === 'pre-installed') {
        return false;
      }
      const type: string = info.appInfo.appDistributionType;
      return type === 'app_gallery' || type === 'internaltesting' || type === 'crowdtesting';
    } catch (error) {
      // 查不到安装来源时按「需要征询」处理：宁严不松
      return true;
    }
  }

  /** 取消订阅并复位启动标记：与 start() 成对，Ability 销毁时调用 */
  public static stop(): void {
    // 复位启动标记：Ability 重建后 onCreate 会再次 start()，
    // 不复位的话既不会重新查状态，也不会重新订阅签署事件（stop 里已经把订阅退了）
    PrivacyConsentService.started = false;
    // 进行中的征询与阻断态都属于上一轮界面：绑定的是旧 Ability 的 context，一律清掉
    PrivacyConsentService.pending = undefined;
    PrivacyConsentService.blocked = false;
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

  /**
   * 查询签署状态。
   *
   * 原则：查不准时绝不当成「已同意」。
   * 已确认接入全模式、但签署状态查询异常时按「未同意」处理——大不了多弹一次系统弹窗；
   * 反过来当成已同意，就是未同意即收集个人信息，属审核驳回项。
   *
   * @param scene 查询场景（启动 / 复查），只用于日志区分，
   *              否则两次查询会打印两行一模一样的文案，排查时分不清是谁查的
   */
  private static query(scene: string): ConsentState {
    try {
      const info: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      if (info.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE) {
        Logger.dev(MODULE, `${scene}：隐私管理服务未接入全模式 type=${info.type}`);
        return ConsentState.UNAVAILABLE;
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.dev(MODULE, `${scene}：接入信息查询失败 code=${err.code}`);
      return ConsentState.UNAVAILABLE;
    }

    try {
      const results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
      for (let i = 0; i < results.length; i++) {
        const item: privacyManager.AppPrivacyResult = results[i];
        if (item.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          // FULL_MODE_AGREED 已同意；DISAGREED 未同意（含用户点过取消）；
          // REQUIRE_RESIGNING_VERSION_UPDATE 协议变更需重签，同样按未同意处理
          const agreed: boolean = item.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED;
          // 这条日志必须打：之前只记录「无签署记录」，导致「点过取消后再启动」的日志里
          // 完全看不到查询动作，排查时误以为状态查询被跳过
          Logger.dev(MODULE, `${scene}：签署记录 result=${item.result}，视为${agreed ? '已同意' : '未同意'}`);
          return agreed ? ConsentState.AGREED : ConsentState.DISAGREED;
        }
      }
      // 已接入但没有任何签署记录 = 从没签过，必须征询
      Logger.dev(MODULE, `${scene}：已接入但无签署记录，视为未同意`);
      return ConsentState.DISAGREED;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.dev(MODULE, `${scene}：签署状态查询失败 code=${err.code}，按未同意处理`);
      return ConsentState.DISAGREED;
    }
  }

  private static isAgreed(results: privacyManager.AppPrivacyResult[]): boolean {
    for (let i = 0; i < results.length; i++) {
      if (results[i].type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
        return results[i].result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED;
      }
    }
    return false;
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  private static subscribe(): void {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EVENT_PRIVACY_STATE_CHANGED]
    };
    commonEventManager.createSubscriber(info)
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        try {
          commonEventManager.subscribe(subscriber,
            (error: BusinessError, data: commonEventManager.CommonEventData) => {
              if (error) {
                Logger.exception(MODULE, '隐私签署事件回调异常', error);
                return;
              }
              PrivacyConsentService.onPrivacyEvent(data.data !== undefined ? data.data : '');
            });
          // 订阅成功后才记录：否则 stop() 会对一个没订阅上的订阅者调 unsubscribe，必然报错
          PrivacyConsentService.subscriber = subscriber;
        } catch (error) {
          Logger.exception(MODULE, '订阅隐私签署事件失败', error as BusinessError);
        }
      })
      .catch((error: BusinessError) => {
        Logger.exception(MODULE, '创建隐私事件订阅者失败', error);
      });
  }

  /**
   * 签署事件与弹窗返回值描述的是同一次操作：
   * 结论由 requestConsent 输出，这里只在 debug 包记录原始数据，并在用户同意时补一次初始化。
   */
  private static onPrivacyEvent(raw: string): void {
    Logger.dev(MODULE, `隐私签署事件 data=${raw.length > 0 ? raw : '(空)'}`);
    if (raw.length === 0) {
      return;
    }
    try {
      const payload: PrivacyStatePayload = JSON.parse(raw) as PrivacyStatePayload;
      if (payload.resultType === RESULT_AGREED) {
        // 系统自动弹出的托管弹窗不会经过 settle()，这里补上闸门标记，
        // 避免下次 settle() 又弹一遍（业务初始化由 markCleared 统一触发）
        PrivacyConsentService.markCleared('签署事件同意');
      }
    } catch (parseError) {
      Logger.exception(MODULE, '解析隐私签署事件失败', parseError as BusinessError);
    }
  }

  /**
   * 初始化业务服务。
   * 页面在同意前就已经渲染（空态），这里初始化完成后由 PRIVACY_CLEARED 事件触发各页刷新。
   */
  private static ensureInit(reason: string): void {
    const context: common.UIAbilityContext | undefined = PrivacyConsentService.context;
    if (context === undefined) {
      return;
    }
    AppBootstrap.init(context, reason);
  }
}
