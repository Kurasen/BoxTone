export class DateUtils {
  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** HH:mm:ss */
  public static timeOfDay(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return `${DateUtils.pad(d.getHours())}:${DateUtils.pad(d.getMinutes())}:${DateUtils.pad(d.getSeconds())}`;
  }

  /** HH:mm:ss.SSS，导出日志用 */
  public static timeWithMillis(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return `${DateUtils.timeOfDay(timestamp)}.${DateUtils.pad3(d.getMilliseconds())}`;
  }

  /** yyyy-MM-dd HH:mm */
  public static dateTime(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return `${d.getFullYear()}-${DateUtils.pad(d.getMonth() + 1)}-${DateUtils.pad(d.getDate())} ` +
      `${DateUtils.pad(d.getHours())}:${DateUtils.pad(d.getMinutes())}`;
  }

  /** yyyyMMdd-HHmmss，文件名用 */
  public static fileStamp(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return `${d.getFullYear()}${DateUtils.pad(d.getMonth() + 1)}${DateUtils.pad(d.getDate())}-` +
      `${DateUtils.pad(d.getHours())}${DateUtils.pad(d.getMinutes())}${DateUtils.pad(d.getSeconds())}`;
  }

  private static pad3(value: number): string {
    if (value < 10) {
      return `00${value}`;
    }
    if (value < 100) {
      return `0${value}`;
    }
    return `${value}`;
  }
}
