import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { I18n } from '../../common/i18n/I18n';
import { AppEvent, EventBus } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { PrimaryButton } from '../../components/PrimaryButton';
import { SectionTitle } from '../../components/SectionTitle';
import { BackupResult, ToneBackupService } from '../../services/ToneBackupService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'BackupPage';

/**
 * 备份与导入。
 *
 * 整库备份是自包含的 `.boxtone` 容器；恢复与 `.pcm` 导入都只做校验与入库，
 * 不会进行任何转码——文件本身必须已经是 16700Hz / 16bit / 单声道的原始波形。
 */
@Component
export struct BackupPage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  topInset: number = 0;
  onClose: () => void = () => {
  };
  @State count: number = 0;
  @State bytes: number = 0;
  @State busy: boolean = false;
  /** 上一次操作的结果，直接显示在页面上，避免只靠一闪而过的 toast */
  @State note: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    // 页面被销毁时别把全屏遮罩留在主界面上
    EventBus.emitText(AppEvent.BUSY_CHANGED, '');
    EventBus.resetBusy();
  }

  private refresh(): void {
    this.count = ToneRepositoryService.count();
    this.bytes = ToneRepositoryService.totalBytes();
  }

  private abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 操作期间复用全局遮罩：系统选择器会盖在它上面，返回后立刻恢复 */
  private setBusy(on: boolean, text: string): void {
    this.busy = on;
    EventBus.emitText(AppEvent.BUSY_CHANGED, on ? text : '');
    if (!on) {
      EventBus.resetBusy();
    }
  }

  private errorText(error: Object): string {
    const businessError: BusinessError = error as BusinessError;
    const message: string = businessError.message !== undefined ? businessError.message : '';
    return message.length > 0 ? message : I18n.t('backup.failed');
  }

  private async exportBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.note = '';
    this.setBusy(true, I18n.t('backup.busyExport'));
    try {
      const fileName: string = await ToneBackupService.exportAll(this.abilityContext());
      this.note = fileName.length > 0 ? I18n.f('backup.exported', [fileName]) : I18n.t('backup.cancelled');
    } catch (error) {
      Logger.exception(MODULE, '导出备份失败', error as BusinessError);
      this.note = this.errorText(error);
    } finally {
      this.setBusy(false, '');
    }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.note = '';
    this.setBusy(true, I18n.t('backup.busyImport'));
    try {
      const result: BackupResult = await ToneBackupService.importBackup(this.abilityContext());
      this.note = this.importResultText(result, false);
      this.afterImport(result);
    } catch (error) {
      Logger.exception(MODULE, '恢复备份失败', error as BusinessError);
      this.note = this.errorText(error);
    } finally {
      this.setBusy(false, '');
    }
  }

  private async importRaw(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.note = '';
    this.setBusy(true, I18n.t('backup.busyRaw'));
    try {
      const result: BackupResult = await ToneBackupService.importRawFiles(this.abilityContext());
      this.note = this.importResultText(result, true);
      this.afterImport(result);
    } catch (error) {
      Logger.exception(MODULE, '导入音效文件失败', error as BusinessError);
      this.note = this.errorText(error);
    } finally {
      this.setBusy(false, '');
    }
  }

  private importResultText(result: BackupResult, raw: boolean): string {
    if (result.added === 0 && result.failed === 0) {
      return I18n.t('backup.cancelled');
    }
    if (result.failed > 0) {
      return I18n.f('backup.importedPartly', [`${result.added}`, `${result.failed}`]);
    }
    if (result.added === 0) {
      return I18n.t('backup.nothing');
    }
    return I18n.f(raw ? 'backup.rawImported' : 'backup.imported', [`${result.added}`]);
  }

  private afterImport(result: BackupResult): void {
    this.refresh();
    if (result.added > 0) {
      EventBus.emit(AppEvent.TONE_CHANGED, 1);
    }
  }

  build() {
    Column() {
      this.buildTopBar()

      Scroll() {
        Column({ space: 16 }) {
          GlassCard({ cardPadding: 16 }) {
            Row() {
              BackupStat({ statLabel: I18n.t('backup.summaryCount'), statValue: `${this.count}` })
              Divider()
                .vertical(true)
                .height(28)
                .color(Palette.FILL_SOFT)
              BackupStat({ statLabel: I18n.t('backup.summarySize'), statValue: FormatUtils.bytes(this.bytes) })
            }
            .width('100%')
          }

          SectionTitle({ sectionText: I18n.t('backup.exportSection') })
          GlassCard({ cardPadding: 16 }) {
            Text(I18n.t('backup.exportDesc'))
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
              .margin({ bottom: 12 })
            PrimaryButton({
              btnLabel: I18n.t('backup.exportAction'),
              btnEnabled: this.count > 0 && !this.busy,
              btnLoading: this.busy,
              btnIcon: $r('app.media.ic_upload'),
              onTap: (): void => {
                this.exportBackup();
              }
            })
          }

          SectionTitle({ sectionText: I18n.t('backup.importSection') })
          GlassCard({ cardPadding: 16 }) {
            Text(I18n.t('backup.importDesc'))
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
              .margin({ bottom: 10 })
            GhostButton({
              ghostLabel: I18n.t('backup.importAction'),
              ghostEnabled: !this.busy,
              ghostIcon: $r('app.media.ic_add'),
              onTap: (): void => {
                this.restoreBackup();
              }
            })

            Text(I18n.t('backup.rawDesc'))
              .fontSize(11)
              .fontColor(Palette.TEXT_TERTIARY)
              .lineHeight(18)
              .width('100%')
              .margin({ top: 14, bottom: 10 })
            GhostButton({
              ghostLabel: I18n.t('backup.rawAction'),
              ghostEnabled: !this.busy,
              ghostIcon: $r('app.media.ic_upload'),
              onTap: (): void => {
                this.importRaw();
              }
            })
          }

          if (this.note.length > 0) {
            GlassCard({ cardPadding: 14 }) {
              Row({ space: 8 }) {
                // 用圆角方块代替 Circle().fill()：fill 属性要到 API 26 才可用，
                // 而本工程 compatibleSdkVersion 是 6.1.0(23)，低版本设备上这个点会渲染不出来
                Row()
                  .width(4)
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(Palette.ACCENT)
                Text(this.note)
                  .fontSize(11)
                  .fontColor(Palette.TEXT_PRIMARY)
                  .lineHeight(18)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          }

          GlassCard({ cardPadding: 16 }) {
            this.buildNote(I18n.t('backup.note1'))
            this.buildNote(I18n.t('backup.note2'))
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: Metric.PAGE_PADDING,
          right: Metric.PAGE_PADDING,
          top: 4,
          bottom: 28
        })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    // 背景由 Index 外层的 AppBackdrop 统一绘制
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
        Text(I18n.t('backup.title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.t('backup.subtitle'))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: Metric.PAGE_PADDING,
      right: Metric.PAGE_PADDING,
      top: 10,
      bottom: 14
    })
  }

  @Builder
  buildNote(text: string) {
    Row({ space: 8 }) {
      // 同上：避免 Circle().fill()（API 26）在 6.1.0(23) 设备上不渲染
      Row()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(Palette.ACCENT)
        .margin({ top: 7 })
      Text(text)
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .lineHeight(18)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }
}

/** 概览单元：@Builder 按值传参不会刷新，故独立成组件 */
@Component
struct BackupStat {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop statLabel: string = '';
  @Prop statValue: string = '';

  build() {
    Column({ space: 5 }) {
      Text(this.statValue)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(this.statLabel)
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}