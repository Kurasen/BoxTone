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
            sectionText: '实测通过机型',
            sectionHint: `${DeviceSupport.countOf(DeviceSupportLevel.VERIFIED)} 款`
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
              sectionText: '官方支持开盒提示音',
              sectionHint: `${DeviceSupport.countOf(DeviceSupportLevel.OFFICIAL)} 款`
            })

            GlassCard({ cardPadding: 16 }) {
              ForEach(DeviceSupport.devicesOf(DeviceSupportLevel.OFFICIAL),
                (device: SupportedDevice, index: number) => {
                  this.buildDeviceRow(device, false, index)
                }, (device: SupportedDevice) => `o-${device.names[0]}`)
            }
          }

          SectionTitle({ sectionText: '兼容性如何判断' })

          GlassCard({ cardPadding: 16 }) {
            this.buildNote('写入前会先通过耳机私有协议读取自报型号：只解析型号字段，不读取 SN；型号来自固件，用户改名不受影响。')
            this.buildNote('型号优先匹配；型号未识别时回退蓝牙名。典藏版、同平台变体按基础型号前缀匹配。')
            this.buildNote('“官方支持开盒提示音”只说明该机型具备官方功能，盒音自定义仍需协议能力探测和格式确认。')
            this.buildNote('格式确认发生在第一个数据包之前：耳机不接受 16700Hz / 16bit 音效格式时会直接拒绝，本次不会写入任何数据，也不会损坏设备。')
            this.buildNote('其他品牌或未适配耳机：能力查询无响应或拒绝格式时，应用会明确提示并停止写入。')
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
        Text(device.detail)
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
        Text(device.modelCodes.length > 0 ? `型号 ${device.modelCodes.join(' / ')}` : '型号代码待实测回传')
          .fontSize(10)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(verified ? '已验证' : '待实测')
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
        Text('支持机型')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT_PRIMARY)
        Text('型号识别 + 协议探测，列表供参考')
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
