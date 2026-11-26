import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';
import { AppRestart } from '../common/utils/AppRestart';
import { Logger } from '../common/utils/Logger';
import { BluetoothService } from '../services/BluetoothService';
import { WriteReason } from '../services/CaseWriteService';
import { RatingService } from '../services/RatingService';
import { ThemeService } from '../services/ThemeService';
import { TaskKind, TaskPhase, TaskSnapshot, WriteTask } from '../services/write/WriteTask';
import { WriteStep } from '../services/write/WriteTypes';

const MODULE: string = 'WritePanel';

/**
 * 写入弹窗：写音效 / 恢复默认 / 切换内置音效共用，全程只有这一个窗口（参考 feat/write-flow-v2）。
 *
 * - 居中模态：进度、步骤、结局都在这一个窗口里，遮罩吃掉所有点击，写入期间切不了页签、点不到页面；
 * - 结局不自动收起（取消除外），用户点「完成」「关闭」才消失；
 * - 状态只来自 WriteTask.snapshot()，通过 @StorageProp('writeEpoch') 触发刷新（键名见 WriteTask.WRITE_EPOCH）。
 *
 * 不用 CustomDialogController：它挂在页面上，切页签或页面未挂载时 open 会静默失败，
 * 而写入任务的生命周期跨页面。这里挂在 Index 的 Stack 上层，由状态驱动显示。
 */
@Component
export struct WritePanel {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @StorageProp('writeEpoch') @Watch('onTaskChange') writeEpoch: number = 0;
  @State snap: TaskSnapshot = WriteTask.snapshot();

  aboutToAppear(): void {
    this.snap = WriteTask.snapshot();
  }

