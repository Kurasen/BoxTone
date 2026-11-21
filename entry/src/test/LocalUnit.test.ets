import { describe, it, expect } from '@ohos/hypium';
import { ByteUtils } from '../main/ets/common/utils/ByteUtils';
import { MbbProtocol } from '../main/ets/services/bluetooth/MbbProtocol';
import {
  DeviceSupport,
  DeviceSupportLevel,
  DeviceVerdict,
  MbbSpec,
  ToneSpec
} from '../main/ets/common/constants/AppConstants';

/**
 * 纯逻辑单测（L1）。
 *
 * 这些用例之前散落在 SelfCheckService 里、只能靠 tools/verify-logic.mjs 在 Node 上跑；
 * 现在补进 hypium，保证 hvigorw test 能覆盖协议编解码这条最容易回归的链路。
 */
export default function localUnitTest() {
  describe('ByteUtils', () => {
    it('hex_roundtrip', 0, () => {
      const source: Uint8Array = new Uint8Array([0x00, 0x5A, 0xFF, 0x10]);
      const roundtrip: Uint8Array = ByteUtils.fromHex(ByteUtils.toHex(source));
      expect(roundtrip.length).assertEqual(source.length);
      for (let i = 0; i < source.length; i++) {
        expect(roundtrip[i]).assertEqual(source[i]);
      }
    });

    it('be16_and_intBE', 0, () => {
      const bytes: Uint8Array = ByteUtils.be16(0xABCD);
      expect(bytes[0]).assertEqual(0xAB);
      expect(bytes[1]).assertEqual(0xCD);
      const wide: Uint8Array = ByteUtils.be32(0x01020304);
      expect(ByteUtils.intBE(wide)).assertEqual(0x01020304);
    });

    it('little_endian', 0, () => {
      const le16: Uint8Array = ByteUtils.u16le(0x1234);
      expect(le16[0]).assertEqual(0x34);
      expect(le16[1]).assertEqual(0x12);
      const le32: Uint8Array = ByteUtils.u32le(0x89ABCDEF);
      expect(le32[0]).assertEqual(0xEF);
      expect(le32[3]).assertEqual(0x89);
    });

    it('slice_bounds', 0, () => {
      const source: Uint8Array = ByteUtils.fromHex('000102030405');
      expect(ByteUtils.slice(source, 1, 4).length).assertEqual(3);
      expect(ByteUtils.slice(source, -5, 999).length).assertEqual(source.length);
      expect(ByteUtils.slice(source, 5, 2).length).assertEqual(0);
    });

    it('utf8_length', 0, () => {
      expect(ByteUtils.utf8('盒').length).assertEqual(3);
      expect(ByteUtils.utf8('A').length).assertEqual(1);
    });
  });

  describe('MbbProtocol', () => {
    it('frame_header_and_crc', 0, () => {
      const payload: Uint8Array = ByteUtils.fromHex('09010101');
      const packet: Uint8Array = MbbProtocol.frame(payload);
      expect(packet[0]).assertEqual(MbbSpec.FRAME_HEAD);
      expect(packet.length).assertEqual(payload.length + 6);
      expect(MbbProtocol.crc(packet)).assertEqual(0);
    });

    it('fragment_split', 0, () => {
      const big: Uint8Array = new Uint8Array(3000);
      for (let i = 0; i < big.length; i++) {
        big[i] = i & 0xFF;
      }
      const frames: Uint8Array[] = MbbProtocol.frames(big);
      expect(frames.length > 1).assertTrue();
      expect(frames[0][3]).assertEqual(MbbProtocol.CONTROL_FIRST);
      expect(frames[frames.length - 1][3]).assertEqual(MbbProtocol.CONTROL_LAST);
    });

    it('tlv_roundtrip', 0, () => {
      const shortValue: Uint8Array = new Uint8Array([1, 2, 3]);
      const longValue: Uint8Array = new Uint8Array(300);
      const packet: Uint8Array = ByteUtils.concat([
        ByteUtils.fromHex('0901'),
        MbbProtocol.field(1, shortValue),
        MbbProtocol.field(2, longValue)
      ]);
      const fields: Map<number, Uint8Array> = MbbProtocol.tlv(packet);
      expect(fields.get(1)?.length).assertEqual(3);
      expect(fields.get(2)?.length).assertEqual(300);
    });

    it('tone_package_rejects_oversize', 0, () => {
      let rejected: boolean = false;
      try {
        MbbProtocol.tonePackage(new Uint8Array(ToneSpec.MAX_BYTES + ToneSpec.BYTES_PER_FRAME));
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });

  describe('ToneSpec', () => {
    // 界面按秒算、写入按字节拦，两个上限必须能互相推导出来
    it('limits_consistent', 0, () => {
      expect(ToneSpec.BYTES_PER_SECOND)
        .assertEqual(ToneSpec.SAMPLE_RATE * ToneSpec.BYTES_PER_FRAME);
      expect(ToneSpec.MAX_BYTES)
        .assertEqual(Math.floor(ToneSpec.BYTES_PER_SECOND * ToneSpec.MAX_SECONDS));
      expect(ToneSpec.MAX_BYTES % ToneSpec.BYTES_PER_FRAME).assertEqual(0);
      // 导入允许旧版本的长音效，但不能比可写入上限还小
      expect(ToneSpec.MAX_IMPORT_BYTES > ToneSpec.MAX_BYTES).assertTrue();
      expect(ToneSpec.MAX_IMPORT_BYTES % ToneSpec.BYTES_PER_FRAME).assertEqual(0);
    });

    it('custom_slot_in_range', 0, () => {
      // 官方音效表里 100~179 才是自建槽位；43 是出厂预置槽
      expect(MbbSpec.TONE_CUSTOM_ID >= 100).assertTrue();
      expect(MbbSpec.TONE_CUSTOM_ID <= 179).assertTrue();
    });
  });

  describe('DeviceSupport', () => {
    it('model_wins_over_name', 0, () => {
      const verdict: DeviceVerdict = DeviceSupport.judge('BTFT0027', ['HUAWEI FreeBuds 7']);
      expect(verdict.level).assertEqual(DeviceSupportLevel.VERIFIED);
    });

    it('name_fallback', 0, () => {
      const verdict: DeviceVerdict = DeviceSupport.judge('', ['华为 FreeClip 2 耳夹耳机']);
      expect(verdict.level).assertEqual(DeviceSupportLevel.VERIFIED);
    });

    it('model_suffix_variant', 0, () => {
      const verdict: DeviceVerdict = DeviceSupport.judge('btft0023-000167', []);
      expect(verdict.level).assertEqual(DeviceSupportLevel.VERIFIED);
    });

    it('unknown_device', 0, () => {
      const verdict: DeviceVerdict = DeviceSupport.judge('BTFT9999', ['Unknown Buds']);
      expect(verdict.level).assertEqual(DeviceSupportLevel.UNKNOWN);
    });
  });
}