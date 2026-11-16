import { Logger } from '../common/utils/Logger';
import { PcmAudio, SynthPreset } from '../models/ToneModel';

const MODULE: string = 'ToneSynth';
const SYNTH_RATE: number = 48000;

interface PartialWave {
  ratio: number;
  amp: number;
}

/**
 * 内置音色合成器
 * 不依赖任何素材，直接以 48kHz 生成波形，再交给统一转换链降采样到 16700Hz
 */
export class ToneSynthesizerService {
  public static readonly PRESETS: SynthPreset[] = [
    { id: 'dawn', name: '晨曦', desc: '清亮钟琴，最接近原厂提示音' },
    { id: 'drop', name: '水滴', desc: '下坠滑音，干净利落' },
    { id: 'pulse', name: '脉冲', desc: '双击短促，适合安静场景' },
    { id: 'rise', name: '上升', desc: '音高上扬，开盖更有仪式感' },
    { id: 'wood', name: '木质', desc: '马林巴质感，温暖厚实' },
    { id: 'glass', name: '琉璃', desc: '长尾泛音，空间感强' }
  ];

  public static generate(presetId: string): PcmAudio {
    Logger.info(MODULE, `合成音色 ${presetId}`);
    if (presetId === 'drop') {
      return ToneSynthesizerService.renderDrop();
    }
    if (presetId === 'pulse') {
      return ToneSynthesizerService.renderPulse();
    }
    if (presetId === 'rise') {
      return ToneSynthesizerService.renderRise();
    }
    if (presetId === 'wood') {
      const partials: PartialWave[] = [
        { ratio: 1, amp: 1 },
        { ratio: 3.93, amp: 0.32 },
        { ratio: 9.24, amp: 0.1 }
      ];
      return ToneSynthesizerService.renderBell(660, partials, 0.26, 1.0);
    }
    if (presetId === 'glass') {
      const partials: PartialWave[] = [
        { ratio: 1, amp: 1 },
        { ratio: 2.01, amp: 0.58 },
        { ratio: 3.02, amp: 0.33 },
        { ratio: 4.17, amp: 0.19 },
        { ratio: 5.43, amp: 0.11 }
      ];
      return ToneSynthesizerService.renderBell(1568, partials, 0.92, 2.4);
    }
    // 默认：晨曦
    const dawnPartials: PartialWave[] = [
      { ratio: 1, amp: 1 },
      { ratio: 2.0, amp: 0.48 },
      { ratio: 2.76, amp: 0.26 },
      { ratio: 4.07, amp: 0.12 }
    ];
    return ToneSynthesizerService.renderBell(1046.5, dawnPartials, 0.72, 1.8);
  }

  /** 钟琴类：多个泛音 + 指数衰减 */
  private static renderBell(f0: number, partials: PartialWave[], tau: number,
    durationSec: number): PcmAudio {
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const attackFrames: number = Math.round(SYNTH_RATE * 0.006);
    let peak: number = 0;
    for (let i = 0; i < total; i++) {
      const t: number = i / SYNTH_RATE;
      const env: number = Math.exp(-t / tau);
      let sample: number = 0;
      for (let p = 0; p < partials.length; p++) {
        const wave: PartialWave = partials[p];
        sample += wave.amp * Math.sin(2 * Math.PI * f0 * wave.ratio * t) * Math.exp(-t / (tau * 1.6));
      }
      let value: number = sample * env;
      if (i < attackFrames) {
        value = value * (i / attackFrames);
      }
      out[i] = value;
      if (Math.abs(value) > peak) {
        peak = Math.abs(value);
      }
    }
    return ToneSynthesizerService.pack(out, peak, durationSec);
  }

  /** 水滴：快速下滑的音高 */
  private static renderDrop(): PcmAudio {
    const durationSec: number = 0.9;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    let phase: number = 0;
    let peak: number = 0;
    for (let i = 0; i < total; i++) {
      const t: number = i / SYNTH_RATE;
      const freq: number = 700 + 1000 * Math.exp(-t / 0.09);
      phase += 2 * Math.PI * freq / SYNTH_RATE;
      const env: number = Math.exp(-t / 0.17);
      const value: number = (Math.sin(phase) + 0.22 * Math.sin(phase * 2)) * env;
      out[i] = value;
      if (Math.abs(value) > peak) {
        peak = Math.abs(value);
      }
    }
    return ToneSynthesizerService.pack(out, peak, durationSec);
  }

  /** 脉冲：两声极短的点按音 */
  private static renderPulse(): PcmAudio {
    const durationSec: number = 0.42;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const onsets: number[] = [0, 0.105];
    let peak: number = 0;
    for (let i = 0; i < total; i++) {
      const t: number = i / SYNTH_RATE;
      let value: number = 0;
      for (let k = 0; k < onsets.length; k++) {
        const local: number = t - onsets[k];
        if (local >= 0 && local < 0.16) {
          value += Math.sin(2 * Math.PI * 2350 * local) * Math.exp(-local / 0.016) * 0.9;
        }
      }
      out[i] = value;
      if (Math.abs(value) > peak) {
        peak = Math.abs(value);
      }
    }
    return ToneSynthesizerService.pack(out, peak, durationSec);
  }

  /** 上升：指数扫频 + 轻微颤音 */
  private static renderRise(): PcmAudio {
    const durationSec: number = 1.25;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    let phase: number = 0;
    let peak: number = 0;
    for (let i = 0; i < total; i++) {
      const t: number = i / SYNTH_RATE;
      const progress: number = t / durationSec;
      const freq: number = 440 * Math.pow(3, progress) * (1 + 0.004 * Math.sin(2 * Math.PI * 5.2 * t));
      phase += 2 * Math.PI * freq / SYNTH_RATE;
      const attack: number = Math.min(1, t / 0.05);
      const release: number = Math.min(1, (durationSec - t) / 0.3);
      const env: number = attack * release;
      const value: number = (Math.sin(phase) + 0.18 * Math.sin(phase * 2)) * env;
      out[i] = value;
      if (Math.abs(value) > peak) {
        peak = Math.abs(value);
      }
    }
    return ToneSynthesizerService.pack(out, peak, durationSec);
  }

  private static pack(samples: Float32Array, peak: number, durationSec: number): PcmAudio {
    if (peak > 0.0001) {
      const scale: number = 0.92 / peak;
      for (let i = 0; i < samples.length; i++) {
        samples[i] = samples[i] * scale;
      }
    }
    const pcm: PcmAudio = {
      sampleRate: SYNTH_RATE,
      channels: 1,
      frameCount: samples.length,
      frames: samples
    };
    Logger.debug(MODULE, `合成完成 时长 ${durationSec.toFixed(2)}s 帧数 ${samples.length}`);
    return pcm;
  }
}
