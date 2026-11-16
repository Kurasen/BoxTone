import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { SupportInfo } from '../../common/constants/AppConstants';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DateUtils } from '../../common/utils/DateUtils';
import { AppEvent, EventBus } from '../../common/utils/EventBus';
import { Logger } from '../../common/utils/Logger';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { PrivacyLinkService } from '../../services/PrivacyLinkService';
import { GlassCard } from '../../components/GlassCard';
import { PrimaryButton } from '../../components/PrimaryButton';
import {
  FEEDBACK_TYPES, FeedbackDraft, FeedbackRecord, FeedbackService, FeedbackTypeOption, IMAGE_MAX_BYTES, MAX_IMAGES,
  SubmitOutcome
} from '../../services/FeedbackService';

const MODULE: string = 'FeedbackPage';

/**
 * 反馈与建议（全屏浮层）
 * 0 = 入口页，1 = 提交反馈，2 = 我的反馈
 */
@Component
export struct FeedbackPage {
  @Link step: number;
  @Prop topInset: number = 0;
  onClose: () => void = () => {
  };
  @State typeIndex: number = 0;
  @State description: string = '';
  @State contact: string = '';
  @State imagePaths: string[] = [];
  @State sending: boolean = false;
  @State policyAgreed: boolean = false;
  @State records: FeedbackRecord[] = [];

  aboutToAppear(): void {
    this.records = FeedbackService.list();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private openPrivacy(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean) => {
      if (!opened) {
        this.toast('隐私政策链接暂不可用，请稍后重试');
      }
    });
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private headerTitle(): string {
    if (this.step === 1) {
      return '提交反馈';
    }
    if (this.step === 2) {
      return '我的反馈';
    }
    return '反馈与建议';
  }

  private headerSub(): string {
    if (this.step === 1) {
      return '自动附带限制大小的诊断日志';
    }
    if (this.step === 2) {
      return '本机提交记录与发送状态';
    }
    return SupportInfo.FEEDBACK_ONLINE_ENABLED
      ? '遇到问题，或有想改进的地方？直接告诉我'
      : '在线反馈暂未开放，可通过邮箱联系';
  }

