import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DateUtils } from '../../common/utils/DateUtils';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { NearLinkAlert } from '../../common/utils/NearLinkAlert';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { GlassCard } from '../../components/GlassCard';
import { ToneCard } from '../../components/ToneCard';
import { ToneEntry } from '../../models/ToneModel';
import { AudioPlayService } from '../../services/AudioPlayService';
import { BluetoothService } from '../../services/BluetoothService';
import { CaseWriteService, WriteCheck, WriteCode, WriteReason, WriteResult } from '../../services/CaseWriteService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'LibraryPage';

@Component
export struct LibraryPage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @State items: ToneEntry[] = [];
  @State totalBytes: number = 0;
  @State expandedId: string = '';
  @State playingId: string = '';
  @State writingId: string = '';
  @State writeStage: string = '';
  @State writeRatio: number = 0;
  @State editingId: string = '';
  @State editingName: string = '';
  @State sortMode: string = 'time';
  @State restoring: boolean = false;
  private changeHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
    this.changeHandler = (): void => {
      this.reload();
    };
    EventBus.on(AppEvent.TONE_CHANGED, this.changeHandler);
  }

  aboutToDisappear(): void {
    if (this.changeHandler !== undefined) {
      EventBus.off(AppEvent.TONE_CHANGED);
      this.changeHandler = undefined;
    }
    AudioPlayService.stop().then(() => {
    }).catch((error: BusinessError) => {
      Logger.exception(MODULE, '释放播放资源失败', error);
    });
  }

  private reload(): void {
    this.items = ToneRepositoryService.list();
    this.totalBytes = ToneRepositoryService.totalBytes();
    if (this.items.length === 0) {
      this.expandedId = '';
    }
    Logger.debug(MODULE, `音效库刷新，共 ${this.items.length} 条`);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private async togglePlay(entry: ToneEntry): Promise<void> {
    if (this.playingId === entry.id) {
      await AudioPlayService.stop();
      this.playingId = '';
      return;
    }
    try {
      const buffer: ArrayBuffer = ToneRepositoryService.readBuffer(entry);
      this.playingId = entry.id;
      await AudioPlayService.playRaw(buffer, (): void => {
        this.playingId = '';
      });
    } catch (error) {
      this.playingId = '';
      Logger.exception(MODULE, '试听失败', error as BusinessError);
      this.toast(I18n.t('tone.previewFailed'));
    }
  }

  /**
   * 写入耳机盒：先检查耳机状态，未连接时给出确认，再走 SPP 控制通道上传
   */
  private async writeToCase(entry: ToneEntry): Promise<void> {
    if (this.writingId.length > 0 || this.restoring) {
      this.toast(this.restoring ? I18n.t('lib.restoringDefault')
        : (this.writingId === entry.id ? I18n.t('lib.writingThis') : I18n.t('lib.writingOther')));
      return;
    }
    // 先刷新一次：配对列表与音频连接状态决定写入目标设备
    await BluetoothService.refresh();
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      if (check.code === WriteCode.NEARLINK_UNSUPPORTED) {
        this.showNearLinkBlocked(check.message);
      } else {
        this.toast(check.message);
      }
      return;
    }
    const baseHint: string = I18n.t('lib.writeHint');
    const hint: string = check.warn.length > 0 ? `${check.warn}\n${baseHint}` : baseHint;
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.writeTitle'),
      message: I18n.f('lib.writeMessage', [hint]),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.startWrite'),
        fontColor: Palette.ACCENT,
        action: (): void => {
          this.runWrite(entry);
        }
      }
    });
  }

  /** 擦写阶段可能持续几十秒，熄屏后应用被挂起会掐断串口 */
  private async setKeepScreenOn(on: boolean): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowKeepScreenOn(on);
    } catch (error) {
      Logger.warn(MODULE, `设置屏幕常亮失败 on=${on} code=${(error as BusinessError).code}`);
    }
  }

  private async runWrite(entry: ToneEntry): Promise<void> {
    this.writingId = entry.id;
    this.writeStage = I18n.t('lib.stageConnect');
    this.writeRatio = 0;
    Logger.info(MODULE, `开始写入「${entry.name}」`);
    await this.setKeepScreenOn(true);
    try {
      const result: WriteResult = await CaseWriteService.write(entry,
        (ratio: number, stage: string): void => {
          this.writeRatio = Math.round(ratio * 100);
          this.writeStage = stage;
        });
      if (result.ok) {
        // 补发选中成功时 upload 已经抛错，进度可能停在上一步，这里补到 100%
        this.writeRatio = 100;
        this.writeStage = I18n.t('lib.stageApplied');
        Logger.info(MODULE, `写入成功「${entry.name}」`);
        this.getUIContext().showAlertDialog({
          title: I18n.t('lib.writeDone'),
          message: I18n.f('lib.writeDoneMessage', [result.message]),
          confirm: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          }
        });
      } else {
        Logger.warn(MODULE, `写入未完成 code=${result.code}：${result.message}`);
        this.showWriteFailure(result);
      }
    } catch (error) {
      Logger.exception(MODULE, '写入异常', error as BusinessError);
      this.toast(I18n.t('lib.writeFailed'));
    } finally {
      this.writingId = '';
      this.writeStage = '';
      this.writeRatio = 0;
      await this.setKeepScreenOn(false);
      // 写入过程会断开音频通道，刷新一次让设备页的状态跟上
      BluetoothService.refresh().then(() => {
      }).catch((error: BusinessError) => {
        Logger.warn(MODULE, `刷新蓝牙状态失败 code=${error.code}`);
      });
    }
  }

  /** 恢复默认开盒音：先刷新设备状态，再给出可执行的确认信息 */
  private async confirmRestore(): Promise<void> {
    if (this.writingId.length > 0 || this.restoring) {
      this.toast(this.restoring ? I18n.t('lib.restoringDefault') : I18n.t('lib.writingNow'));
      return;
    }
    await BluetoothService.refresh();
    const check: WriteCheck = CaseWriteService.checkRestore();
    if (!check.ok) {
      Logger.warn(MODULE, `恢复默认前置检查未通过 code=${check.code}：${check.message}`);
      if (check.code === WriteCode.NEARLINK_UNSUPPORTED) {
        this.showNearLinkBlocked(check.message);
      } else {
        this.toast(check.message);
      }
      return;
    }
    const warn: string = check.warn.length > 0 ? `${check.warn}\n` : '';
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.restoreTitle'),
      message: I18n.f('lib.restoreMessage', [warn]),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.restoreAction'),
        fontColor: Palette.ACCENT,
        action: (): void => {
          this.runRestore();
        }
      }
    });
  }

  private async runRestore(): Promise<void> {
    this.restoring = true;
    EventBus.emitText(AppEvent.BUSY_CHANGED, I18n.t('lib.restoreBusy'));
    await this.setKeepScreenOn(true);
    Logger.info(MODULE, '开始恢复默认开盒音');
    try {
      const result: WriteResult = await CaseWriteService.restoreDefault();
      if (result.ok) {
        Logger.info(MODULE, '恢复默认开盒音成功');
        this.getUIContext().showAlertDialog({
          title: I18n.t('lib.restoreDone'),
          message: I18n.f('lib.restoreDoneMessage', [result.message]),
          confirm: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          }
        });
      } else {
        Logger.warn(MODULE, `恢复默认开盒音未完成 code=${result.code}：${result.message}`);
        this.getUIContext().showAlertDialog({
          title: I18n.t('lib.restoreIncomplete'),
          message: `${result.message}\n\n${I18n.f('lib.errorCode', [`${result.code}`])}`,
          primaryButton: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          },
          secondaryButton: {
            value: I18n.t('lib.viewLog'),
            fontColor: Palette.ACCENT,
            action: (): void => {
              EventBus.emit(AppEvent.OPEN_LOG, 1);
            }
          }
        });
      }
    } catch (error) {
      Logger.exception(MODULE, '恢复默认开盒音异常', error as BusinessError);
      this.toast(I18n.t('lib.restoreFailed'));
    } finally {
      this.restoring = false;
      EventBus.emitText(AppEvent.BUSY_CHANGED, '');
      await this.setKeepScreenOn(false);
      BluetoothService.refresh().then(() => {
      }).catch((error: BusinessError) => {
        Logger.warn(MODULE, `刷新蓝牙状态失败 code=${error.code}`);
      });
    }
  }

  /** 列表展示用：时间按新→旧，名称按中文排序 */
  private sortedItems(): ToneEntry[] {
    const copy: ToneEntry[] = this.items.slice();
    if (this.sortMode === 'name') {
      copy.sort((a: ToneEntry, b: ToneEntry): number => a.name.localeCompare(b.name));
    } else {
      copy.sort((a: ToneEntry, b: ToneEntry): number => b.createdAt - a.createdAt);
    }
    return copy;
  }

  /** 星闪连接下写入被前置拦截：给出明确的切换指引和跳转入口 */
  private showNearLinkBlocked(message: string): void {
    NearLinkAlert.show(this.getUIContext(), message);
  }

  private showWriteFailure(result: WriteResult): void {
    // 星闪链路失败：同样引导去系统设置切换连接方式
    if (result.reason === WriteReason.NEARLINK) {
      this.showNearLinkBlocked(result.message);
      return;
    }
    // 不支持 / 格式被拒：把现场一键带回给开发者；其它失败保留查看日志
    const needReport: boolean = result.reason === WriteReason.UNSUPPORTED ||
      result.reason === WriteReason.FORMAT;
    if (needReport) {
      const title: string = result.reason === WriteReason.UNSUPPORTED ?
        I18n.t('lib.unsupportedTitle') : I18n.t('lib.rejectedTitle');
      this.getUIContext().showAlertDialog({
        title: title,
        message: `${result.message}\n\n${I18n.f('lib.errorCode', [`${result.code}`])}`,
        primaryButton: {
          value: I18n.t('common.close'),
          action: (): void => {
          }
        },
        secondaryButton: {
          value: I18n.t('lib.copyDiagnostic'),
          fontColor: Palette.ACCENT,
          action: (): void => {
            this.copyDiagnostic(result.diagnostic);
          }
        }
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.writeIncomplete'),
      message: `${result.message}\n\n${I18n.f('lib.errorCode', [`${result.code}`])}`,
      primaryButton: {
        value: I18n.t('common.ok'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.viewLog'),
        fontColor: Palette.ACCENT,
        action: (): void => {
          EventBus.emit(AppEvent.OPEN_LOG, 1);
        }
      }
    });
  }

  private async copyDiagnostic(text: string): Promise<void> {
    if (text.length === 0) {
      this.toast(I18n.t('lib.noDiagnostic'));
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast(I18n.t('lib.diagnosticCopied'));
    } catch (error) {
      Logger.warn(MODULE, `复制诊断信息失败 code=${(error as BusinessError).code}`);
      this.toast(I18n.t('common.copyFailed'));
    }
  }

  private async exportTone(entry: ToneEntry): Promise<void> {
    try {
      const fileName: string = await ToneRepositoryService.exportTone(entry);
      if (fileName.length > 0) {
        this.toast(I18n.f('tone.exported', [fileName]));
      }
    } catch (error) {
      Logger.exception(MODULE, '导出失败', error as BusinessError);
      this.toast(I18n.t('tone.exportFailed'));
    }
  }

  private confirmDelete(entry: ToneEntry): void {
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.deleteTitle'),
      message: I18n.f('lib.deleteMessage', [entry.name]),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.delete'),
        fontColor: Palette.DANGER,
        action: (): void => {
          ToneRepositoryService.remove(entry);
          if (this.playingId === entry.id) {
            AudioPlayService.stop();
            this.playingId = '';
          }
          this.reload();
          this.toast(I18n.t('lib.deleted'));
        }
      }
    });
  }

  private commitRename(entry: ToneEntry): void {
    const trimmed: string = this.editingName.trim();
    if (trimmed.length === 0) {
      this.toast(I18n.t('lib.renameEmpty'));
      return;
    }
    ToneRepositoryService.rename(entry, trimmed);
    this.editingId = '';
    this.editingName = '';
    this.reload();
    this.toast(I18n.t('lib.renamed'));
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildSummary()
        this.buildRestoreAction()
        if (this.items.length > 0) {
          this.buildSortBar()
        }
        this.buildList()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Metric.PAGE_PADDING,
        right: Metric.PAGE_PADDING,
        top: 8,
        bottom: Metric.CONTENT_BOTTOM_INSET
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  buildHeader() {
    Column({ space: 6 }) {
      Text(I18n.t('lib.title'))
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text(I18n.t('lib.subtitle'))
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 4 })
  }

  @Builder
  buildSummary() {
    GlassCard({ cardPadding: 16 }) {
      Row() {
        SummaryCell({
          cellLabel: I18n.t('lib.count'),
          cellValue: `${this.items.length}`,
          cellUnit: I18n.t('lib.unit')
        })
        Divider()
          .vertical(true)
          .height(28)
          .color(Palette.FILL_SOFT)
        SummaryCell({
          cellLabel: I18n.t('lib.size'),
          cellValue: FormatUtils.bytes(this.totalBytes),
          cellUnit: ''
        })
        Divider()
          .vertical(true)
          .height(28)
          .color(Palette.FILL_SOFT)
        SummaryCell({ cellLabel: I18n.t('lib.last'), cellValue: this.lastCreated(), cellUnit: '' })
      }
      .width('100%')
    }
  }

  private lastCreated(): string {
    if (this.items.length === 0) {
      return '—';
    }
    return DateUtils.timeOfDay(this.items[0].createdAt);
  }

  @Builder
  buildRestoreAction() {
    GhostButton({
      ghostLabel: this.restoring ? I18n.t('lib.restoring') : I18n.t('lib.restoreDefault'),
      ghostEnabled: !this.restoring && this.writingId.length === 0,
      onTap: (): void => {
        this.confirmRestore();
      }
    })
  }

  @Builder
  buildSortBar() {
    Row({ space: 8 }) {
      Text(I18n.f('lib.totalCount', [`${this.items.length}`]))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
      Blank()
      this.sortChip(I18n.t('lib.sortTime'), 'time')
      this.sortChip(I18n.t('lib.sortName'), 'name')
    }
    .width('100%')
    .margin({ top: -4 })
  }

  @Builder
  sortChip(label: string, key: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.sortMode === key ? '#05080E' : Palette.TEXT_SECONDARY)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.sortMode === key ? Palette.ACCENT : Palette.FILL_FAINT)
      .onClick(() => {
        this.sortMode = key;
      })
  }

  @Builder
  buildList() {
    if (this.items.length === 0) {
      GlassCard({ cardPadding: 6 }) {
        EmptyView({
          emptyIcon: $r('app.media.ic_tab_library'),
          emptyTitle: I18n.t('lib.empty'),
          emptyDesc: I18n.t('lib.emptyDesc')
        })
      }
    } else {
      Column({ space: 10 }) {
        ForEach(this.sortedItems(), (entry: ToneEntry) => {
          Column({ space: 8 }) {
            ToneCard({
              entry: entry,
              expanded: this.expandedId === entry.id,
              playing: this.playingId === entry.id,
              writing: this.writingId === entry.id,
              writingText: this.writingId === entry.id && this.writeRatio > 0
                ? I18n.f('lib.writeProgress', [`${this.writeRatio}`]) : I18n.t('lib.writing'),
              writeLocked: this.restoring ||
                (this.writingId.length > 0 && this.writingId !== entry.id),
              onToggle: (): void => {
                this.expandedId = this.expandedId === entry.id ? '' : entry.id;
                if (this.expandedId !== entry.id) {
                  this.editingId = '';
                }
              },
              onPlay: (): void => {
                this.togglePlay(entry);
              },
              onWrite: (): void => {
                this.writeToCase(entry);
              },
              onExport: (): void => {
                this.exportTone(entry);
              },
              onRename: (): void => {
                this.editingId = entry.id;
                this.editingName = entry.name;
              },
              onDelete: (): void => {
                this.confirmDelete(entry);
              }
            })

            if (this.writingId === entry.id) {
              Column({ space: 6 }) {
                Row() {
                  Text(this.writeStage.length > 0 ? this.writeStage : I18n.t('lib.writingStage'))
                    .fontSize(11)
                    .fontColor(Palette.ACCENT)
                    .layoutWeight(1)
                  Text(`${this.writeRatio}%`)
                    .fontSize(11)
                    .fontColor(Palette.TEXT_TERTIARY)
                }
                .width('100%')

                Progress({ value: this.writeRatio, total: 100, type: ProgressType.Linear })
                  .width('100%')
                  .height(3)
                  .color(Palette.ACCENT)
                  .backgroundColor(Palette.FILL_SOFT)
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 2 })
            }

            if (this.editingId === entry.id) {
              Row({ space: 8 }) {
                TextInput({ text: this.editingName, placeholder: I18n.t('lib.renamePlaceholder') })
                  .layoutWeight(1)
                  .height(40)
                  .fontSize(13)
                  .fontColor(Palette.TEXT_PRIMARY)
                  .placeholderColor(Palette.TEXT_TERTIARY)
                  .backgroundColor(Palette.FILL_FAINT)
                  .borderRadius(11)
                  .onChange((value: string) => {
                    this.editingName = value;
                  })
                Text(I18n.t('common.save'))
                  .fontSize(12)
                  .fontColor('#05080E')
                  .height(40)
                  .padding({ left: 16, right: 16 })
                  .textAlign(TextAlign.Center)
                  .borderRadius(11)
                  .backgroundColor(Palette.ACCENT)
                  .onClick(() => {
                    this.commitRename(entry);
                  })
              }
              .width('100%')
              .padding({ left: 4, right: 4 })
            }
          }
          .width('100%')
        }, (entry: ToneEntry) => entry.id)
      }
      .width('100%')
    }
  }
}

/** 概览单元：数值变化需要刷新，@Builder 按值传参不会刷新，故独立成组件 */
@Component
struct SummaryCell {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop cellLabel: string = '';
  @Prop cellValue: string = '';
  @Prop cellUnit: string = '';

  build() {
    Column({ space: 5 }) {
      Row({ space: 2 }) {
        Text(this.cellValue)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        if (this.cellUnit.length > 0) {
          Text(this.cellUnit)
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
            .margin({ bottom: 2 })
        }
      }
      Text(this.cellLabel)
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}
