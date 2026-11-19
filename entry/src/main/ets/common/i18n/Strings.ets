/**
 * 界面文案字典
 *
 * 只收录用户可见文案；日志、诊断原始记录保持中文，方便开发者排查。
 * 占位符使用 {0} {1}，由 I18n.f 替换。
 */
import { ZH_STRINGS as ZH } from './StringsZh'; import { EN_STRINGS as EN } from './StringsEn';  /** 对外仍从 ./Strings 导出，调用方不需要改 import 路径 */ export const ZH_STRINGS: Record<string, string> = ZH; export const EN_STRINGS: Record<string, string> = EN; 
