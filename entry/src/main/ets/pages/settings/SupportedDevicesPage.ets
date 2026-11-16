import { I18n } from '../../common/i18n/I18n';
import { Metric, Palette } from '../../common/constants/ThemeConstants';
import { DeviceSupport, DeviceSupportLevel, SupportedDevice } from '../../common/constants/AppConstants';
import { GlassCard } from '../../components/GlassCard';
import { SectionTitle } from '../../components/SectionTitle';

/** 支持机型：实测记录 + 兼容性判断说明 */
@Component
export struct SupportedDevicesPage {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  topInset: number = 0;
  onClose: () => void = () => {
  };

  build() {
    Column() {
      this.buildTopBar()

      Scroll() {
        Column({ space: 16 }) {
          SectionTitle({
            sectionText: I18n.t('support.verified'),
            sectionHint: I18n.f('support.count', [`${DeviceSupport.countOf(DeviceSupportLevel.VERIFIED)}`])
          })

          GlassCard({ cardPadding: 16 }) {
            ForEach(DeviceSupport.devicesOf(DeviceSupportLevel.VERIFIED),
              (device: SupportedDevice, index: number) => {
                this.buildDeviceRow(device, true, index)
              }, (device: SupportedDevice) => `v-${device.names[0]}`)
          }

          // 全部机型转为已验证后这一栏没有内容，直接隐藏
          if (DeviceSupport.countOf(DeviceSupportLevel.OFFICIAL) > 0) {
            SectionTitle({
              sectionText: I18n.t('support.official'),
              sectionHint: I18n.f('support.count', [`${DeviceSupport.countOf(DeviceSupportLevel.OFFICIAL)}`])
            })

            GlassCard({ cardPadding: 16 }) {
              ForEach(DeviceSupport.devicesOf(DeviceSupportLevel.OFFICIAL),
                (device: SupportedDevice, index: number) => {
                  this.buildDeviceRow(device, false, index)
                }, (device: SupportedDevice) => `o-${device.names[0]}`)
            }
          }

          SectionTitle({ sectionText: I18n.t('support.how') })

          GlassCard({ cardPadding: 16 }) {
            this.buildNote(I18n.t('support.note1'))
            this.buildNote(I18n.t('support.note2'))
            this.buildNote(I18n.t('support.note3'))
            this.buildNote(I18n.t('support.note4'))
            this.buildNote(I18n.t('support.note5'))
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
    .backgroundColor(Palette.BG_TOP)
    .linearGradient({
      angle: 170,
      colors: [[Palette.BG_TOP, 0.0], [Palette.BG_END, 1.0]]
    })
  }

  @Builder
  buildDeviceRow(device: SupportedDevice, verified: boolean, index: number) {
    if (index > 0) {
      Divider()
        .color(Palette.FILL_FAINT)
        .margin({ top: 10, bottom: 10 })
    }
    Row({ space: 10 }) {
      Stack() {
        Image(verified ? $r('app.media.ic_check') : $r('app.media.ic_info'))
          .width(10)
          .height(10)
          .fillColor(verified ? Palette.SUCCESS : Palette.WARNING)
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .backgroundColor(verified ? Palette.SUCCESS_SOFT : Palette.WARNING_SOFT)

      Column({ space: 3 }) {
        Text(device.names[0])
          .fontSize(14)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.t(device.detailKey))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
        Text(device.modelCodes.length > 0 ? I18n.f('support.model', [device.modelCodes.join(' / ')]) :
          I18n.t('support.modelUnknown'))
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(verified ? I18n.t('support.verifiedTag') : I18n.t('support.pendingTag'))
        .fontSize(10)
        .fontColor(verified ? Palette.SUCCESS : Palette.WARNING)
    }
    .width('100%')
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
        Text(I18n.t('support.title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text(I18n.t('support.subtitle'))
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
      Circle()
        .width(4)
        .height(4)
        .fill(Palette.ACCENT)
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
