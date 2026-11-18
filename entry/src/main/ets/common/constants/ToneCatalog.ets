import { I18n } from '../i18n/I18n';

/**
 * 盒端内置提示音表
 *
 * id 与名称都由固件/官方音效表定义，不是本应用的数据。切换内置音效只是让盒端
 * 换成另一段自带的音效，不涉及闪存写入，所以可以随便试、随时切回。
 *
 * 数据来源：官方音效配置 tone_config.json（version 3，00000A 设备族）中
 * 带 support 标记的条目按其适用机型过滤；官方云端另有一条 200 "肖邦"
 * （support=00016D_19，仅特定机型+固件），未收录，避免出现选了必然失败的项。
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
  /** FreeClip 2（固件自报型号 BTFT0027） */
  private static readonly FREECLIP2: ToneOption[] = [
    { id: 0, zh: '舒展', en: 'Unfold' },
    { id: 4, zh: '邦戈手鼓', en: 'Bongo' },
    { id: 7, zh: '棋', en: 'Chess' },
    { id: 10, zh: '晶莹', en: 'Dewdrop' },
    { id: 11, zh: '门铃', en: 'Doorbell' },
    { id: 12, zh: '嘀嗒', en: 'Drip' },
    // 14 号在官方表里标为 custom，是留给自建音效的槽位，原厂出厂时放的是「新发现」
    { id: 14, zh: '新发现', en: 'Emerging' },
    { id: 15, zh: '喷泉', en: 'Fountain' },
    { id: 18, zh: '华为经典', en: 'Huawei Cascade' },
    { id: 22, zh: '跃动', en: 'Leap' },
    { id: 25, zh: '点亮', en: 'Lit' },
    { id: 26, zh: '如愿以偿', en: 'Little Wish' },
    { id: 28, zh: '冥想', en: 'Meditation' },
    { id: 31, zh: '精灵', en: 'Pixies' },
    { id: 32, zh: '游戏', en: 'Play' },
    { id: 34, zh: '追逐', en: 'Pursue' },
    { id: 35, zh: '昂扬', en: 'Rise' },
    { id: 36, zh: '照耀', en: 'Shine' },
    // 43 号是出厂自带的「口哨」，也是本应用早先写入自定义音效时占用的槽位
    { id: 43, zh: '口哨', en: 'Whistle' }
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
