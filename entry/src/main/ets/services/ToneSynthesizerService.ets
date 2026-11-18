import { Logger } from '../common/utils/Logger';
import { PcmAudio, SynthPreset } from '../models/ToneModel';

const MODULE: string = 'ToneSynth';
const SYNTH_RATE: number = 48000;

interface PartialWave {
  ratio: number;
  amp: number;
}

/** 确定性伪随机源：保证每次生成同一个音色的结果一致 */
class NoiseSource {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0;
  }

  next(): number {
    this.state = (this.state * 1664525 + 1013904223) % 4294967296;
    return this.state / 4294967296;
  }

  bipolar(): number {
    return this.next() * 2 - 1;
  }
}

/**
 * 内置音色合成器
 * 不依赖任何素材，直接以 48kHz 生成波形，再交给统一转换链降采样到 16700Hz。
 * 钟琴类音色刻意把泛音限制在 4kHz 内，避免充电盒小喇叭听起来刺耳。
 */
export class ToneSynthesizerService {
  public static readonly PRESETS: SynthPreset[] = [
    { id: 'dawn', nameKey: 'preset.dawn.name', descKey: 'preset.dawn.desc' },
    { id: 'drop', nameKey: 'preset.drop.name', descKey: 'preset.drop.desc' },
    { id: 'pulse', nameKey: 'preset.pulse.name', descKey: 'preset.pulse.desc' },
    { id: 'rise', nameKey: 'preset.rise.name', descKey: 'preset.rise.desc' },
    { id: 'wood', nameKey: 'preset.wood.name', descKey: 'preset.wood.desc' },
    { id: 'glass', nameKey: 'preset.glass.name', descKey: 'preset.glass.desc' },
    { id: 'rain', nameKey: 'preset.rain.name', descKey: 'preset.rain.desc' },
    { id: 'windchime', nameKey: 'preset.windchime.name', descKey: 'preset.windchime.desc' },
    { id: 'birds', nameKey: 'preset.birds.name', descKey: 'preset.birds.desc' }
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
      return ToneSynthesizerService.renderWood();
    }
    if (presetId === 'glass') {
      return ToneSynthesizerService.renderGlass();
    }
    if (presetId === 'rain') {
      return ToneSynthesizerService.renderRain();
    }
    if (presetId === 'windchime') {
      return ToneSynthesizerService.renderWindChime();
    }
    if (presetId === 'birds') {
      return ToneSynthesizerService.renderBirds();
    }
    return ToneSynthesizerService.renderDawn();
  }

  /** 晨曦：C5-E5-G5 三音上行，柔和的钟琴泛音 */
  private static renderDawn(): PcmAudio {
    const durationSec: number = 1.7;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const partials: PartialWave[] = ToneSynthesizerService.softPartials();
    ToneSynthesizerService.addBell(out, 0, 523.25, partials, 1.0, 0.55);
    ToneSynthesizerService.addBell(out, 0.12, 659.25, partials, 0.85, 0.5);
    ToneSynthesizerService.addBell(out, 0.24, 783.99, partials, 0.7, 0.45);
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 水滴：两声下坠的“咚”，叠加低频水滴体感 */
  private static renderDrop(): PcmAudio {
    const durationSec: number = 1.0;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    ToneSynthesizerService.addDrop(out, 0, 0.18, 980, 460, 0.9, 0.10, 0.18);
    ToneSynthesizerService.addDrop(out, 0, 0.22, 240, 165, 0.35, 0.16, 0.26);
    ToneSynthesizerService.addDrop(out, 0.26, 0.16, 880, 420, 0.65, 0.09, 0.16);
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 脉冲：两声很短的木质点按音 */
  private static renderPulse(): PcmAudio {
    const durationSec: number = 0.55;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const partials: PartialWave[] = [
      { ratio: 1, amp: 1 },
      { ratio: 2.02, amp: 0.28 }
    ];
    ToneSynthesizerService.addBell(out, 0, 523.25, partials, 0.9, 0.13);
    ToneSynthesizerService.addBell(out, 0.13, 783.99, partials, 0.75, 0.12);
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 上升：柔和的上扬滑音，带一点颤音 */
  private static renderRise(): PcmAudio {
    const durationSec: number = 1.45;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    let phase: number = 0;
    for (let i = 0; i < total; i++) {
      const t: number = i / SYNTH_RATE;
      const progress: number = t / durationSec;
      const freq: number = 330 * Math.pow(2, progress) * (1 + 0.003 * Math.sin(2 * Math.PI * 5.2 * t));
      phase += 2 * Math.PI * freq / SYNTH_RATE;
      const attack: number = Math.min(1, t / 0.06);
      const release: number = Math.min(1, (durationSec - t) / 0.32);
      const env: number = attack * release;
      const value: number = (Math.sin(phase) + 0.14 * Math.sin(phase * 2)) * env;
      out[i] = value;
    }
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 木质：偏马林巴的短促木质音 */
  private static renderWood(): PcmAudio {
    const durationSec: number = 0.85;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const partials: PartialWave[] = [
      { ratio: 1, amp: 1 },
      { ratio: 3.93, amp: 0.22 },
      { ratio: 1.48, amp: 0.12 }
    ];
    ToneSynthesizerService.addBell(out, 0, 392, partials, 0.95, 0.24);
    ToneSynthesizerService.addBell(out, 0.01, 784, partials, 0.35, 0.16);
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 琉璃：低一点的玻璃钟琴，泛音收在 4kHz 内 */
  private static renderGlass(): PcmAudio {
    const durationSec: number = 1.9;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const partials: PartialWave[] = [
      { ratio: 1, amp: 1 },
      { ratio: 2.01, amp: 0.36 },
      { ratio: 2.99, amp: 0.16 },
      { ratio: 4.01, amp: 0.06 }
    ];
    ToneSynthesizerService.addBell(out, 0, 880, partials, 0.9, 0.75);
    ToneSynthesizerService.addBell(out, 0.04, 1174.66, partials, 0.35, 0.55);
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 雨声：柔和的雨幕底噪 + 随机水滴 */
  private static renderRain(): PcmAudio {
    const durationSec: number = 2.0;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const noise: NoiseSource = new NoiseSource(0x51A7);
    const alpha: number = 1 - Math.exp(-2 * Math.PI * 2600 / SYNTH_RATE);
    let low: number = 0;
    for (let i = 0; i < total; i++) {
      low += alpha * (noise.bipolar() - low);
      out[i] = low * 0.42;
    }
    for (let k = 0; k < 22; k++) {
      const start: number = noise.next() * (durationSec - 0.2);
      const freq: number = 650 + noise.next() * 700;
      const amp: number = 0.08 + noise.next() * 0.16;
      const tau: number = 0.025 + noise.next() * 0.045;
      ToneSynthesizerService.addDrop(out, start, 0.12, freq, freq * 0.72, amp, tau, 0.11);
    }
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 风铃：随机五声音阶的短铃，带一点空气声 */
  private static renderWindChime(): PcmAudio {
    const durationSec: number = 2.0;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const noise: NoiseSource = new NoiseSource(0x7C31);
    const notes: number[] = [523.25, 587.33, 659.25, 783.99, 880, 1046.5];
    const partials: PartialWave[] = ToneSynthesizerService.softPartials();
    const alpha: number = 1 - Math.exp(-2 * Math.PI * 1200 / SYNTH_RATE);
    let air: number = 0;
    for (let i = 0; i < total; i++) {
      air += alpha * (noise.bipolar() - air);
      out[i] = air * 0.035;
    }
    for (let k = 0; k < 8; k++) {
      const start: number = noise.next() * (durationSec - 0.75);
      const note: number = notes[Math.floor(noise.next() * notes.length)];
      const amp: number = 0.28 + noise.next() * 0.5;
      const tau: number = 0.5 + noise.next() * 0.55;
      ToneSynthesizerService.addBell(out, start, note, partials, amp, tau);
    }
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 晨鸟：几声轻柔的鸟鸣，底下铺一点清晨微风 */
  private static renderBirds(): PcmAudio {
    const durationSec: number = 2.0;
    const total: number = Math.round(SYNTH_RATE * durationSec);
    const out: Float32Array = new Float32Array(total);
    const noise: NoiseSource = new NoiseSource(0x2D19);
    const alpha: number = 1 - Math.exp(-2 * Math.PI * 900 / SYNTH_RATE);
    let breeze: number = 0;
    for (let i = 0; i < total; i++) {
      breeze += alpha * (noise.bipolar() - breeze);
      out[i] = breeze * 0.06;
    }
    for (let k = 0; k < 4; k++) {
      const start: number = 0.12 + noise.next() * 1.3;
      ToneSynthesizerService.addChirp(out, start, 1900, 2500, 0.07, 0.32);
      ToneSynthesizerService.addChirp(out, start + 0.095, 2200, 2900, 0.06, 0.25);
    }
    return ToneSynthesizerService.pack(out, durationSec);
  }

  /** 柔和的钟琴泛音：基频 + 2/3/4 次泛音，避免高频刺耳 */
  private static softPartials(): PartialWave[] {
    const partials: PartialWave[] = [
      { ratio: 1, amp: 1 },
      { ratio: 2, amp: 0.3 },
      { ratio: 3, amp: 0.11 },
      { ratio: 4.01, amp: 0.045 }
    ];
    return partials;
  }

  /** 在指定时间叠加一个钟琴音 */
  private static addBell(out: Float32Array, startSec: number, f0: number,
    partials: PartialWave[], amp: number, tau: number): void {
    const start: number = Math.round(startSec * SYNTH_RATE);
    const attackFrames: number = Math.round(SYNTH_RATE * 0.008);
    const tail: number = Math.round(SYNTH_RATE * Math.min(2.4, tau * 4));
    for (let i = 0; i < tail; i++) {
      const index: number = start + i;
      if (index < 0 || index >= out.length) {
        continue;
      }
      const local: number = i / SYNTH_RATE;
      const attack: number = Math.min(1, i / attackFrames);
      const env: number = Math.exp(-local / tau) * attack;
      let sample: number = 0;
      for (let p = 0; p < partials.length; p++) {
        const wave: PartialWave = partials[p];
        sample += wave.amp * Math.sin(2 * Math.PI * f0 * wave.ratio * local);
      }
      out[index] += sample * env * amp;
    }
  }

  /** 在指定时间叠加一个下坠水滴 */
  private static addDrop(out: Float32Array, startSec: number, durationSec: number,
    fStart: number, fEnd: number, amp: number, tau: number, tailSec: number): void {
    const start: number = Math.round(startSec * SYNTH_RATE);
    const body: number = Math.round(durationSec * SYNTH_RATE);
    const tail: number = Math.round(tailSec * SYNTH_RATE);
    let phase: number = 0;
    for (let i = 0; i < tail; i++) {
      const index: number = start + i;
      if (index < 0 || index >= out.length) {
        continue;
      }
      const local: number = i / SYNTH_RATE;
      const progress: number = Math.min(1, local / durationSec);
      const freq: number = fStart + (fEnd - fStart) * progress;
      phase += 2 * Math.PI * freq / SYNTH_RATE;
      const env: number = Math.exp(-local / tau);
      const shape: number = i < body ? 1 : Math.max(0, 1 - (i - body) / tail);
      out[index] += Math.sin(phase) * env * shape * amp;
    }
  }

  /** 在指定时间叠加一声短促鸟鸣 */
  private static addChirp(out: Float32Array, startSec: number,
    fStart: number, fEnd: number, durationSec: number, amp: number): void {
    const start: number = Math.round(startSec * SYNTH_RATE);
    const count: number = Math.round(durationSec * SYNTH_RATE);
    let phase: number = 0;
    for (let i = 0; i < count; i++) {
      const index: number = start + i;
      if (index < 0 || index >= out.length) {
        continue;
      }
      const progress: number = i / count;
      const freq: number = fStart + (fEnd - fStart) * progress;
      phase += 2 * Math.PI * freq / SYNTH_RATE;
      const env: number = Math.sin(Math.PI * progress);
      out[index] += Math.sin(phase) * env * amp;
    }
  }

  /** 统一加首尾淡入淡出并归一化，避免爆音和削顶 */
  private static pack(samples: Float32Array, durationSec: number): PcmAudio {
    const fadeFrames: number = Math.round(SYNTH_RATE * 0.006);
    let peak: number = 0;
    for (let i = 0; i < samples.length; i++) {
      const fadeIn: number = Math.min(1, i / fadeFrames);
      const fadeOut: number = Math.min(1, (samples.length - 1 - i) / fadeFrames);
      let value: number = samples[i] * Math.min(fadeIn, fadeOut);
      if (value > 1) {
        value = 1;
      } else if (value < -1) {
        value = -1;
      }
      samples[i] = value;
      if (Math.abs(value) > peak) {
        peak = Math.abs(value);
      }
    }
    if (peak > 0.0001) {
      const scale: number = 0.9 / peak;
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
