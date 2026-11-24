/**
 * 内置音效目录
 *
 * 音效文件随 App 打包在 rawfile/ 根目录下，均为盒端规格 16700Hz / 16bit / 单声道。
 * 顺序即音效页展示顺序，按语种分组：音效 → 日语 → 英语 → 中文，组内按辨识度排。
 */
export interface BuiltinTone {
  /** 稳定标识，同时作为 rawfile 文件名（不含扩展名） */
  id: string;
  /** 中文显示名 */
  zh: string;
  /** 英文显示名 */
  en: string;
  /** 时长（毫秒），用于列表展示；实际以解码结果为准 */
  durationMs: number;
}

export class BuiltinToneCatalog {
  private static readonly TONES: BuiltinTone[] = [
    // ---- 日语 ----
    {
      id: 'faq',
      zh: 'FAQ!',
      en: 'FAQ!',
      durationMs: 1800
    },
    {
      id: 'demo',
      zh: 'demodemo',
      en: 'demodemo',
      durationMs: 620
    },
    {
      id: 'zako',
      zh: '杂鱼杂鱼',
      en: 'Zako zako',
      durationMs: 1540
    },
    // ---- 英语 ----
    {
      id: 'wow',
      zh: 'WOW！',
      en: 'WOW!',
      durationMs: 2500
    },
    {
      id: 'kobe',
      zh: '科比 man!',
      en: 'Kobe man!',
      durationMs: 1050
    },
    // ---- 中文 ----
    {
      id: 'woqu',
      zh: '我靠',
      en: 'Whoa',
      durationMs: 980
    },
    {
      id: 'taishuai',
      zh: '我去太帅了',
      en: 'So handsome',
      durationMs: 2300
    },
    {
      id: 'xiexie',
      zh: '谢谢',
      en: 'Thanks',
      durationMs: 1180
    },
    {
      id: 'bendan',
      zh: '笨蛋',
      en: 'Dummy',
      durationMs: 1420
    }
  ];

  static all(): BuiltinTone[] {
    return BuiltinToneCatalog.TONES;
  }

  static label(tone: BuiltinTone, english: boolean): string {
    return english ? (tone.en.length > 0 ? tone.en : tone.zh) : tone.zh;
  }
}
