import { LogLevel } from '../../common/constants/AppConstants';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DateUtils } from '../../common/utils/DateUtils';
import { EmptyView } from '../../components/EmptyView';
import { LogEntry, LOG_FILTERS, LogFilterOption, LogLevelStyle } from '../../models/LogModel';
import { LogChangeListener, LogService } from '../../services/LogService';

const MODULE: string = 'LogPage';

/**
 * 日志中心（全屏浮层）
 * 直接嵌入主界面的 Stack，避免使用已废弃的 router 跳转
 */
@Component
export struct LogPage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  onClose: () => void = () => {
  };
  topInset: number = 0;
  @State entries: LogEntry[] = [];
  @State filterKey: string = 'all';
  private listener: LogChangeListener | undefined = undefined;

  aboutToAppear(): void {
    const service: LogService = LogService.getInstance();
    this.entries = service.getEntries();
    const handler: LogChangeListener = (next: LogEntry[]): void => {
      this.entries = next;
    };
    this.listener = handler;
    service.onChange(handler);
  }

  aboutToDisappear(): void {
    if (this.listener !== undefined) {
      LogService.getInstance().offChange(this.listener);
      this.listener = undefined;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private filtered(): LogEntry[] {
    const option: LogFilterOption = this.currentOption();
    if (option.levels.length === 0) {
      return this.entries;
    }
    const result: LogEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const entry: LogEntry = this.entries[i];
      if (option.levels.indexOf(entry.level) >= 0) {
        result.push(entry);
      }
    }
    return result;
  }

  private currentOption(): LogFilterOption {
    for (let i = 0; i < LOG_FILTERS.length; i++) {
      if (LOG_FILTERS[i].key === this.filterKey) {
        return LOG_FILTERS[i];
      }
    }
    return LOG_FILTERS[0];
  }

  private async exportLog(): Promise<void> {
    try {
      const fileName: string = await LogService.getInstance().exportToFile();
      if (fileName.length > 0) {
        this.toast(I18n.f('log.exported', [fileName]));
      }
    } catch (error) {
      this.toast(I18n.t('log.exportFailed'));
    }
  }

  private async copyLog(): Promise<void> {
    try {
      await LogService.getInstance().copyToClipboard();
      this.toast(I18n.t('log.copied'));
    } catch (error) {
      this.toast(I18n.t('common.copyFailed'));
    }
  }

  build() {
    Column() {
      this.buildTopBar()
      this.buildFilters()

      if (this.filtered().length === 0) {
        Column() {
          EmptyView({
            emptyIcon: $r('app.media.ic_log'),
            emptyTitle: I18n.t('log.empty'),
            emptyDesc: this.filterKey === 'all' ? I18n.t('log.emptyDescAll') : I18n.t('log.emptyDescFiltered')
          })
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 8 }) {
          ForEach(this.filtered(), (entry: LogEntry) => {
            ListItem() {
              this.buildEntry(entry)
            }
          }, (entry: LogEntry) => entry.id)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .padding({ left: Metric.PAGE_PADDING, right: Metric.PAGE_PADDING })
        .cachedCount(6)
      }

      this.buildBottomBar()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    .backgroundColor(Palette.BG_TOP)
    .linearGradient({
      angle: 170,
      colors: [[Palette.BG_TOP, 0.0], [Palette.BG_END, 1.0]]
    })
  }

  @Builder
  buildTopBar() {
    Row({ space: 12 }) {
      Image($r('app.media.ic_chevron_right'))
        .width(18)
        .height(18)
        .fillColor(Palette.TEXT_PRIMARY)
        .rotate({ angle: 180 })
        .onClick(() => {
          this.onClose();
        })

      Column({ space: 3 }) {
        Text(I18n.t('log.title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.f('log.summary',
          [`${this.entries.length}`, `${LogService.getInstance().countOf(LogLevel.ERROR)}`]))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Metric.PAGE_PADDING, right: Metric.PAGE_PADDING, top: 12, bottom: 14 })
  }

  @Builder
  buildFilters() {
    Row({ space: 8 }) {
      ForEach(LOG_FILTERS, (option: LogFilterOption) => {
        Text(I18n.t(option.labelKey))
          .fontSize(12)
          .fontColor(this.filterKey === option.key ? '#05080E' : Palette.TEXT_SECONDARY)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor(this.filterKey === option.key ? Palette.ACCENT : Palette.FILL_FAINT)
          .onClick(() => {
            this.filterKey = option.key;
          })
      }, (option: LogFilterOption) => option.key)
    }
    .width('100%')
    .padding({ left: Metric.PAGE_PADDING, right: Metric.PAGE_PADDING })
    .margin({ bottom: 12 })
  }

  @Builder
  buildEntry(entry: LogEntry) {
    Row({ space: 10 }) {
      Column()
        .width(3)
        .height(34)
        .borderRadius(2)
        .backgroundColor(LogLevelStyle.colorOf(entry.level))

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(DateUtils.timeOfDay(entry.timestamp))
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
          Text(entry.module)
            .fontSize(10)
            .fontColor(LogLevelStyle.colorOf(entry.level))
          Blank()
          Text(LogLevelStyle.labelOf(entry.level))
            .fontSize(9)
            .fontColor(LogLevelStyle.colorOf(entry.level))
        }
        .width('100%')

        Text(entry.message)
          .fontSize(12)
          .fontColor(Palette.TEXT_SECONDARY)
          .lineHeight(17)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .borderRadius(14)
    .backgroundColor(Palette.BG_CARD)
    .border({ width: 1, color: Palette.STROKE_SOFT })
  }

  @Builder
  buildBottomBar() {
    Row({ space: 10 }) {
      this.bottomButton(I18n.t('log.copy'), $r('app.media.ic_log'), (): void => {
        this.copyLog();
      })
      this.bottomButton(I18n.t('log.export'), $r('app.media.ic_upload'), (): void => {
        this.exportLog();
      })
      this.bottomButton(I18n.t('log.clear'), $r('app.media.ic_trash'), (): void => {
        LogService.getInstance().clear();
        this.entries = LogService.getInstance().getEntries();
        this.toast(I18n.t('log.cleared'));
      })
    }
    .width('100%')
    .padding({
      left: Metric.PAGE_PADDING,
      right: Metric.PAGE_PADDING,
      top: 12,
      bottom: 30
    })
  }

  @Builder
  bottomButton(buttonLabel: string, buttonIcon: Resource, handler: () => void) {
    Row({ space: 6 }) {
      Image(buttonIcon)
        .width(13)
        .height(13)
        .fillColor(Palette.TEXT_PRIMARY)
      Text(buttonLabel)
        .fontSize(12)
        .fontColor(Palette.TEXT_PRIMARY)
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(Palette.FILL_FAINT)
    .border({ width: 1, color: Palette.STROKE })
    .onClick(() => {
      handler();
    })
  }
}
