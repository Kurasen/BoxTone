import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { ToneCatalog, ToneOption } from '../../common/constants/ToneCatalog';
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
import { SettingsService } from '../../services/SettingsService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'LibraryPage';

/** 整页滚动的底部留白：与悬浮底栏等高，最后一张卡片能完整滚到底栏上方 */
const SCROLL_BOTTOM_INSET: number = Metric.CONTENT_BOTTOM_INSET;

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
  /** 本机记录的「盒内当前音效」 */
  @State lastWrittenId: string = '';
  /** 批量删除：选择模式与已勾选 id */
  @State selecting: boolean = false;
  @State selectedIds: string[] = [];
  @State restoring: boolean = false;
  @State builtinBusy: boolean = false;
  @State builtinLabel: string = '';
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
    this.lastWrittenId = SettingsService.getLastWrittenTone();
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
      const context: common.UIAbilityContext = this.abilityContext();
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowKeepScreenOn(on);
    } catch (error) {
      Logger.warn(MODULE, `设置屏幕常亮失败 on=${on} code=${(error as BusinessError).code}`);
    }
  }

  private abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async runWrite(entry: ToneEntry): Promise<void> {
    this.writingId = entry.id;
    this.writeStage = I18n.t('lib.stageConnect');
    this.writeRatio = 0;
    Logger.info(MODULE, `开始写入「entry.name}」`);
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
        Logger.info(MODULE, `写入成功「entry.name}」`);
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
        Logger.warn(MODULE, `写入未完 code=${result.code}${result.message}`);
        this.showWriteFailure(result);
      }
    } catch (error) {
      Logger.exception(MODULE, '写入异常', error as BusinessError);
      this.toast(I18n.t('lib.writeFailed'));
    } finally {
      this.writingId = '';
      this.writeStage = '';
      this.writeRatio = 0;
      this.lastWrittenId = SettingsService.getLastWrittenTone();
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
        Logger.warn(MODULE, `恢复默认开盒音未完 code=${result.code}${result.message}`);
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
      this.lastWrittenId = SettingsService.getLastWrittenTone();
      EventBus.emitText(AppEvent.BUSY_CHANGED, '');
      await this.setKeepScreenOn(false);
      BluetoothService.refresh().then(() => {
      }).catch((error: BusinessError) => {
        Logger.warn(MODULE, `刷新蓝牙状态失败 code=${error.code}`);
      });
    }
  }

  /** 列表展示用：按时间/名称排序 */
  private sortedItems(): ToneEntry[] {
    const copy: ToneEntry[] = this.items.slice();
    if (this.sortMode === 'name') {
      copy.sort((a: ToneEntry, b: ToneEntry): number => a.name.localeCompare(b.name));
    } else {
      copy.sort((a: ToneEntry, b: ToneEntry): number => b.createdAt - a.createdAt);
    }
    return copy;
  }

  // ---------------- 批量删除 ----------------

  /** 进入批量选择：写入/恢复期间不允许，避免把正在使用的文件删掉 */
  private enterSelecting(): void {
    if (CaseWriteService.isBusy() || this.writingId.length > 0) {
      this.toast(I18n.t('lib.selectBusy'));
      return;
    }
    this.selecting = true;
    this.selectedIds = [];
    this.expandedId = '';
    this.editingId = '';
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private toggleSelected(id: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.selectedIds.length; i++) {
      if (this.selectedIds[i] === id) {
        found = true;
      } else {
        next.push(this.selectedIds[i]);
      }
    }
    if (!found) {
      next.push(id);
    }
    this.selectedIds = next;
  }

  /** 当前过滤结果是否已全选 */
  private visibleAllSelected(): boolean {
    const visible: ToneEntry[] = this.sortedItems();
    if (visible.length === 0) {
      return false;
    }
    for (let i = 0; i < visible.length; i++) {
      if (!this.isSelected(visible[i].id)) {
        return false;
      }
    }
    return true;
  }

  private toggleSelectAll(): void {
    if (this.visibleAllSelected()) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    const visible: ToneEntry[] = this.sortedItems();
    for (let i = 0; i < visible.length; i++) {
      ids.push(visible[i].id);
    }
    this.selectedIds = ids;
  }

  private confirmBatchDelete(): void {
    if (this.selectedIds.length === 0) {
      this.toast(I18n.t('lib.selectNoneHint'));
      return;
    }
    if (CaseWriteService.isBusy() || this.writingId.length > 0) {
      this.toast(I18n.t('lib.selectBusy'));
      return;
    }
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.deleteBatchTitle'),
      message: I18n.f('lib.deleteBatchMessage', [`${this.selectedIds.length}`]),
      primaryButton: {
        value: I18n.t('common.cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: I18n.t('lib.delete'),
        fontColor: Palette.DANGER,
        action: (): void => {
          this.runBatchDelete();
        }
      }
    });
  }

  private runBatchDelete(): void {
    let removed: number = 0;
    let markerCleared: boolean = false;
    for (let i = 0; i < this.items.length; i++) {
      const entry: ToneEntry = this.items[i];
      if (!this.isSelected(entry.id) || this.writingId === entry.id ||
        CaseWriteService.isToneWriting(entry.id)) {
        continue;
      }
      if (this.playingId === entry.id) {
        AudioPlayService.stop();
        this.playingId = '';
      }
      ToneRepositoryService.remove(entry);
      if (this.lastWrittenId === entry.id) {
        markerCleared = true;
      }
      removed++;
    }
    if (markerCleared) {
      SettingsService.setLastWrittenTone('');
    }
    this.selecting = false;
    this.selectedIds = [];
    this.reload();
    this.toast(I18n.f('lib.deleteBatchDone', [`${removed}`]));
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
    const isLink: boolean = result.reason === WriteReason.LINK;
    this.getUIContext().showAlertDialog({
      title: I18n.t('lib.writeIncomplete'),
      message: `${result.message}\n\n${I18n.f('lib.errorCode', [`${result.code}`])}`,
      primaryButton: {
        value: isLink ? I18n.t('device.openSettings') : I18n.t('common.ok'),
        action: (): void => {
          if (isLink) {
            this.openBluetoothSettings();
          }
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

  private openBluetoothSettings(): void {
    BluetoothService.openSystemBluetoothSettings().catch((error: BusinessError) => {
      Logger.warn(MODULE, `打开系统蓝牙设置失败 code=${error.code}`);
      this.toast(I18n.t('device.openSettingsFailed'));
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
    // 正在写入的音效不能删：文件被删会让传输中的校验与收尾失去依据
    if (this.writingId === entry.id || CaseWriteService.isToneWriting(entry.id)) {
      this.toast(I18n.t('lib.deleteLockedWriting'));
      return;
    }
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
          // 删掉的正好是盒内音效：标记同步清空，卡片不再显示已不存在的名字
          if (this.lastWrittenId === entry.id) {
            SettingsService.setLastWrittenTone('');
          }
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
    // 整页一起滚：数据量不大，不用 List 做局部滚动
    Scroll() {
      Column({ space: 12 }) {
        this.buildHeader()
        this.buildSummary()
        this.buildRestoreAction()
        if (this.items.length > 0) {
          if (this.selecting) {
            this.buildSelectBar()
          } else {
            this.buildSortBar()
          }
        }
        this.buildItems()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Metric.PAGE_PADDING,
        right: Metric.PAGE_PADDING,
        top: 8,
        bottom: SCROLL_BOTTOM_INSET
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
    Column({ space: 8 }) {
      GhostButton({
        ghostLabel: this.restoring ? I18n.t('lib.restoring') : I18n.t('lib.restoreDefault'),
        ghostEnabled: !this.restoring && !this.builtinBusy && this.writingId.length === 0,
        onTap: (): void => {
          this.confirmRestore();
        }
      })
      // 内置音效只在收录过音效表的机型上出现，没有表就不给对不上的名字
      if (this.builtinOptions().length > 0) {
        Row({ space: 8 }) {
          Text(I18n.t('lib.builtinPick'))
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
          Select(this.builtinOptions())
            .selected(-1)
            .value(this.builtinBusy ? I18n.t('lib.builtinBusy') : this.builtinLabel)
            .font({ size: 11 })
            .optionFont({ size: 12 })
            .selectedOptionFont({ size: 12 })
            .enabled(!this.restoring && !this.builtinBusy && this.writingId.length === 0)
            .layoutWeight(1)
            .onSelect((index: number): void => {
              this.pickBuiltIn(index);
            })
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      }
    }
    .width('100%')
  }

  /** 当前机型可切换的内置音效；未收录型号返回空 */
  private builtinCatalog(): ToneOption[] {
    return ToneCatalog.options(BluetoothService.deviceModelOf(BluetoothService.activeAudioId()));
  }

  private builtinOptions(): SelectOption[] {
    const catalog: ToneOption[] = this.builtinCatalog();
    const options: SelectOption[] = [];
    for (let i = 0; i < catalog.length; i++) {
      options.push({ value: ToneCatalog.label(catalog[i]) });
    }
    return options;
  }

  /** 切换内置音效：不写闪存，只发一条选中命令 */
  private async pickBuiltIn(index: number): Promise<void> {
    const catalog: ToneOption[] = this.builtinCatalog();
    if (index < 0 || index >= catalog.length) {
      return;
    }
    if (this.builtinBusy || this.restoring || this.writingId.length > 0) {
      return;
    }
    const option: ToneOption = catalog[index];
    const label: string = ToneCatalog.label(option);
    this.builtinBusy = true;
    EventBus.emitText(AppEvent.BUSY_CHANGED, I18n.t('lib.builtinBusy'));
    Logger.info(MODULE, `切换内置音效 id=${option.id}`);
    try {
      const result: WriteResult = await CaseWriteService.selectBuiltIn(option.id, label);
      if (result.ok) {
        this.builtinLabel = label;
      }
      this.toast(result.message);
    } catch (error) {
      Logger.exception(MODULE, '切换内置音效异常', error as BusinessError);
      this.toast(I18n.t('write.builtinFailed'));
    } finally {
      this.builtinBusy = false;
      this.lastWrittenId = SettingsService.getLastWrittenTone();
      EventBus.emitText(AppEvent.BUSY_CHANGED, '');
    }
  }

  @Builder
  buildSortBar() {
    Row({ space: 8 }) {
      Text(I18n.f('lib.totalCount', [`${this.sortedItems().length}`]))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
      Blank()
      this.sortChip(I18n.t('lib.sortTime'), 'time')
      this.sortChip(I18n.t('lib.sortName'), 'name')
      Text(I18n.t('lib.select'))
        .fontSize(11)
        .fontColor(this.writingId.length > 0 || this.restoring ? Palette.TEXT_TERTIARY : Palette.ACCENT_TEXT)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(999)
        .backgroundColor(Palette.ACCENT_SOFT)
        .opacity(this.writingId.length > 0 || this.restoring ? 0.5 : 1)
        .onClick(() => {
          this.enterSelecting();
        })
    }
    .width('100%')
    .margin({ top: -4 })
  }

  /** 批量选择工具条：替换排序条，写入期间不会出现在这里 */
  @Builder
  buildSelectBar() {
    Row({ space: 8 }) {
      Text(I18n.f('lib.selectedCount', [`${this.selectedIds.length}`]))
        .fontSize(10)
        .fontColor(Palette.TEXT_TERTIARY)
        .layoutWeight(1)
      Text(this.visibleAllSelected() ? I18n.t('lib.unselectAll') : I18n.t('lib.selectAll'))
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(999)
        .backgroundColor(Palette.FILL_FAINT)
        .onClick(() => {
          this.toggleSelectAll();
        })
      Text(I18n.t('lib.deleteSelected'))
        .fontSize(11)
        .fontColor(this.selectedIds.length > 0 ? Palette.DANGER : Palette.TEXT_TERTIARY)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(999)
        .backgroundColor(Palette.FILL_FAINT)
        .opacity(this.selectedIds.length > 0 ? 1 : 0.5)
        .onClick(() => {
          this.confirmBatchDelete();
        })
      Text(I18n.t('common.cancel'))
        .fontSize(11)
        .fontColor(Palette.TEXT_SECONDARY)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(999)
        .backgroundColor(Palette.BG_INPUT)
        .onClick(() => {
          this.exitSelecting();
        })
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
  buildItems() {
    if (this.items.length === 0) {
      Column() {
        GlassCard({ cardPadding: 6 }) {
          EmptyView({
            emptyIcon: $r('app.media.ic_tab_library'),
            emptyTitle: I18n.t('lib.empty'),
            emptyDesc: I18n.t('lib.emptyDesc')
          })
        }
      }
      .width('100%')
      .padding({ top: 40 })
    } else {
      Column({ space: 10 }) {
        ForEach(this.sortedItems(), (entry: ToneEntry) => {
          Column({ space: 8 }) {
            ToneCard({
              entry: entry,
              inCase: this.lastWrittenId === entry.id,
              selecting: this.selecting,
              selected: this.isSelected(entry.id),
              deleteLocked: this.writingId === entry.id || CaseWriteService.isToneWriting(entry.id),
              expanded: !this.selecting && this.expandedId === entry.id,
              playing: this.playingId === entry.id,
              writing: this.writingId === entry.id,
              writingText: this.writingId === entry.id && this.writeRatio > 0
                ? I18n.f('lib.writeProgress', [`${this.writeRatio}`]) : I18n.t('lib.writing'),
              writeLocked: this.restoring ||
                (this.writingId.length > 0 && this.writingId !== entry.id),
              onToggle: (): void => {
                if (this.selecting) {
                  this.toggleSelected(entry.id);
                  return;
                }
                this.expandedId = this.expandedId === entry.id ? '' : entry.id;
                if (this.expandedId !== entry.id) {
                  this.editingId = '';
                }
              },
              onSelect: (): void => {
                this.toggleSelected(entry.id);
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
                    .fontColor(Palette.ACCENT_TEXT)
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
        }, (entry: ToneEntry) => `${entry.id}-${this.lastWrittenId === entry.id ? 1 : 0}`)
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