  onTaskChange(changed: string): void {
    this.snap = WriteTask.snapshot();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  // ---------------------------------------------------------------- 文案

  private running(): boolean {
    return this.snap.phase !== TaskPhase.IDLE && !TaskPhase.isTerminal(this.snap.phase);
  }

  private headline(): string {
    const phase: string = this.snap.phase;
    if (phase === TaskPhase.DONE) {
      return this.snap.kind === TaskKind.TONE ? I18n.t('wp.phase.done') : I18n.t('wp.phase.applied');
    }
    if (phase === TaskPhase.FAILED) {
      return I18n.t('wp.phase.failed');
    }
    if (phase === TaskPhase.CANCELLED) {
      return I18n.t('wp.phase.cancelled');
    }
    // 恢复默认 / 切内置音效没有传输阶段，只有一句
    if (this.snap.kind !== TaskKind.TONE) {
      return I18n.t('wp.phase.command');
    }
    switch (phase) {
      case WriteStep.WAIT:
        return I18n.t('wp.phase.wait');
      case WriteStep.HANDSHAKE:
        return I18n.t('wp.phase.handshake');
      case WriteStep.TRANSFER:
        return I18n.t('wp.phase.transfer');
      case WriteStep.FLASH:
        return I18n.t('wp.phase.flash');
      case WriteStep.APPLY:
        return I18n.t('wp.phase.apply');
      default:
        return I18n.t('wp.phase.connect');
    }
  }

  private subject(): string {
    if (this.snap.kind === TaskKind.RESTORE) {
      return I18n.t('wp.titleRestore');
    }
    if (this.snap.kind === TaskKind.BUILTIN) {
      return I18n.f('wp.titleBuiltin', [this.snap.title]);
    }
    return I18n.f('wp.titleTone', [this.snap.title]);
  }

  private detail(): string {
    return TaskPhase.isTerminal(this.snap.phase) ? this.snap.message : this.snap.stage;
  }

  /** 运行中的提示：写音效时提醒别合盖、别切走（后台待久了下一条容易卡住） */
  private hint(): string {
    if (this.running()) {
      return this.snap.kind === TaskKind.TONE ? I18n.t('wp.keepNear') : '';
    }
    return this.snap.phase === TaskPhase.FAILED ? this.snap.hint : '';
  }

  private showPercent(): boolean {
    const phase: string = this.snap.phase;
    return this.snap.kind === TaskKind.TONE &&
      (phase === WriteStep.TRANSFER || phase === WriteStep.FLASH || phase === WriteStep.APPLY);
  }

  /** 步骤条：准备 → 传输 → 写入 → 完成 */
  private currentStep(): number {
    switch (this.snap.phase) {
      case WriteStep.TRANSFER:
        return 1;
      case WriteStep.FLASH:
      case WriteStep.APPLY:
        return 2;
      case TaskPhase.DONE:
        return 3;
      default:
        return 0;
    }
  }

  private showSteps(): boolean {
    return this.snap.kind === TaskKind.TONE && (this.running() || this.snap.phase === TaskPhase.DONE);
  }

  private codeLine(): string {
    if (this.snap.phase !== TaskPhase.FAILED || this.snap.code === 0 || this.snap.reason === WriteReason.BLOCKED) {
      return '';
    }
    return I18n.f('lib.errorCode', [`${this.snap.code}`]);
  }

  private detailColor(): string {
    return this.snap.phase === TaskPhase.FAILED ? Palette.DANGER : Palette.TEXT_SECONDARY;
  }

  // ---------------------------------------------------------------- 动作

  private hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private finishDone(): void {
    const tone: boolean = this.snap.kind === TaskKind.TONE;
    WriteTask.dismiss();
    // 用户点掉「写入完成」之后再谈评分：两个弹窗叠在一起体验很差
    if (tone) {
      RatingService.maybeAskAfterWrite(this.hostContext());
    }
  }

  private openSettings(): void {
    BluetoothService.openSystemBluetoothSettings().catch((error: BusinessError) => {
      Logger.warn(MODULE, `打开系统蓝牙设置失败 code=${error.code}`);
      this.toast(I18n.t('device.openSettingsFailed'));
    });
  }

  private async copyDiagnostic(): Promise<void> {
    const text: string = this.snap.diagnostic;
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

  private restartApp(): void {
    if (!AppRestart.restart(this.hostContext())) {
      this.toast(I18n.t('lib.restartFailed'));
    }
  }

  // ---------------------------------------------------------------- UI

  build() {
    Stack() {
      if (this.snap.phase !== TaskPhase.IDLE) {
        Column() {
          this.card()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 28, right: 28 })
        // 遮罩固定深色、不跟随主题：和全屏忙碌遮罩一致
        .backgroundColor('rgba(5, 8, 14, 0.55)')
        // 模态：遮罩吃掉所有点击
        .onClick((): void => {
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    // 没有任务时整层不参与命中测试，页面照常可点
    .hitTestBehavior(this.snap.phase === TaskPhase.IDLE ? HitTestMode.None : HitTestMode.Default)
  }

  @Builder
  card() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        this.badge()
        Text(this.headline())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
          .textAlign(TextAlign.Center)
        Text(this.subject())
          .fontSize(12)
          .fontColor(Palette.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      if (this.showSteps()) {
        this.steps()
      }

      if (this.showPercent()) {
        Row({ space: 10 }) {
          Progress({ value: this.snap.progress, total: 100, type: ProgressType.Linear })
            .layoutWeight(1)
            .height(6)
            .color(Palette.ACCENT)
            .backgroundColor(Palette.FILL_SOFT)
          Text(`${this.snap.progress}%`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.ACCENT_TEXT)
        }
        .width('100%')
      }

      if (this.detail().length > 0) {
        Text(this.detail())
          .fontSize(13)
          .lineHeight(20)
          .fontColor(this.detailColor())
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      if (this.hint().length > 0) {
        Text(this.hint())
          .fontSize(12)
          .lineHeight(18)
          .fontColor(Palette.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      if (this.codeLine().length > 0) {
        Row({ space: 12 }) {
          Text(this.codeLine())
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
          if (this.snap.diagnostic.length > 0) {
            Text(I18n.t('wp.btn.copy'))
              .fontSize(11)
              .fontColor(Palette.ACCENT_TEXT)
              .onClick((): void => {
                this.copyDiagnostic();
              })
          }
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }

      this.actions()
    }
    .width('100%')
    .constraintSize({ maxWidth: 400 })
    .padding({ left: 20, right: 20, top: 22, bottom: 18 })
    .borderRadius(24)
    .backgroundColor(Palette.BG_CARD)
    .border({ width: 1, color: Palette.STROKE })
    .shadow({
      radius: ThemeService.isDark() ? 28 : 22,
      color: ThemeService.isDark() ? 'rgba(0, 0, 0, 0.5)' : 'rgba(62, 78, 120, 0.2)',
      offsetX: 0,
      offsetY: 8
    })
    // 吃掉卡片上的点击，避免穿透到遮罩
    .onClick((): void => {
    })
  }

  @Builder
  badge() {
    if (this.running()) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(Palette.ACCENT)
    } else {
      Text(this.badgeGlyph())
        .width(44)
        .height(44)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)
        .borderRadius(22)
        .fontColor(this.badgeColor())
        .backgroundColor(this.badgeFill())
    }
  }

  private badgeGlyph(): string {
    if (this.snap.phase === TaskPhase.DONE) {
      return '✓';
    }
    return this.snap.phase === TaskPhase.CANCELLED ? '–' : '!';
  }

  private badgeColor(): string {
    if (this.snap.phase === TaskPhase.DONE) {
      return Palette.SUCCESS;
    }
    return this.snap.phase === TaskPhase.FAILED ? Palette.DANGER : Palette.TEXT_SECONDARY;
  }

  private badgeFill(): string {
    if (this.snap.phase === TaskPhase.DONE) {
      return Palette.SUCCESS_SOFT;
    }
    return this.snap.phase === TaskPhase.FAILED ? Palette.DANGER_SOFT : Palette.FILL_SOFT;
  }

  @Builder
  steps() {
    Row({ space: 6 }) {
      this.stepItem(I18n.t('wp.step.prepare'), 0)
      this.stepLine(1)
      this.stepItem(I18n.t('wp.step.transfer'), 1)
      this.stepLine(2)
      this.stepItem(I18n.t('wp.step.flash'), 2)
      this.stepLine(3)
      this.stepItem(I18n.t('wp.step.done'), 3)
    }
    .width('100%')
  }

  @Builder
  stepItem(label: string, index: number) {
    Row({ space: 4 }) {
      Circle({ width: 6, height: 6 })
        .fill(index <= this.currentStep() ? Palette.ACCENT : Palette.FILL_SOFT)
      Text(label)
        .fontSize(10)
        .fontColor(index === this.currentStep() ? Palette.TEXT_PRIMARY : Palette.TEXT_TERTIARY)
        .fontWeight(index === this.currentStep() ? FontWeight.Medium : FontWeight.Normal)
    }
  }

  @Builder
  stepLine(index: number) {
    Divider()
      .layoutWeight(1)
      .strokeWidth(1)
      .color(index <= this.currentStep() ? Palette.ACCENT_LINE : Palette.FILL_SOFT)
  }

  /** 底部按钮行：等宽排布，主操作在最右 */
  @Builder
  actions() {
    if (this.snap.phase === TaskPhase.FAILED) {
      Row({ space: 10 }) {
        if (this.snap.reason === WriteReason.WEDGED) {
          // 串口卡死：重启应用约 3 秒最快。关开蓝牙也有效但要 20 秒左右、会断开所有蓝牙设备，
          // 只在文案里提示用户自己去控制中心操作，不再替用户关蓝牙
          this.button(I18n.t('wp.btn.close'), false, (): void => {
            WriteTask.dismiss();
          })
          this.button(I18n.t('lib.restartApp'), true, (): void => {
            this.restartApp();
          })
        } else if (this.snap.reason === WriteReason.STALLED) {
          // 耳机没回应：常能自己恢复，先给重试；重试若变成本机秒拒，会以 WEDGED 结局再引导重启
          this.button(I18n.t('wp.btn.close'), false, (): void => {
            WriteTask.dismiss();
          })
          this.button(I18n.t('lib.restartApp'), false, (): void => {
            this.restartApp();
          })
          this.button(I18n.t('wp.btn.retry'), true, (): void => {
            WriteTask.retry();
          })
        } else if (this.snap.reason === WriteReason.NEARLINK) {
          this.button(I18n.t('wp.btn.close'), false, (): void => {
            WriteTask.dismiss();
          })
          this.button(I18n.t('wp.btn.settings'), true, (): void => {
            this.openSettings();
          })
        } else if (this.snap.reason === WriteReason.UNSUPPORTED || this.snap.reason === WriteReason.FORMAT) {
          // 机型不支持 / 格式被拒：重试没有意义，把现场带回给开发者
          this.button(I18n.t('wp.btn.close'), false, (): void => {
            WriteTask.dismiss();
          })
          this.button(I18n.t('wp.btn.copy'), true, (): void => {
            this.copyDiagnostic();
          })
        } else {
          // 不放「查看日志」：用户看不懂日志，排查走「我的 → 日志」或反馈
          this.button(I18n.t('wp.btn.close'), false, (): void => {
            WriteTask.dismiss();
          })
          this.button(I18n.t('wp.btn.retry'), true, (): void => {
            WriteTask.retry();
          })
        }
      }
      .width('100%')
      .margin({ top: 4 })
    } else if (this.snap.phase === TaskPhase.DONE) {
      Row() {
        this.button(I18n.t('wp.btn.done'), true, (): void => {
          this.finishDone();
        })
      }
      .width('100%')
      .margin({ top: 4 })
    } else if (this.snap.phase === TaskPhase.CANCELLED) {
      Row() {
        this.button(I18n.t('wp.btn.close'), true, (): void => {
          WriteTask.dismiss();
        })
      }
      .width('100%')
      .margin({ top: 4 })
    } else if (WriteTask.isCancellable()) {
      Row() {
        this.button(I18n.t('wp.btn.cancel'), false, (): void => {
          WriteTask.cancel();
        })
      }
      .width('100%')
      .margin({ top: 4 })
    }
  }

  @Builder
  button(label: string, primary: boolean, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(primary ? Palette.ON_ACCENT : Palette.TEXT_PRIMARY)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(40)
      .layoutWeight(1)
      .borderRadius(20)
      .backgroundColor(primary ? Palette.ACCENT : Palette.FILL_SOFT)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick((): void => {
        onTap();
      })
  }
}
