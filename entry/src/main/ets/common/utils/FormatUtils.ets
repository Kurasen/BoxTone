import { I18n } from '../i18n/I18n';

export class FormatUtils {
  /** 字节数 → 人类可读，保留一位小数 */
  public static bytes(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / 1024 / 1024).toFixed(2)} MB`;
  }

  /** 毫秒 → 0.00s */
  public static seconds(ms: number): string {
    return `${(ms / 1000).toFixed(2)}s`;
  }

  /** 毫秒 → mm:ss.S */
  public static duration(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000);
    const minute: number = Math.floor(totalSec / 60);
    const second: number = totalSec % 60;
    const tenth: number = Math.floor((ms % 1000) / 100);
    const minText: string = minute < 10 ? `0${minute}` : `${minute}`;
    const secText: string = second < 10 ? `0${second}` : `${second}`;
    return `${minText}:${secText}.${tenth}`;
  }

  /** 采样率显示，如 44.1 kHz */
  public static sampleRate(rate: number): string {
    if (rate % 1000 === 0) {
      return `${rate / 1000} kHz`;
    }
    return `${(rate / 1000).toFixed(1)} kHz`;
  }

  /** 声道数显示 */
  public static channelName(channels: number): string {
    if (channels === 1) {
      return I18n.t('format.mono');
    }
    if (channels === 2) {
      return I18n.t('format.stereo');
    }
    return I18n.f('format.channelCount', [`${channels}`]);
  }

  /** 带符号的增益显示 */
  public static gain(db: number): string {
    if (db > 0) {
      return `+${db.toFixed(1)} dB`;
    }
    return `${db.toFixed(1)} dB`;
  }

  /** 设备地址脱敏：AA:BB:CC:DD:EE:FF → AA:BB:**:EE:FF */
  public static maskAddress(deviceId: string): string {
    const parts: string[] = deviceId.split(':');
    if (parts.length !== 6) {
      return deviceId;
    }
    return `${parts[0]}:${parts[1]}:**:${parts[4]}:${parts[5]}`;
  }
}
