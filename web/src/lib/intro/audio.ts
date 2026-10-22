import { mulberry32 } from './timeline';

/**
 * The brand opening sequence - the score.
 *
 * A port of the archived original's audio module
 * (`docs/opening-sequence/source/intro-overlay.html`, source 572-807): the
 * master chain, the reverb send, and every voice of the composition.
 *
 * The score is a DATA TABLE, not a chain of calls. Every parameter of every
 * voice - its envelope, its filter, its reverb send, its pan - is in the table,
 * because the original's noise beds are not interchangeable with each other:
 * the riser is a band-passed sweep, the ticks are a low-passed click, the
 * handoff chime's noise is a band-passed wash, and each has its own high-pass
 * and its own envelope. A single generic "noise voice" changes the sound.
 *
 * ## Two deliberate departures from the original
 *
 * **The noise is seeded.** The original drew its reverb impulse response and
 * every noise buffer from `Math.random()` (source 602, 610), so its live
 * synthesis was never bit-reproducible - and it was never sample-identical to
 * `intro-theme.wav` either, because that file is the *Python* renderer's output
 * (`render_intro_theme.py`, seeded at line 50) through a hand-rolled RBJ
 * filter, not the browser's `BiquadFilterNode`. Seeding the port's noise makes
 * its render reproducible, which is what lets the oracle compare renders at
 * all. The perceptual difference is nil: it is noise either way.
 *
 * **The score is anchored, not orphaned.** The original scheduled the whole
 * score against `ctx.currentTime + RAMP` (source 782) - and a suspended
 * context's clock does not advance, so the score played in full, from the top,
 * whenever the context eventually resumed, possibly long after the animation
 * had ended. The port anchors the score to the animation's clock instead, and
 * drops it if the animation is over.
 */

export type VoiceKind = 'room' | 'noise' | 'osc' | 'chord' | 'bell' | 'sub' | 'pad' | 'padNoise';

/** The envelope a voice wears. */
export type EnvelopeKind = 'perc' | 'ad' | 'pad' | 'room';

export interface ScoreVoice {
  kind: VoiceKind;
  /** Seconds from the score's own zero. */
  at: number;
  /** How long the voice runs. */
  dur: number;
  peak: number;
  pan: number;
  /** The reverb send (source 617-618). */
  verb: number;
  /** The envelope. */
  env: EnvelopeKind;
  /** The envelope's attack. */
  atk: number;
  /** The envelope's decay, for `perc`. */
  dec?: number;
  /** The envelope's release, for `ad` and `pad`. */
  rel?: number;
  /** The oscillator's fundamental. */
  freq?: number;
  /** Where a sweeping oscillator ends. */
  f1?: number;
  /** A noise voice's band: where it starts and ends. */
  f0?: number;
  /** A noise voice's filter. */
  type?: BiquadFilterType;
  q?: number;
  /** A noise voice's high-pass. Absent for the voices the original builds
   *  inline rather than through `noiseVoice` - the riser is the only one. */
  hp?: number;
  /** Where a noise voice's sweep ends, as a score-time offset. */
  sweepEnd?: number;
  /** A chord's frequencies. */
  freqs?: number[];
  /** A chord's low-pass. */
  lp?: number;
  /** A chord's stereo spread. */
  spread?: number;
  /** A sub's saturation drive. */
  drive?: number;
  /** A bell's FM ratio and index. */
  ratio?: number;
  index?: number;
}

/**
 * The composition, transcribed from the original's `build(t0)` (source 698-776).
 *
 * This is the port's own claim about what it plays. The golden fixture in
 * `score-golden.json` is a second transcription of the same table, and the two
 * agreeing is the evidence that the port plays the score the original composed.
 */
