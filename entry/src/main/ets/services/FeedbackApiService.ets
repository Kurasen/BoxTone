import { http } from '@kit.NetworkKit';
import { I18n } from '../common/i18n/I18n';
import { Logger } from '../common/utils/Logger';

const MODULE: string = 'FeedbackApi';

/**
 * 反馈后端配置
 *
 * 上架版不把邮箱授权码放进安装包：应用只向自己的服务端发 HTTPS 请求，
 * 由服务端去投递邮件。留空时退回系统分享。
 */
export class FeedbackApiConfig {
  /**
   * 反馈接口地址，例如 https://api.example.com/feedback
   *
   * 暂时停用：不填地址时会退回系统分享（见 FeedbackService.submit）。
   * 需要恢复上报时取消下面一行注释并填回接口地址。
   */
  // static readonly ENDPOINT: string = 'https://1311785285-0cro9783mh.ap-guangzhou.tencentscf.com/feedback';
  static readonly ENDPOINT: string = '';
  /** 可选鉴权令牌，会以 Bearer 形式放在 Authorization 头 */
  static readonly TOKEN: string = '';
  static readonly TIMEOUT_MS: number = 60000;
}

export interface FeedbackPayload {
  typeLabel: string;
  description: string;
  contact: string;
  device: string;
  appVersion: string;
  createdAt: number;
  /** 诊断日志纯文本 */
  log: string;
  /** 截图 base64（不含 data: 前缀） */
  images: string[];
}

/**
 * 反馈上报
 * 接口约定：POST JSON，返回 2xx 视为成功
 */
export class FeedbackApiService {
  public static isConfigured(): boolean {
    return FeedbackApiConfig.ENDPOINT.length > 0;
  }

  public static async submit(payload: FeedbackPayload): Promise<void> {
    if (!FeedbackApiService.isConfigured()) {
      throw new Error(I18n.t('fb.apiNotConfigured'));
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json' };
      if (FeedbackApiConfig.TOKEN.length > 0) {
        header['Authorization'] = `Bearer ${FeedbackApiConfig.TOKEN}`;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: FeedbackApiConfig.TIMEOUT_MS
      };
      const response: http.HttpResponse = await request.request(FeedbackApiConfig.ENDPOINT, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(I18n.f('fb.apiStatus', [`${response.responseCode}`]));
      }
      Logger.info(MODULE, `反馈已提交 状态=${response.responseCode}`);
    } finally {
      request.destroy();
    }
  }
}
