import { I18n } from '../i18n/I18n';

/**
 * 盒端内置提示音表
 *
 * id 与名称都由固件/官方音效表定义，不是本应用的数据。切换内置音效只是让盒端
 * 换成另一段自带的音效，不涉及闪存写入，所以可以随便试、随时切回。
 *
 * 表按型号分开维护：型号来自耳机自报（0107 tag 15），未收录的型号返回空数组，
 * 界面据此隐藏选择器，避免给出对不上的名称。
 */
export interface ToneOption {
  id: number;
  zh: string;
  en: string;
}

export class ToneCatalog {
  /** FreeClip 2（固件自报型号 BTFT0027）：官方音效表中已确认的条目 */
  private static readonly FREECLIP2: ToneOption[] = [
    { id: 0, zh: '舒展', en: 'Relax' },
    { id: 4, zh: '邦戈手鼓', en: 'Bongo' },
    { id: 7, zh: '棋', en: 'Chess' },
    { id: 10, zh: '晶莹', en: 'Crystal' },
    { id: 11, zh: '门铃', en: 'Doorbell' },
    { id: 12, zh: '嘀嗒', en: 'Tick' },
    { id: 14, zh: '新发现', en: 'Discovery' },
    { id: 15, zh: '喷泉', en: 'Fountain' },
    { id: 18, zh: '华为经典', en: 'Huawei classic' },
    { id: 22, zh: '跃动', en: 'Vivid' },
    { id: 31, zh: '精灵', en: 'Sprite' }
  ];

  /** 取某型号可切换的内置音效；未收录型号返回空数组 */
  static options(hwModel: string): ToneOption[] {
    const model: string = hwModel.toUpperCase();
    if (model === 'BTFT0027') {
      return ToneCatalog.FREECLIP2;
    }
    return [];
  }

  /** 名称按当前语言取，英文缺失时退回中文 */
  static label(option: ToneOption): string {
    const name: string = I18n.isEnglish() ? option.en : option.zh;
    return `${option.id} · ${name.length > 0 ? name : option.zh}`;
  }
}