export const SCORE: ScoreVoice[] = [
  /* room tone - a constant bed under everything (source 700-707) */
  {
    kind: 'room', at: 0, dur: 3.0, peak: 0.03, pan: 0, verb: 0, env: 'room',
    atk: 0, f0: 60, f1: 420,
  },
  /* riser - the noise sweep and the sub gliss into the first hit (source 709-716) */
  {
    kind: 'noise', at: 0.12, dur: 0.56, peak: 0.15, pan: 0.3, verb: 0.12, env: 'ad',
    atk: 0.3, rel: 0.54, f0: 200, f1: 6200, type: 'bandpass', q: 1.5,
    // The riser is built INLINE in the original (source 709-714), not through
    // `noiseVoice` - so it has NO high-pass, and its sweep ends at t+0.60
    // rather than at the generic `dur * 0.9`. Giving it a high-pass would
    // thin out the loudest early sound in the score.
    sweepEnd: 0.6,
  },
  {
    kind: 'osc', at: 0.12, dur: 0.5, peak: 0.085, pan: -0.15, verb: 0.1, env: 'ad',
    atk: 0.28, rel: 0.54, freq: 90, f1: 260,
  },
  /* HIT 1 (source 718-726) */
  { kind: 'sub', at: 0.62, dur: 0.38, peak: 0.5, pan: 0, verb: 0.05, env: 'perc', atk: 0.006, dec: 0.38, freq: 58, f1: 38, drive: 1.5 },
  {
    kind: 'chord', at: 0.62, dur: 0.52, peak: 0.15, pan: 0, verb: 0.16, env: 'ad',
    atk: 0.008, rel: 0.52, freqs: [55, 82.4069, 110, 130.8128], lp: 900, spread: 0.14,
  },
  { kind: 'osc', at: 0.62, dur: 0.53, peak: 0.2, pan: 0, verb: 0.15, env: 'perc', atk: 0.006, dec: 0.52, freq: 110 },
  {
    kind: 'noise', at: 0.62, dur: 0.03, peak: 0.03, pan: 0, verb: 0.2, env: 'perc',
    atk: 0.002, dec: 0.03, f0: 300, f1: 240, type: 'lowpass', q: 0.7, hp: 40,
  },
  {
    kind: 'noise', at: 0.62, dur: 0.07, peak: 0.055, pan: 0.2, verb: 0.2, env: 'perc',
    atk: 0.004, dec: 0.045, f0: 7000, f1: 5000, type: 'lowpass', q: 0.7, hp: 3000,
  },
  { kind: 'osc', at: 0.62, dur: 0.7, peak: 0.115, pan: 0, verb: 0.2, env: 'perc', atk: 0.02, dec: 0.78, freq: 46, f1: 40 },
  /* sheen (source 728-729) */
  {
    kind: 'noise', at: 0.74, dur: 0.42, peak: 0.085, pan: -0.25, verb: 0.2, env: 'perc',
    atk: 0.1, dec: 0.34, f0: 2200, f1: 9000, type: 'bandpass', q: 1, hp: 800,
  },
  /* ticks (source 731-734) */
  { kind: 'noise', at: 0.8, dur: 0.012, peak: 0.03, pan: 0.12, verb: 0.2, env: 'perc', atk: 0.001, dec: 0.01, f0: 2600, f1: 2200, type: 'lowpass', q: 0.8, hp: 600 },
  { kind: 'noise', at: 1.24, dur: 0.012, peak: 0.026, pan: -0.12, verb: 0.2, env: 'perc', atk: 0.001, dec: 0.01, f0: 2600, f1: 2200, type: 'lowpass', q: 0.8, hp: 600 },
  { kind: 'noise', at: 1.42, dur: 0.012, peak: 0.022, pan: 0.1, verb: 0.2, env: 'perc', atk: 0.001, dec: 0.01, f0: 2600, f1: 2200, type: 'lowpass', q: 0.8, hp: 600 },
  /* HIT 2 (source 736-745) */
  { kind: 'sub', at: 1.12, dur: 0.9, peak: 0.46, pan: 0, verb: 0.05, env: 'perc', atk: 0.006, dec: 0.9, freq: 84, f1: 55, drive: 1.4 },
  {
    kind: 'chord', at: 1.12, dur: 1.35, peak: 0.15, pan: 0, verb: 0.16, env: 'ad',
    atk: 0.008, rel: 1.35, freqs: [82.4069, 123.4711, 164.8138, 207.6523], lp: 1500, spread: 0.12,
  },
  { kind: 'osc', at: 1.12, dur: 1.38, peak: 0.17, pan: 0, verb: 0.2, env: 'perc', atk: 0.006, dec: 1.35, freq: 164.8138 },
  { kind: 'osc', at: 1.12, dur: 1.38, peak: 0.11, pan: 0.4, verb: 0.2, env: 'perc', atk: 0.006, dec: 1.35, freq: 123.4711 },
  { kind: 'bell', at: 1.12, dur: 1.2, peak: 0.15, pan: -0.18, verb: 0.34, env: 'perc', atk: 0.004, dec: 1.2, freq: 659.2551, ratio: 2, index: 3.2 },
  { kind: 'bell', at: 1.12, dur: 0.95, peak: 0.085, pan: 0.22, verb: 0.34, env: 'perc', atk: 0.004, dec: 0.95, freq: 987.7666, ratio: 2, index: 3.2 },
  {
    kind: 'noise', at: 1.12, dur: 0.07, peak: 0.045, pan: -0.2, verb: 0.2, env: 'perc',
    atk: 0.004, dec: 0.03, f0: 8000, f1: 6000, type: 'lowpass', q: 0.7, hp: 4000,
  },
  /* pad (source 747-759) */
  { kind: 'pad', at: 1.12, dur: 1.88, peak: 0.075, pan: 0, verb: 0.5, env: 'pad', atk: 0.5, rel: 0.45, freq: 110 },
  {
    kind: 'padNoise', at: 1.12, dur: 1.93, peak: 0.03, pan: 0, verb: 0.3, env: 'pad',
    atk: 0.5, rel: 0.45, f0: 1100, type: 'bandpass', q: 0.8,
  },
  /* sparkle (source 761-764) */
  { kind: 'bell', at: 1.58, dur: 0.55, peak: 0.045, pan: 0.35, verb: 0.34, env: 'perc', atk: 0.004, dec: 0.55, freq: 1318.5102, ratio: 2, index: 3 },
  { kind: 'bell', at: 1.66, dur: 0.5, peak: 0.034, pan: -0.4, verb: 0.34, env: 'perc', atk: 0.004, dec: 0.5, freq: 1975.5332, ratio: 2, index: 3 },
  { kind: 'bell', at: 1.74, dur: 0.45, peak: 0.026, pan: 0.1, verb: 0.34, env: 'perc', atk: 0.004, dec: 0.45, freq: 2637.0205, ratio: 2, index: 3 },
  /* handoff chime (source 766-769) */
  { kind: 'bell', at: 2.0, dur: 1.05, peak: 0.13, pan: 0, verb: 0.34, env: 'perc', atk: 0.004, dec: 1.05, freq: 659.2551, ratio: 2, index: 3 },
  { kind: 'bell', at: 2.02, dur: 0.95, peak: 0.09, pan: 0.25, verb: 0.34, env: 'perc', atk: 0.004, dec: 0.95, freq: 987.7666, ratio: 2, index: 3 },
  {
    kind: 'noise', at: 2.0, dur: 0.7, peak: 0.048, pan: 0, verb: 0.2, env: 'perc',
    atk: 0.1, dec: 0.42, f0: 3000, f1: 6500, type: 'bandpass', q: 0.8, hp: 1200,
  },
];

