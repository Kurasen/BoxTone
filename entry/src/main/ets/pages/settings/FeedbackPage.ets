import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { I18n } from '../../common/i18n/I18n';
import { SupportInfo } from '../../common/constants/AppConstants';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DateUtils } from '../../common/utils/DateUtils';
import { AppEvent, EventBus } from '../../common/utils/EventBus';
import { Logger } from '../../common/utils/Logger';
import { MemProbe } from '../../common/utils/MemProbe';
import { EmptyView } from '../../components/EmptyView';
import { GhostButton } from '../../components/GhostButton';
import { PillButton, PillTone } from '../../components/PillButton';
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
  @StorageProp('themeEpoch') themeEpoch: number = 0;
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
    MemProbe.mount('FeedbackPage');
    this.records = FeedbackService.list();
  }

  aboutToDisappear(): void {
    MemProbe.unmount('FeedbackPage', true, this);
    // 页面销毁时把未提交的截图副本一起清掉，避免长期占着 cacheDir
    FeedbackService.discardImages(this.imagePaths);
    this.imagePaths = [];
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private openPrivacy(): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    PrivacyLinkService.open(context).then((opened: boolean) => {
      if (!opened) {
        this.toast(I18n.t('profile.privacyUnavailable'));
      }
    });
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private headerTitle(): string {
    if (this.step === 1) {
      return I18n.t('fb.submitTitle');
    }
    if (this.step === 2) {
      return I18n.t('fb.mineTitle');
    }
    return I18n.t('fb.title');
  }

  private headerSub(): string {
    if (this.step === 1) {
      return I18n.t('fb.submitSub');
    }
    if (this.step === 2) {
      return I18n.t('fb.mineSub');
    }
    return SupportInfo.FEEDBACK_ONLINE_ENABLED
      ? I18n.t('fb.hubSubOnline')
      : I18n.t('fb.hubSubOffline');
  }

  private async copyEmail(): Promise<void> {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, SupportInfo.EMAIL);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast(I18n.t('fb.emailCopied'));
    } catch (error) {
      Logger.exception(MODULE, '复制邮箱失败', error as BusinessError);
      this.toast(I18n.t('common.copyFailed'));
    }
  }

  private async pickImages(): Promise<void> {
    if (this.imagePaths.length >= MAX_IMAGES) {
      this.toast(I18n.f('fb.maxImages', [`${MAX_IMAGES}`]));
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
      this.toast(I18n.t('fb.pickFailed'));
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
            this.toast(I18n.t('fb.imageTooLarge'));
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
        this.toast(I18n.t('fb.addImageFailed'));
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
    if (index >= 0 && index < this.imagePaths.length) {
      FeedbackService.discardImages([this.imagePaths[index]]);
    }
    this.imagePaths = next;
  }

  private resetForm(): void {
    FeedbackService.discardImages(this.imagePaths);
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
      this.toast(I18n.t('fb.describeFirst'));
      return;
    }
    this.sending = true;
    EventBus.emitText(AppEvent.BUSY_CHANGED, I18n.t('fb.sending'));
    try {
      const draft: FeedbackDraft = {
        typeLabel: I18n.t(FEEDBACK_TYPES[this.typeIndex].labelKey),
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
          title: I18n.t('fb.submitted'),
          message: outcome.message,
          confirm: {
            value: I18n.t('common.ok'),
            action: (): void => {
            }
          }
        });
      } else {
        this.getUIContext().showAlertDialog({
          title: I18n.t('fb.submitFailed'),
          message: outcome.message,
          confirm: {
            value: I18n.t('common.ok'),
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
      // 背景由 Index 外层的 AppBackdrop 统一绘制

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
            rowTitle: I18n.t('fb.entrySubmit'),
            rowDesc: I18n.t('fb.entrySubmitDesc'),
            rowIcon: $r('app.media.ic_feedback'),
            onTap: (): void => {
              this.step = 1;
            }
          })
          Divider()
            .color(Palette.FILL_FAINT)
            .margin({ left: 16, right: 16 })
          FeedbackEntryRow({
            rowTitle: I18n.t('fb.entryMine'),
            rowDesc: I18n.t('fb.entryMineDesc'),
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
          Text(I18n.t('fb.logNotice'))
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
              Text(I18n.t('fb.offlineTitle'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.TEXT_PRIMARY)
            }
            .width('100%')

            Text(I18n.t('fb.offlineBody'))
              .fontSize(11)
              .fontColor(Palette.TEXT_SECONDARY)
              .lineHeight(18)
              .width('100%')

            Row({ space: 8 }) {
              Text(SupportInfo.EMAIL)
                .fontSize(13)
                .fontColor(Palette.ACCENT_TEXT)
                .layoutWeight(1)
              PillButton({
                pillText: I18n.t('fb.copyEmail'),
                pillTone: PillTone.ACCENT,
                onTap: (): void => {
                  this.copyEmail();
                }
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
        Text(I18n.t('fb.type'))
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')

        Row({ space: 8 }) {
          ForEach(FEEDBACK_TYPES, (option: FeedbackTypeOption, index: number) => {
            Text(I18n.t(option.labelKey))
              .fontSize(12)
              .fontWeight(this.typeIndex === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.typeIndex === index ? Palette.ON_ACCENT : Palette.TEXT_SECONDARY)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(999)
              .backgroundColor(this.typeIndex === index ? Palette.ACCENT : Palette.CHIP_IDLE)
              .border({ width: 1, color: this.typeIndex === index ? Palette.ACCENT : Palette.CHIP_IDLE_STROKE })
              .onClick(() => {
                this.typeIndex = index;
              })
          }, (option: FeedbackTypeOption) => option.key)
        }
        .width('100%')

        Text(I18n.t('fb.describe'))
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 6 })

        TextArea({
          text: this.description,
          placeholder: I18n.t('fb.describePlaceholder')
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
          Text(I18n.t('fb.addScreenshots'))
            .fontSize(13)
            .fontColor(Palette.TEXT_PRIMARY)
          Text(I18n.f('fb.optionalImages', [`${MAX_IMAGES}`]))
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
              Text(I18n.t('fb.diagnosticLog'))
                .fontSize(13)
                .fontColor(Palette.TEXT_PRIMARY)
              Text(I18n.t('fb.diagnosticDesc'))
                .fontSize(10)
                .fontColor(Palette.TEXT_TERTIARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(I18n.t('fb.attached'))
              .fontSize(11)
              .fontColor(Palette.SUCCESS)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(Palette.SUCCESS_SOFT)
          }
          .width('100%')
        }

        Text(I18n.t('fb.contact'))
          .fontSize(13)
          .fontColor(Palette.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 6 })

        TextInput({ text: this.contact, placeholder: I18n.t('fb.contactPlaceholder') })
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
          Text(I18n.t('fb.agree'))
            .fontSize(11)
            .fontColor(Palette.TEXT_SECONDARY)
          Text(I18n.t('fb.privacyDoc'))
            .fontSize(11)
            .fontColor(Palette.ACCENT_TEXT)
            .onClick(() => {
              this.openPrivacy();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 10 })

        PrimaryButton({
          btnLabel: I18n.t('fb.send'),
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
          emptyTitle: I18n.t('fb.empty'),
          emptyDesc: I18n.t('fb.emptyDesc')
        })
        Row() {
          GhostButton({
            ghostLabel: I18n.t('fb.goSubmit'),
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
          .fontColor(Palette.ACCENT_TEXT)
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
  @StorageProp('themeEpoch') themeEpoch: number = 0;
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
