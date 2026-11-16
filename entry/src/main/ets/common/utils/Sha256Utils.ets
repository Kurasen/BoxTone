import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

const MODULE: string = 'Sha256';

/**
 * SHA-256 摘要
 *
 * 音效包规范要求 SHA-256 覆盖「48 字节音频头 + PCM」，
 * 耳机用这份摘要校验收到的内容是否完整。
 */
export class Sha256Utils {
  static digest(data: Uint8Array): Uint8Array {
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const blob: cryptoFramework.DataBlob = { data: data };
      md.updateSync(blob);
      const result: cryptoFramework.DataBlob = md.digestSync();
      return result.data;
    } catch (error) {
      Logger.exception(MODULE, '计算音效包摘要失败', error as BusinessError);
      throw error as Error;
    }
  }
}