/** The lead-in between the score's zero and the first sample (source 579). */
export const RAMP = 0.12;

/** The seed for the noise. Fixed, so the render is reproducible. */
const NOISE_SEED = 0x1f7a3c;

/**
 * The score's builder, bound to a context.
 *
 * It works on a live `AudioContext` and on an `OfflineAudioContext` alike, so
 * the oracle renders the score with exactly the code that plays it.
 */
export interface ScoreBuilder {
  /**
   * Schedule the score.
   *
   * `base` is the score's ZERO, in the context's clock, and `elapsed` is how
   * many seconds of the animation have already played. A voice at `at` in the
   * score lands at `base + at`.
   *
   * The live caller places `base` at `ctx.currentTime + RAMP - elapsed`,
   * which is exactly where the animation's zero is: the animation's clock
   * starts 120 ms in the future (source 849) and the score is anchored to the
   * same instant (source 782). `RAMP` is not a lead-in for the score - it is
   * what makes the two agree.
   *
   * A voice whose beat has already passed is skipped rather than fired late.
   */
  build(base: number, elapsed: number): void;
  /** Stop everything, with a fade. */
  stop(fade: number): void;
  /** The master gain, for the mute. */
  setMuted(muted: boolean): void;
}

export const createScoreBuilder = (
  ctx: BaseAudioContext,
  destination: AudioNode,
): ScoreBuilder => {
  let master: GainNode;
  let seqBus: GainNode;
  let verbIn: GainNode;
  const nodes: AudioScheduledSourceNode[] = [];
  const buffers = new Map<string, AudioBuffer>();
  let random = mulberry32(NOISE_SEED);

  /* ── the master chain (source 586-596) ────────────────────────────────────── */
  master = ctx.createGain();
  master.gain.value = 1;
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -14;
  comp.knee.value = 10;
  comp.ratio.value = 3.2;
  comp.attack.value = 0.004;
  comp.release.value = 0.25;
  master.connect(comp);
  comp.connect(destination);

  seqBus = ctx.createGain();
  seqBus.gain.value = 1;
  seqBus.connect(master);

  verbIn = ctx.createGain();
  verbIn.gain.value = 1;
  const conv = ctx.createConvolver();
  conv.buffer = makeIR(1.5, 2.6);
  const wet = ctx.createGain();
  wet.gain.value = 0.3;
  verbIn.connect(conv);
  conv.connect(wet);
  wet.connect(master);

  /* ── the noise sources (source 598-612), seeded ──────────────────────────── */
  function makeIR(dur: number, decay: number): AudioBuffer {
    const n = Math.floor(ctx.sampleRate * dur);
    const b = ctx.createBuffer(2, n, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = b.getChannelData(ch);
      let lp = 0;
      for (let i = 0; i < n; i++) {
        const t = i / n;
        lp = lp * 0.72 + (random() * 2 - 1) * 0.28;
        d[i] = lp * Math.pow(1 - t, decay);
      }
    }
    return b;
  }

  function noiseBuffer(dur: number): AudioBuffer {
    const key = dur.toFixed(3);
    const cached = buffers.get(key);
    if (cached) return cached;
    const n = Math.max(1, Math.floor(ctx.sampleRate * dur));
    const b = ctx.createBuffer(2, n, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = b.getChannelData(ch);
      for (let i = 0; i < n; i++) d[i] = random() * 2 - 1;
    }
    buffers.set(key, b);
    return b;
  }

  /* ── the voice helpers (source 613-695) ──────────────────────────────────── */
  const keep = (n: AudioScheduledSourceNode) => {
    nodes.push(n);
    return n;
  };

  const out = (node: AudioNode, panv: number, verb: number) => {
    const p = ctx.createStereoPanner();
    p.pan.value = panv || 0;
    node.connect(p);
    p.connect(seqBus);
    if (verb) {
      const s = ctx.createGain();
      s.gain.value = verb;
      p.connect(s);
      s.connect(verbIn);
    }
  };

  const osc = (
    type: OscillatorType,
    f0: number,
    f1: number,
    rampDur: number,
    when: number,
    stopAt: number,
  ) => {
    const o = ctx.createOscillator();
    o.type = type;
    o.frequency.setValueAtTime(f0, when);
    if (f1 && f1 !== f0) o.frequency.exponentialRampToValueAtTime(f1, when + (rampDur || 0.5));
    o.start(when);
    o.stop(stopAt);
    return o;
  };

  const envPerc = (when: number, attack: number, peak: number, decay: number) => {
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(peak, when + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, when + attack + decay);
    return g;
  };

  const envAD = (when: number, attack: number, peak: number, until: number) => {
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(peak, when + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, when + until);
    return g;
  };

  const envPad = (when: number, attack: number, peak: number, holdAt: number, rel: number) => {
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.linearRampToValueAtTime(peak, when + attack);
    g.gain.setValueAtTime(peak, when + holdAt);
    g.gain.linearRampToValueAtTime(0.0001, when + holdAt + rel);
    return g;
  };

  const noiseSrc = (dur: number, when: number, stopAt: number) => {
    const s = ctx.createBufferSource();
    s.buffer = noiseBuffer(dur);
    s.start(when);
    s.stop(stopAt);
    return s;
  };

  const filt = (type: BiquadFilterType, freq: number, q: number) => {
    const f = ctx.createBiquadFilter();
    f.type = type;
    f.frequency.value = freq;
    f.Q.value = q;
    return f;
  };

  /** The envelope a voice wears (source 625-645). */
  const envelopeFor = (v: ScoreVoice, when: number): GainNode => {
    switch (v.env) {
      case 'perc':
        return envPerc(when, v.atk, v.peak, v.dec ?? v.dur);
      case 'ad':
        return envAD(when, v.atk, v.peak, when + (v.rel ?? v.dur));
      case 'pad':
        return envPad(when, v.atk, v.peak, when + 1.43, v.rel ?? 0.45);
      case 'room':
      default: {
        const g = ctx.createGain();
        g.gain.setValueAtTime(0.0001, when);
        g.gain.linearRampToValueAtTime(v.peak, when + 0.25);
        g.gain.setValueAtTime(v.peak, when + 2.55);
        g.gain.linearRampToValueAtTime(0.0001, when + 3.0);
        return g;
      }
    }
  };

  /** The score's voices (source 698-776). */
  const build = (base: number, elapsed: number) => {
    const when = (at: number) => base + at;
    const pending = SCORE.filter((v) => v.at >= elapsed);

    for (const v of pending) {
      const t = when(v.at);
      switch (v.kind) {
        case 'room': {
          const rt = noiseSrc(v.dur, t, t + v.dur + 0.05);
          const rth = filt('highpass', v.f0 ?? 60, 0.7);
          const rtf = filt('lowpass', v.f1 ?? 420, 0.6);
          const rtg = envelopeFor(v, t);
          rt.connect(rth);
          rth.connect(rtf);
          rtf.connect(rtg);
          out(rtg, v.pan, v.verb);
          break;
        }
        case 'noise': {
          const s = noiseSrc(v.dur, t, t + v.dur + 0.05);
          const f = filt(v.type ?? 'bandpass', v.f0 ?? 200, v.q ?? 1);
          f.frequency.setValueAtTime(v.f0 ?? 200, t);
          if (v.f1 && v.f1 !== v.f0) {
            // The generic path sweeps to `dur * 0.9` (source 689); the voices
            // the original builds inline carry their own end point.
            const sweepTo = v.sweepEnd !== undefined ? v.sweepEnd - v.at : v.dur * 0.9;
            f.frequency.exponentialRampToValueAtTime(v.f1, t + sweepTo);
          }
          let chain: AudioNode = s;
          if (v.hp) {
            const h = filt('highpass', v.hp, 0.7);
            chain.connect(h);
            chain = h;
          }
          chain.connect(f);
          const g = envelopeFor(v, t);
          f.connect(g);
          out(g, v.pan, v.verb);
          break;
        }
        case 'osc': {
          const o = osc('sine', v.freq ?? 220, v.f1 ?? 0, v.dur * 0.8, t, t + v.dur);
          // The ENVELOPE is what reaches the bus. Connecting the oscillator
          // itself would bypass it, and the raw sine would ride on top of the
          // mix at full amplitude.
          const g = envelopeFor(v, t);
          o.connect(g);
          out(g, v.pan, v.verb);
          break;
        }
        case 'chord': {
          const g = envelopeFor(v, t);
          const f = filt('lowpass', v.lp ?? 900, 0.9);
          f.connect(g);
          out(g, v.pan, v.verb);
          const freqs = v.freqs ?? [];
          for (let i = 0; i < freqs.length; i++) {
            const o = osc('sawtooth', freqs[i], 0, 0, t, t + v.dur + 0.05);
            const gg = ctx.createGain();
            gg.gain.value = 1 / freqs.length;
            const p = ctx.createStereoPanner();
            p.pan.value = (i % 2 ? 1 : -1) * (v.spread ?? 0.1);
            o.connect(gg);
            gg.connect(p);
            p.connect(f);
          }
          break;
        }
        case 'sub': {
          const o = osc('sine', v.freq ?? 58, v.f1 ?? 38, v.dur * 0.8, t, t + v.dur + 0.05);
          const w = ctx.createWaveShaper();
          const n = 1024;
          const c = new Float32Array(n);
          for (let i = 0; i < n; i++) {
            const x = (i / (n - 1)) * 2 - 1;
            c[i] = Math.tanh(x * (v.drive ?? 1.5));
          }
          w.curve = c;
          o.connect(w);
          // As with the plain oscillators: the envelope is what reaches the
          // bus, not the saturated signal.
          const g = envelopeFor(v, t);
          w.connect(g);
          out(g, v.pan, v.verb);
          break;
        }
        case 'bell': {
          const car = ctx.createOscillator();
          car.type = 'sine';
          car.frequency.value = v.freq ?? 440;
          const mod = ctx.createOscillator();
          mod.type = 'sine';
          mod.frequency.value = (v.freq ?? 440) * (v.ratio ?? 2);
          const mg = ctx.createGain();
          mg.gain.setValueAtTime((v.freq ?? 440) * (v.index ?? 3.2), t);
          mg.gain.exponentialRampToValueAtTime((v.freq ?? 440) * 0.02, t + v.dur * 0.85);
          mod.connect(mg);
          mg.connect(car.frequency);
          const g = envelopeFor(v, t);
          car.connect(g);
          out(g, v.pan, v.verb);
          car.start(t);
          car.stop(t + v.dur + 0.06);
          mod.start(t);
          mod.stop(t + v.dur + 0.06);
          keep(car);
          keep(mod);
          break;
        }
        case 'pad': {
          const holdAt = when(2.55);
          const rel = v.rel ?? 0.45;
          const pg = envPad(t, v.atk, v.peak, holdAt, rel);
          const pf = filt('lowpass', 700, 0.8);
          pf.connect(pg);
          out(pg, v.pan, v.verb);
          const padF = [110, 164.8138, 220, 261.6256];
          const det = [0, -7, 6, -5];
          for (let i = 0; i < padF.length; i++) {
            const po = osc(
              'sawtooth',
              padF[i] * Math.pow(2, det[i] / 1200),
              0,
              0,
              t,
              holdAt + rel + 0.05,
            );
            const pgg = ctx.createGain();
            pgg.gain.value = 0.25;
            po.connect(pgg);
            pgg.connect(pf);
          }
          break;
        }
        case 'padNoise': {
          const holdAt = when(2.55);
          const rel = v.rel ?? 0.45;
          const pa = noiseSrc(v.dur, t, holdAt + rel + 0.05);
          const paf = filt(v.type ?? 'bandpass', v.f0 ?? 1100, v.q ?? 0.8);
          const pag = envPad(t, v.atk, v.peak, holdAt, rel);
          pa.connect(paf);
          paf.connect(pag);
          out(pag, v.pan, v.verb);
          break;
        }
      }
    }

    // The master fade to silence as the UI takes over (source 771-775).
    seqBus.gain.cancelScheduledValues(when(0));
    seqBus.gain.setValueAtTime(1, when(0));
    seqBus.gain.setValueAtTime(1, when(2.75));
    seqBus.gain.linearRampToValueAtTime(0.0001, when(3.0));
  };

  const stop = (fade: number) => {
    const now = ctx.currentTime;
    const f = fade == null ? 0.06 : fade;
    try {
      seqBus.gain.cancelScheduledValues(now);
      seqBus.gain.setValueAtTime(seqBus.gain.value, now);
      seqBus.gain.linearRampToValueAtTime(0.0001, now + f);
    } catch {
      /* the context may already be closed */
    }
    for (const n of nodes) {
      try {
        n.stop(now + f + 0.02);
      } catch {
        /* already stopped */
      }
    }
    nodes.length = 0;
  };

  return {
    build,
    stop,
    setMuted(muted: boolean) {
      master.gain.setTargetAtTime(muted ? 0.0001 : 1, ctx.currentTime, 0.02);
    },
  };
};

