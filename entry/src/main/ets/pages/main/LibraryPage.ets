import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { ToneCatalog, ToneOption } from '../../common/constants/ToneCatalog';
import { DateUtils } from '../../common/utils/DateUtils';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { NearLinkAlert } from '../../common/utils/NearLinkAlert';
import { WriteConfirm } from '../../common/utils/WriteConfirm';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { PillButton, PillTone } from '../../components/PillButton';
import { GlassCard } from '../../components/GlassCard';
import { ToneCard } from '../../components/ToneCard';
import { ToneEntry } from '../../models/ToneModel';
import { AudioPlayService } from '../../services/AudioPlayService';
import { BluetoothService } from '../../services/BluetoothService';
import { CaseWriteService, WriteCheck, WriteCode, WriteResult } from '../../services/CaseWriteService';
import { SettingsService } from '../../services/SettingsService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';
import { WriteTask } from '../../services/write/WriteTask';

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
  @State editingId: string = '';
  @State editingName: string = '';
  @State sortMode: string = 'time';
  /** 本机记录的「盒内当前音效」 */
  @State lastWrittenId: string = '';
  /** 批量删除：选择模式与已勾选 id */
  @State selecting: boolean = false;
  @State selectedIds: string[] = [];
  /** 写入弹窗在显示：期间禁用会改动盒内状态或音效库的按钮 */
  @State taskActive: boolean = false;
  @StorageProp('writeEpoch') @Watch('onTaskChange') writeEpoch: number = 0;
  @State builtinLabel: string = '';
  private changeHandler: SimpleHandler | undefined = undefined;

  aboutToAppear(): void {
    // 同意前音效库还没初始化，list() 返回空，渲染的是空态；放行时再刷一次真实数据
    this.reload();
    this.changeHandler = (): void => {
      this.reload();
    };
    EventBus.on(AppEvent.TONE_CHANGED, this.changeHandler);
    EventBus.on(AppEvent.PRIVACY_CLEARED, this.changeHandler);
  }


  onTaskChange(changed: string): void {
    this.taskActive = WriteTask.isActive();
  }

  aboutToDisappear(): void {
    if (this.changeHandler !== undefined) {
      EventBus.off(AppEvent.TONE_CHANGED, this.changeHandler);
      EventBus.off(AppEvent.PRIVACY_CLEARED, this.changeHandler);
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

  /** 写入充电盒：先检查耳机状态，确认后交给写入弹窗 */
  private async writeToCase(entry: ToneEntry): Promise<void> {
    if (WriteTask.isActive()) {
      this.toast(I18n.t('wp.busy'));
      return;
    }
    // 先刷新一次：配对列表与音频连接状态决定写入目标设备
    await BluetoothService.refresh();
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      if (check.code === WriteCode.NEARLINK_UNSUPPORTED) {
        NearLinkAlert.show(this.getUIContext(), check.message);
      } else {
        this.toast(check.message);
      }
      return;
    }
    WriteConfirm.tone(this.getUIContext(), entry.name, check.warn, (): void => {
      Logger.info(MODULE, `开始写入「${entry.name}」`);
      WriteTask.writeTone(entry);
    });
  }

  /** 恢复默认开盒音：先刷新设备状态，再给出可执行的确认信息 */
  private async confirmRestore(): Promise<void> {
    if (WriteTask.isActive()) {
      this.toast(I18n.t('wp.busy'));
      return;
    }
    await BluetoothService.refresh();
    const check: WriteCheck = CaseWriteService.checkRestore();
    if (!check.ok) {
      Logger.warn(MODULE, `恢复默认前置检查未通过 code=${check.code}：${check.message}`);
      if (check.code === WriteCode.NEARLINK_UNSUPPORTED) {
        NearLinkAlert.show(this.getUIContext(), check.message);
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
          Logger.info(MODULE, '开始恢复默认开盒音');
          WriteTask.restoreDefault();
        }
      }
    });
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
    if (CaseWriteService.isBusy() || this.taskActive) {
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
    if (CaseWriteService.isBusy() || this.taskActive) {
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
      if (!this.isSelected(entry.id) ||
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

  /**
   * 通过系统分享面板发给微信 / QQ：先把裸 PCM 包成 WAV，否则对方打不开。
   *
   * 入口暂时隐藏（ToneCard 的分享按钮已移除），实现保留以便随时恢复：
   * 把 ToneCard 的 `onShare` 属性与 ActionChip、以及这里的 `onShare:` 传参加回来即可。
   */
  private async shareTone(entry: ToneEntry): Promise<void> {
    try {
      const uri: string = await ToneRepositoryService.prepareShareFile(entry);
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.AUDIO,
        uri: uri,
        title: entry.name
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (error) {
      Logger.exception(MODULE, '分享失败', error as BusinessError);
      this.toast(I18n.t('lib.shareFailed'));
    }
  }

  private confirmDelete(entry: ToneEntry): void {
    // 正在写入的音效不能删：文件被删会让传输中的校验与收尾失去依据
    if (CaseWriteService.isToneWriting(entry.id)) {
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
        ghostLabel: I18n.t('lib.restoreDefault'),
        ghostEnabled: !this.taskActive,
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
            .value(this.builtinLabel)
            .font({ size: 11 })
            .optionFont({ size: 12 })
            .selectedOptionFont({ size: 12 })
            .enabled(!this.taskActive)
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

  /** 切换内置音效：不写闪存，只发一条选中命令；过程和结局显示在写入弹窗里 */
  private async pickBuiltIn(index: number): Promise<void> {
    const catalog: ToneOption[] = this.builtinCatalog();
    if (index < 0 || index >= catalog.length || WriteTask.isActive()) {
      return;
    }
    const option: ToneOption = catalog[index];
    const label: string = ToneCatalog.label(option);
    Logger.info(MODULE, `切换内置音效 id=${option.id}`);
    const result: WriteResult = await WriteTask.selectBuiltIn(option.id, label);
    if (result.ok) {
      this.builtinLabel = label;
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
      PillButton({
        pillText: I18n.t('lib.select'),
        pillTone: PillTone.ACCENT,
        pillEnabled: !this.taskActive,
        onTap: (): void => {
          this.enterSelecting();
        }
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
      PillButton({
        pillText: this.visibleAllSelected() ? I18n.t('lib.unselectAll') : I18n.t('lib.selectAll'),
        pillTone: PillTone.NEUTRAL,
        onTap: (): void => {
          this.toggleSelectAll();
        }
      })
      PillButton({
        pillText: I18n.t('lib.deleteSelected'),
        pillTone: PillTone.DANGER,
        pillEnabled: this.selectedIds.length > 0,
        onTap: (): void => {
          this.confirmBatchDelete();
        }
      })
      PillButton({
        pillText: I18n.t('common.cancel'),
        pillTone: PillTone.NEUTRAL,
        onTap: (): void => {
          this.exitSelecting();
        }
      })
    }
    .width('100%')
    .margin({ top: -4 })
  }

  @Builder
  sortChip(label: string, key: string) {
    // 选项胶囊：选中实心，未选中淡白底 + 细边
    Text(label)
      .fontSize(12)
      .fontWeight(this.sortMode === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.sortMode === key ? Palette.ON_ACCENT : Palette.TEXT_SECONDARY)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.sortMode === key ? Palette.ACCENT : Palette.CHIP_IDLE)
      .border({ width: 1, color: this.sortMode === key ? Palette.ACCENT : Palette.CHIP_IDLE_STROKE })
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
              deleteLocked: this.taskActive && CaseWriteService.isToneWriting(entry.id),
              expanded: !this.selecting && this.expandedId === entry.id,
              playing: this.playingId === entry.id,
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
                  .fontColor(Palette.ON_ACCENT)
                  .fontWeight(FontWeight.Medium)
                  .height(40)
                  .padding({ left: 16, right: 16 })
                  .textAlign(TextAlign.Center)
                  .borderRadius(20)
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