  private async copyEmail(): Promise<void> {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, SupportInfo.EMAIL);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast('邮箱已复制');
    } catch (error) {
      Logger.exception(MODULE, '复制邮箱失败', error as BusinessError);
      this.toast('复制失败');
    }
  }

  private async pickImages(): Promise<void> {
    if (this.imagePaths.length >= MAX_IMAGES) {
      this.toast(`最多添加 ${MAX_IMAGES} 张截图`);
      return;
    }
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = MAX_IMAGES - this.imagePaths.length;
      const pickerInstance: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await pickerInstance.select(options);
      this.copyImages(result.photoUris);
    } catch (error) {
      Logger.exception(MODULE, '选择截图失败', error as BusinessError);
      this.toast('选择截图失败');
    }
  }

  private copyImages(uris: string[]): void {
    const cacheDir: string = this.context().cacheDir;
    const next: string[] = [];
    for (let i = 0; i < this.imagePaths.length; i++) {
      next.push(this.imagePaths[i]);
    }
    for (let i = 0; i < uris.length && next.length < MAX_IMAGES; i++) {
      const ext: string = FeedbackService.suffixOf(uris[i]);
      const path: string = `${cacheDir}/feedback-image-${Date.now()}-${i}${ext}`;
      try {
        // 选择器返回的是 URI，copyFileSync 打不开，必须 openSync 后再读写
        const source: fs.File = fs.openSync(uris[i], fs.OpenMode.READ_ONLY);
        try {
          const size: number = fs.statSync(source.fd).size;
          if (size > IMAGE_MAX_BYTES) {
            this.toast('有截图超过 4MB，已跳过');
            continue;
          }
          const buffer: ArrayBuffer = new ArrayBuffer(size);
          const read: number = fs.readSync(source.fd, buffer);
          const dest: fs.File = fs.openSync(path,
            fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(dest.fd, buffer.slice(0, read));
          } finally {
            fs.closeSync(dest);
          }
        } finally {
          fs.closeSync(source);
        }
        next.push(path);
      } catch (error) {
        Logger.exception(MODULE, '复制截图失败', error as BusinessError);
        this.toast('添加截图失败');
      }
    }
    this.imagePaths = next;
  }

  private removeImage(index: number): void {
    const next: string[] = [];
    for (let i = 0; i < this.imagePaths.length; i++) {
      if (i !== index) {
        next.push(this.imagePaths[i]);
      }
    }
    this.imagePaths = next;
  }

  private resetForm(): void {
    this.typeIndex = 0;
    this.description = '';
    this.contact = '';
    this.imagePaths = [];
  }

  private async submit(): Promise<void> {
    if (this.sending) {
      return;
    }
    const text: string = this.description.trim();
    if (text.length === 0) {
      this.toast('请先描述遇到的问题或建议');
      return;
    }
    this.sending = true;
    EventBus.emitText(AppEvent.BUSY_CHANGED, '正在发送反馈…');
    try {
      const draft: FeedbackDraft = {
        typeLabel: FEEDBACK_TYPES[this.typeIndex].label,
        description: text,
        contact: this.contact.trim(),
        imagePaths: this.imagePaths
      };
      const outcome: SubmitOutcome = await FeedbackService.submit(draft);
      if (outcome.ok) {
        this.resetForm();
        this.records = FeedbackService.list();
        this.step = 2;
        this.getUIContext().showAlertDialog({
          title: '反馈已提交',
          message: outcome.message,
          confirm: {
            value: '知道了',
            action: (): void => {
            }
          }
        });
      } else {
        this.getUIContext().showAlertDialog({
          title: '提交失败',
          message: outcome.message,
          confirm: {
            value: '知道了',
            action: (): void => {
            }
          }
        });
      }
    } finally {
      this.sending = false;
      EventBus.emitText(AppEvent.BUSY_CHANGED, '');
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.buildTopBar()

        if (this.step === 0) {
          this.buildHub()
        } else if (this.step === 1) {
          this.buildSubmit()
        } else {
          this.buildMine()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      .backgroundColor(Palette.BG_TOP)
      .linearGradient({
        angle: 170,
        colors: [[Palette.BG_TOP, 0.0], ['#0C1422', 1.0]]
      })

    }
    .width('100%')
    .height('100%')
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
          if (this.step === 0) {
            this.onClose();
          } else {
            this.step = 0;
          }
        })

      Column({ space: 3 }) {
        Text(this.headerTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(this.headerSub())
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
  buildHub() {
    Column({ space: 12 }) {
      if (SupportInfo.FEEDBACK_ONLINE_ENABLED) {
        GlassCard({ cardPadding: 4 }) {
          FeedbackEntryRow({
            rowTitle: '提交反馈',
            rowDesc: '无需登录，可附截图与诊断日志',
            rowIcon: $r('app.media.ic_feedback'),
            onTap: (): void => {
              this.step = 1;
            }
          })
          Divider()
            .color('rgba(255, 255, 255, 0.05)')
            .margin({ left: 16, right: 16 })
          FeedbackEntryRow({
            rowTitle: '我的反馈',
            rowDesc: '查看本机提交记录和发送状态',
            rowIcon: $r('app.media.ic_clock'),
            onTap: (): void => {
              this.records = FeedbackService.list();
              this.step = 2;
            }
          })
        }

        Row({ space: 8 }) {
          Image($r('app.media.ic_info'))
            .width(12)
            .height(12)
            .fillColor(Palette.TEXT_TERTIARY)
          Text('反馈会附带当前机型的诊断日志（txt，≤512KB），请先确认内容不含隐私信息。')
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
            .lineHeight(16)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: 4, right: 4 })
      } else {
        GlassCard({ cardPadding: 16 }) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Image($r('app.media.ic_info'))
                .width(16)
                .height(16)
                .fillColor(Palette.WARNING)
              Text('在线反馈暂未开放')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.TEXT_PRIMARY)
            }
            .width('100%')

            Text('在线反馈会在完成联网备案后开放。现在可以直接发邮件给开发者，' +
              '附上问题描述、机型和截图即可。')
              .fontSize(11)
              .fontColor(Palette.TEXT_SECONDARY)
              .lineHeight(18)
              .width('100%')

            Row({ space: 8 }) {
              Text(SupportInfo.EMAIL)
                .fontSize(13)
                .fontColor(Palette.ACCENT)
                .layoutWeight(1)
              Text('复制邮箱')
                .fontSize(11)
                .fontColor(Palette.ACCENT)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .backgroundColor(Palette.ACCENT_SOFT)
                .onClick(() => {
                  this.copyEmail();
                })
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Metric.PAGE_PADDING, right: Metric.PAGE_PADDING, top: 6 })
  }

  @Builder
  buildSubmit() {
    Scroll() {
      Column({ space: 12 }) {
        Text('反馈类型')
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')

        Row({ space: 8 }) {
          ForEach(FEEDBACK_TYPES, (option: FeedbackTypeOption, index: number) => {
            Text(option.label)
              .fontSize(12)
              .fontColor(this.typeIndex === index ? '#05080E' : Palette.TEXT_SECONDARY)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(999)
              .backgroundColor(this.typeIndex === index ? Palette.ACCENT : 'rgba(255, 255, 255, 0.05)')
              .onClick(() => {
                this.typeIndex = index;
              })
          }, (option: FeedbackTypeOption) => option.key)
        }
        .width('100%')

        Text('请描述一下')
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 6 })

        TextArea({
          text: this.description,
          placeholder: '遇到问题：在哪个页面、如何触发、实际结果。\n提出建议：使用场景、希望怎样改进。'
        })
          .width('100%')
          .height(150)
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .placeholderColor(Palette.TEXT_TERTIARY)
          .backgroundColor(Palette.BG_INPUT)
          .borderRadius(16)
          .padding(12)
          .maxLength(10000)
          .onChange((value: string) => {
            this.description = value;
          })

        Text(`${this.description.length} / 10000`)
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .width('100%')
          .textAlign(TextAlign.End)

        Row({ space: 6 }) {
          Text('添加截图')
            .fontSize(13)
            .fontColor(Palette.TEXT_PRIMARY)
          Text(`选填 · 最多 ${MAX_IMAGES} 张`)
            .fontSize(10)
            .fontColor(Palette.TEXT_TERTIARY)
        }
        .width('100%')
        .margin({ top: 2 })

        Row({ space: 10 }) {
          ForEach(this.imagePaths, (path: string, index: number) => {
            this.buildImageTile(path, index)
          }, (path: string) => path)

          if (this.imagePaths.length < MAX_IMAGES) {
            Stack() {
              Image($r('app.media.ic_add'))
                .width(20)
                .height(20)
                .fillColor(Palette.TEXT_TERTIARY)
            }
            .width(72)
            .height(72)
            .borderRadius(14)
            .backgroundColor(Palette.BG_INPUT)
            .border({ width: 1, color: Palette.STROKE_SOFT })
            .onClick(() => {
              this.pickImages();
            })
          }
        }
        .width('100%')

        GlassCard({ cardPadding: 14 }) {
          Row({ space: 12 }) {
            Image($r('app.media.ic_log'))
              .width(18)
              .height(18)
              .fillColor(Palette.TEXT_SECONDARY)

            Column({ space: 3 }) {
              Text('诊断日志')
                .fontSize(13)
                .fontColor(Palette.TEXT_PRIMARY)
              Text('提交时自动附带最近日志（txt，≤512KB）')
                .fontSize(10)
                .fontColor(Palette.TEXT_TERTIARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('自动附带')
              .fontSize(11)
              .fontColor(Palette.SUCCESS)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(Palette.SUCCESS_SOFT)
          }
          .width('100%')
        }

        Text('联系方式')
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 6 })

        TextInput({ text: this.contact, placeholder: 'QQ / 邮箱，仅用于需要补充信息时联系' })
          .width('100%')
          .height(46)
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .placeholderColor(Palette.TEXT_TERTIARY)
          .backgroundColor(Palette.BG_INPUT)
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.contact = value;
          })

        Row({ space: 6 }) {
          Checkbox({ name: 'feedback-agree' })
            .select(this.policyAgreed)
            .selectedColor(Palette.ACCENT)
            .width(18)
            .height(18)
            .onChange((checked: boolean) => {
              this.policyAgreed = checked;
            })
          Text('我已阅读并同意')
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
          Text('《隐私政策》')
            .fontSize(11)
            .fontColor(Palette.ACCENT)
            .onClick(() => {
              this.openPrivacy();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 10 })

        PrimaryButton({
          btnLabel: '提交反馈',
          btnEnabled: this.description.trim().length > 0 && this.policyAgreed,
          btnLoading: this.sending,
          onTap: (): void => {
            this.submit();
          }
        })
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: Metric.PAGE_PADDING,
        right: Metric.PAGE_PADDING,
        top: 4,
        bottom: 40
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  buildImageTile(path: string, index: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image(`file://${path}`)
        .width(72)
        .height(72)
        .borderRadius(14)
        .objectFit(ImageFit.Cover)

      Stack() {
        Image($r('app.media.ic_close'))
          .width(9)
          .height(9)
          .fillColor('#FFFFFF')
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .backgroundColor('rgba(0, 0, 0, 0.62)')
      .margin({ top: 4, right: 4 })
      .onClick(() => {
        this.removeImage(index);
      })
    }
    .width(72)
    .height(72)
  }

  @Builder
  buildMine() {
    if (this.records.length === 0) {
      Column({ space: 16 }) {
        EmptyView({
          emptyIcon: $r('app.media.ic_clock'),
          emptyTitle: '还没有提交过反馈',
          emptyDesc: '提交后可以在这里查看发送状态。'
        })
        Row() {
          GhostButton({
            ghostLabel: '去提交反馈',
            onTap: (): void => {
              this.step = 1;
            }
          })
        }
        .width('100%')
        .padding({ left: 48, right: 48 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 10 }) {
        ForEach(this.records, (record: FeedbackRecord) => {
          ListItem() {
            this.buildRecord(record)
          }
        }, (record: FeedbackRecord) => record.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: Metric.PAGE_PADDING, right: Metric.PAGE_PADDING })
      .cachedCount(6)
    }
  }

  @Builder
  buildRecord(record: FeedbackRecord) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(record.typeLabel)
          .fontSize(12)
          .fontColor(Palette.ACCENT)
        Text(DateUtils.dateTime(record.createdAt))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
        Blank()
        Text(`${record.channel} · ${record.status}`)
          .fontSize(10)
          .fontColor(Palette.SUCCESS)
      }
      .width('100%')

      Text(record.description)
        .fontSize(12)
        .fontColor(Palette.TEXT_SECONDARY)
        .lineHeight(18)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(14)
    .backgroundColor(Palette.BG_CARD)
    .border({ width: 1, color: Palette.STROKE_SOFT })
  }
}

@Component
struct FeedbackEntryRow {
  @Prop rowTitle: string = '';
  @Prop rowDesc: string = '';
  rowIcon: Resource = $r('app.media.ic_feedback');
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Image(this.rowIcon)
        .width(18)
        .height(18)
        .fillColor(Palette.TEXT_SECONDARY)
        .margin({ left: 12 })

      Column({ space: 3 }) {
        Text(this.rowTitle)
          .fontSize(14)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(this.rowDesc)
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Image($r('app.media.ic_chevron_right'))
        .width(13)
        .height(13)
        .fillColor(Palette.TEXT_TERTIARY)
        .margin({ right: 12 })
    }
    .width('100%')
    .height(62)
    .onClick(() => {
      this.onTap();
    })
  }
}