/**
 * The live score.
 *
 * It owns the `AudioContext`, and it is deliberately the ONLY thing in the app
 * that touches the audio. The renderer never sees it, which is what makes the
 * animation provably unblocked by a suspended `AudioContext`.
 */
export class IntroScore {
  private ctx: AudioContext | null = null;
  private builder: ScoreBuilder | null = null;
  private muted = false;
  private started = false;

  /** The context's state, for the overlay's decisions. */
  get state(): AudioContextState | 'none' {
    return this.ctx ? this.ctx.state : 'none';
  }

  get isMuted(): boolean {
    return this.muted;
  }

  get hasStarted(): boolean {
    return this.started;
  }

  /**
   * Start the score.
   *
   * `elapsed` is how far the animation has already played, so the score can be
   * anchored to the animation's clock. If the context is suspended the score is
   * NOT scheduled: it waits for the first gesture, and if the animation is over
   * by then it is dropped rather than orphaned.
   *
   * Returns true if the score was scheduled.
   */
  start(elapsed = 0): boolean {
    if (this.started) return true;
    const w =
      typeof window === 'undefined'
        ? undefined
        : (window as unknown as {
            AudioContext?: typeof AudioContext;
            webkitAudioContext?: typeof AudioContext;
          });
    const AC = w?.AudioContext ?? w?.webkitAudioContext;
    if (!AC) return false; // no Web Audio: the animation carries on regardless
    if (!this.ctx) {
      this.ctx = new AC();
      this.builder = createScoreBuilder(this.ctx, this.ctx.destination);
    }
    if (this.ctx.state === 'suspended') {
      // A suspended context's clock does not advance, so scheduling now would
      // freeze the score rather than play it. It waits for a gesture.
      return false;
    }
    this.builder?.build(this.ctx.currentTime + RAMP - elapsed, elapsed);
    this.started = true;
    return true;
  }

