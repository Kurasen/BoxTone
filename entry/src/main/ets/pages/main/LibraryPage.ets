import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DateUtils } from '../../common/utils/DateUtils';
import { AppEvent, EventBus, SimpleHandler } from '../../common/utils/EventBus';
import { FormatUtils } from '../../common/utils/FormatUtils';
import { Logger } from '../../common/utils/Logger';
import { EmptyView } from '../../components/EmptyView';
import { GlassCard } from '../../components/GlassCard';
import { ToneCard } from '../../components/ToneCard';
import { ToneEntry } from '../../models/ToneModel';
import { AudioPlayService } from '../../services/AudioPlayService';
import { BluetoothService } from '../../services/BluetoothService';
import { CaseWriteService, WriteCheck, WriteResult } from '../../services/CaseWriteService';
import { ToneRepositoryService } from '../../services/ToneRepositoryService';

const MODULE: string = 'LibraryPage';

@Component
export struct LibraryPage {
  @State items: ToneEntry[] = [];
  @State totalBytes: number = 0;
  @State expandedId: string = '';
  @State playingId: string = '';
  @State writingId: string = '';
  @State writeStage: string = '';
  @State writeRatio: number = 0;
  @State editingId: string = '';
  @State editingName: string = '';
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
      this.toast('试听失败');
    }
  }

  /**
   * 写入耳机盒：先检查耳机状态，未连接时给出确认，再走 SPP 控制通道上传
   */
  private async writeToCase(entry: ToneEntry): Promise<void> {
    if (this.writingId.length > 0) {
      this.toast(this.writingId === entry.id ? '正在写入这条音效，请稍候' : '正在写入其他音效，完成后再试');
      return;
    }
    // 先刷新一次：配对列表与音频连接状态决定写入目标设备
    await BluetoothService.refresh();
    const check: WriteCheck = CaseWriteService.check(entry);
    if (!check.ok) {
      Logger.warn(MODULE, `写入前置检查未通过 code=${check.code}：${check.message}`);
      this.toast(check.message);
      return;
    }
    const hint: string = check.warn.length > 0 ? check.warn :
      '写入会把数据直接下发到充电盒，过程中会临时断开耳机与手机的音频连接。';
    this.getUIContext().showAlertDialog({
      title: '准备写入充电盒',
      message: `${hint}\n\n请确认双耳已放入盒内并打开盒盖，然后继续。\n\n` +
        '其他机型不兼容时会被盒子拒绝，不会损坏设备。' +
        '写入期间请勿切走应用或关闭蓝牙。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '开始写入',
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
    this.writeStage = '连接耳机';
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
        this.writeStage = '已应用';
        Logger.info(MODULE, `写入成功「${entry.name}」`);
        this.getUIContext().showAlertDialog({
          title: '写入完成',
          message: `${result.message}\n\n如需恢复听歌，从充电盒取出耳机会自动重连。`,
          confirm: {
            value: '知道了',
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
      this.toast('写入失败，请查看日志');
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

  private showWriteFailure(result: WriteResult): void {
    this.getUIContext().showAlertDialog({
      title: '写入未完成',
      message: `${result.message}\n\n错误码 ${result.code}`,
      primaryButton: {
        value: '知道了',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '查看日志',
        fontColor: Palette.ACCENT,
        action: (): void => {
          EventBus.emit(AppEvent.OPEN_LOG, 1);
        }
      }
    });
  }

  private async exportTone(entry: ToneEntry): Promise<void> {
    try {
      const fileName: string = await ToneRepositoryService.exportTone(entry);
      if (fileName.length > 0) {
        this.toast(`已导出 ${fileName}`);
      }
    } catch (error) {
      Logger.exception(MODULE, '导出失败', error as BusinessError);
      this.toast('导出失败，请查看日志');
    }
  }

  private confirmDelete(entry: ToneEntry): void {
    this.getUIContext().showAlertDialog({
      title: '删除音效',
      message: `确定删除「${entry.name}」吗？该操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Palette.DANGER,
        action: (): void => {
          ToneRepositoryService.remove(entry);
          if (this.playingId === entry.id) {
            AudioPlayService.stop();
            this.playingId = '';
          }
          this.reload();
          this.toast('已删除');
        }
      }
    });
  }

  private commitRename(entry: ToneEntry): void {
    const trimmed: string = this.editingName.trim();
    if (trimmed.length === 0) {
      this.toast('名称不能为空');
      return;
    }
    ToneRepositoryService.rename(entry, trimmed);
    this.editingId = '';
    this.editingName = '';
    this.reload();
    this.toast('已重命名');
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.buildHeader()
        this.buildSummary()
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
      Text('音效库')
        .fontSize(Metric.TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT_PRIMARY)
      Text('已生成的音效都会保存在本机，可随时导出')
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
        SummaryCell({ cellLabel: '音效数量', cellValue: `${this.items.length}`, cellUnit: '个' })
        Divider()
          .vertical(true)
          .height(28)
          .color('rgba(255, 255, 255, 0.07)')
        SummaryCell({
          cellLabel: '占用空间',
          cellValue: FormatUtils.bytes(this.totalBytes),
          cellUnit: ''
        })
        Divider()
          .vertical(true)
          .height(28)
          .color('rgba(255, 255, 255, 0.07)')
        SummaryCell({ cellLabel: '最近生成', cellValue: this.lastCreated(), cellUnit: '' })
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
  buildList() {
    if (this.items.length === 0) {
      GlassCard({ cardPadding: 6 }) {
        EmptyView({
          emptyIcon: $r('app.media.ic_tab_library'),
          emptyTitle: '还没有音效',
          emptyDesc: '去「音效」页导入素材或选择内置音色，生成后会出现在这里'
        })
      }
    } else {
      Column({ space: 10 }) {
        ForEach(this.items, (entry: ToneEntry) => {
          Column({ space: 8 }) {
            ToneCard({
              entry: entry,
              expanded: this.expandedId === entry.id,
              playing: this.playingId === entry.id,
              writing: this.writingId === entry.id,
              writingText: this.writingId === entry.id && this.writeRatio > 0
                ? `写入 ${this.writeRatio}%` : '写入中…',
              writeLocked: this.writingId.length > 0 && this.writingId !== entry.id,
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
                  Text(this.writeStage.length > 0 ? this.writeStage : '正在写入')
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
                  .backgroundColor('rgba(255, 255, 255, 0.08)')
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 2 })
            }

            if (this.editingId === entry.id) {
              Row({ space: 8 }) {
                TextInput({ text: this.editingName, placeholder: '输入新名称' })
                  .layoutWeight(1)
                  .height(40)
                  .fontSize(13)
                  .fontColor(Palette.TEXT_PRIMARY)
                  .placeholderColor(Palette.TEXT_TERTIARY)
                  .backgroundColor('rgba(255, 255, 255, 0.05)')
                  .borderRadius(11)
                  .onChange((value: string) => {
                    this.editingName = value;
                  })
                Text('保存')
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
