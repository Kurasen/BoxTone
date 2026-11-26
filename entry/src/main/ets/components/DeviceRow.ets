import { I18n } from '../common/i18n/I18n';
import { Palette } from '../common/constants/ThemeConstants';
import { FormatUtils } from '../common/utils/FormatUtils';
import { PillButton, PillTone } from './PillButton';
import { BtDevice, createEmptyDevice } from '../models/DeviceModel';

/** 蓝牙设备行 */
@Component
export struct DeviceRow {
  @StorageProp('themeEpoch') themeEpoch: number = 0;
  @Prop device: BtDevice = createEmptyDevice();
  @Prop actionLabel: string = '';
  @Prop showAction: boolean = true;
  onAction: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Stack() {
        Circle()
          .width(38)
          .height(38)
          .fill(this.device.audio ? Palette.ACCENT_SOFT : Palette.FILL_FAINT)
        Image($r('app.media.ic_tab_device'))
          .width(18)
          .height(18)
          .fillColor(this.device.audio ? Palette.ACCENT_TEXT : Palette.TEXT_TERTIARY)
      }

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.device.name)
            .fontSize(13)
            .fontColor(Palette.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.device.connected) {
            Circle()
              .width(6)
              .height(6)
              .fill(Palette.SUCCESS)
          }
        }
        .width('100%')

        Text(this.subtitle())
          .fontSize(11)
          .fontColor(Palette.TEXT_TERTIARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showAction && this.actionLabel.length > 0) {
        PillButton({
          pillText: this.actionLabel,
          pillTone: PillTone.ACCENT,
          onTap: (): void => {
            this.onAction();
          }
        })
      }
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  private subtitle(): string {
    const address: string = FormatUtils.maskAddress(this.device.deviceId);
    if (this.device.nearLink && this.device.connected) {
      return I18n.f('row.nearLink', [address]);
    }
    if (this.device.connected) {
      return I18n.f('row.connected', [address]);
    }
    if (this.device.paired) {
      return I18n.f('row.paired', [address]);
    }
    return this.device.audio ? I18n.f('row.audio', [address]) : address;
  }
}