  /**
   * The context was resumed. If the animation is still running the score
   * starts now, anchored to the animation's position; if the animation is over
   * the score is dropped.
   */
  onResumed(elapsed: number | null): boolean {
    if (!this.ctx || !this.builder) return false;
    if (this.started) return true;
    if (elapsed === null) return false; // the animation is over: drop the score
    this.builder.build(this.ctx.currentTime + RAMP - elapsed, elapsed);
    this.started = true;
    return true;
  }

  /** Resume the context, if it is suspended. */
  async resume(): Promise<void> {
    if (!this.ctx) return;
    if (this.ctx.state === 'suspended') {
      try {
        await this.ctx.resume();
      } catch {
        /* the browser refused; the animation does not care */
      }
    }
  }

  /** Stop the score, with a fade. */
  stop(fade = 0.1): void {
    this.builder?.stop(fade);
    this.started = false;
  }

  setMuted(muted: boolean): void {
    this.muted = muted;
    this.builder?.setMuted(muted);
  }

  toggleMute(): boolean {
    this.setMuted(!this.muted);
    return this.muted;
  }
}

/**
 * Render the score offline, for the oracle.
 *
 * The same builder, the same seeded noise, the same composition - rendered
 * into an `OfflineAudioContext` so the result is a buffer that can be measured
 * rather than listened to.
 *
 * `base` is where the score's zero lands in the rendered buffer. The live
 * caller uses `ctx.currentTime + RAMP`, so an offline render that is to be
 * compared with the live original's must use `RAMP` too; one that is to be
 * compared with `intro-theme.wav` (whose zero is at the buffer's start) must
 * use `0`.
 */
export const renderScoreOffline = async (
  sampleRate = 44100,
  duration = 3.1,
  base = RAMP,
): Promise<AudioBuffer> => {
  const ctx = new OfflineAudioContext(2, Math.floor(sampleRate * duration), sampleRate);
  const builder = createScoreBuilder(ctx, ctx.destination);
  builder.build(base, 0);
  return ctx.startRendering();
};
