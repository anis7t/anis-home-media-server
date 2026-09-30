#!/usr/bin/env python3
"""
Render the "Anis' Home Media Server" opening title theme to a stereo WAV file.

Fully original composition -- nothing sampled, nothing licensed:
  room tone -> riser -> HIT 1 (A-minor impact) -> sheen -> HIT 2 (E-major lift)
  -> sustained pad -> sparkle -> handoff chime -> room tone out.

Pure standard library (wave / array / math / random) so it runs anywhere.
The Web Audio version embedded in intro.html mirrors this design 1:1, so the
browser demo and this rendered asset sound the same.

Usage:
    python render_intro_theme.py                 # -> intro-theme.wav (7.0 s, 44.1 kHz)
    python render_intro_theme.py --out x.wav --gain 0.85
"""
from __future__ import annotations

import argparse
import math
import random
import wave
from array import array

SR = 44100

# ---------------------------------------------------------------- timeline (s)
# The whole sequence is 3.00 s -- the visible animation ends at T_SEQ_END.
T_SEQ_END = 3.00    # animation end (app takes over)
T_ROOM_END = 3.00   # room tone fades out here
T_RISER = 0.12
T_HIT1 = 0.62
T_SHEEN = 0.74
T_TICK1 = 0.80      # wordmark 1
T_HIT2 = 1.12       # wordmark 2 + note 2
T_TICK2 = 1.24      # subtitle
T_TICK3 = 1.42      # rule
T_PAD = 1.12
T_PAD_REL = 2.55     # the pad holds under the reveal, then releases into the tail
T_SPARKLE = 1.58
T_CHIME = 2.00      # handoff
T_END = 3.05        # file length (50 ms tail past the animation)

# ------------------------------------------------------------------ note table
A1, E2, A2, C3 = 55.00, 82.4069, 110.00, 130.8128
B2, E3, GS3 = 123.4711, 164.8138, 207.6523
A3, C4 = 220.00, 261.6256
E5, B5, E6, B6, E7 = 659.2551, 987.7666, 1318.5102, 1975.5332, 2637.0205

random.seed(20260928)

L: list[float] = [0.0] * int(SR * (T_END + 0.02))
R: list[float] = [0.0] * int(SR * (T_END + 0.02))


# ------------------------------------------------------------------ envelopes
def env_perc(decay: float):
    return lambda t: math.exp(-decay * t)


def env_ad(attack: float, decay: float):
    def f(t: float) -> float:
        a = min(1.0, t / attack) if attack > 0 else 1.0
        return a * math.exp(-decay * max(0.0, t - attack))
    return f


def env_pad(attack: float, rel_start: float, release: float):
    def f(t: float) -> float:
        if t < attack:
            return t / attack
        if t < rel_start:
            return 1.0
        return max(0.0, 1.0 - (t - rel_start) / release)
    return f


def env_room(fade_in: float, fade_out_at: float, fade_out: float, dur: float):
    def f(t: float) -> float:
        a = min(1.0, t / fade_in) if fade_in > 0 else 1.0
        b = 1.0 if t < fade_out_at else max(0.0, 1.0 - (t - fade_out_at) / fade_out)
        return a * b
    return f


# ------------------------------------------------------------------- waveform
def sine_sweep(f0: float, f1: float, dur: float, phase: float = 0.0):
    """Exponential glide f0 -> f1 over dur; phase = integral of f(t)."""
    if abs(f1 - f0) < 1e-9:
        return lambda t: math.sin(2.0 * math.pi * f0 * t + phase)
    k = math.log(f1 / f0) / dur
    return lambda t: math.sin(2.0 * math.pi * f0 * (math.exp(k * t) - 1.0) / k + phase)


def sine_f(freq: float, phase: float = 0.0):
    return lambda t: math.sin(2.0 * math.pi * freq * t + phase)


def saw_f(freq: float, detune_cents: float = 0.0):
    f = freq * (2.0 ** (detune_cents / 1200.0))
    return lambda t: 2.0 * ((f * t) % 1.0) - 1.0


def tri_f(freq: float, detune_cents: float = 0.0):
    f = freq * (2.0 ** (detune_cents / 1200.0))

    def g(t: float) -> float:
        x = (f * t) % 1.0
        return 4.0 * abs(x - 0.5) - 1.0
    return g


def sat(x: float, drive: float = 1.6) -> float:
    return math.tanh(x * drive)


# --------------------------------------------------------- filtered noise beds
def filtered_noise(dur: float, f_start: float, f_end: float,
                   q: float = 1.4, hp: float = 100.0) -> list[float]:
    """White noise -> resonant 2-pole lowpass sweep (blockwise RBJ) -> 1-pole HP."""
    n = int(dur * SR)
    src = [random.uniform(-1.0, 1.0) for _ in range(n)]
    out = [0.0] * n
    x1 = x2 = y1 = y2 = 0.0
    block = 64
    hp_a = 1.0 / (1.0 + 2.0 * math.pi * hp / SR)
    hx1 = hy1 = 0.0
    for start in range(0, n, block):
        frac = start / max(1, n - 1)
        fc = f_start * ((f_end / f_start) ** frac)
        w0 = 2.0 * math.pi * fc / SR
        cw, sw = math.cos(w0), math.sin(w0)
        alpha = sw / (2.0 * q)
        b0 = (1.0 - cw) / 2.0
        b1 = 1.0 - cw
        b2 = b0
        a0 = 1.0 + alpha
        a1 = -2.0 * cw
        a2 = 1.0 - alpha
        nb0, nb1, nb2 = b0 / a0, b1 / a0, b2 / a0
        na1, na2 = a1 / a0, a2 / a0
        for i in range(start, min(start + block, n)):
            x = src[i]
            y = nb0 * x + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            x2, x1 = x1, x
            y2, y1 = y1, y
            hy = hp_a * (hy1 + y - hx1)
            hx1, hy1 = y, hy
            out[i] = hy
    return out


# ------------------------------------------------------------------ voice mixer
def add(t0: float, dur: float, gen, env, pan: float = 0.0, peak: float = 1.0,
        drive: float = 0.0) -> None:
    n = int(dur * SR)
    i0 = int(t0 * SR)
    if i0 >= len(L) or n <= 0:
        return
    n = min(n, len(L) - i0)
    gl = math.cos((pan + 1.0) * math.pi / 4.0)
    gr = math.sin((pan + 1.0) * math.pi / 4.0)
    for i in range(n):
        t = i / SR
        s = gen(t) * env(t) * peak
        if drive:
            s = sat(s, drive)
        L[i0 + i] += s * gl
        R[i0 + i] += s * gr


def add_samples(t0: float, samples: list[float], env, pan: float = 0.0,
                peak: float = 1.0) -> None:
    i0 = int(t0 * SR)
    if i0 >= len(L):
        return
    n = min(len(samples), len(L) - i0)
    gl = math.cos((pan + 1.0) * math.pi / 4.0)
    gr = math.sin((pan + 1.0) * math.pi / 4.0)
    for i in range(n):
        t = i / SR
        s = samples[i] * env(t) * peak
        L[i0 + i] += s * gl
        R[i0 + i] += s * gr


def bell(t0: float, freq: float, dur: float, peak: float, pan: float = 0.0,
         ratio: float = 2.0, index: float = 3.0, decay: float = 3.2) -> None:
    """FM bell: carrier sine + decaying modulator -> percussive, glassy."""
    def gen(t: float) -> float:
        m = math.sin(2.0 * math.pi * freq * ratio * t) * index * math.exp(-decay * 0.55 * t)
        return math.sin(2.0 * math.pi * freq * t + m)
    add(t0, dur, gen, env_perc(decay), pan=pan, peak=peak)


# =====================================================================  BUILD
# 1. room tone -------------------------------------------------------------
room = filtered_noise(T_ROOM_END, 420.0, 420.0, q=0.6, hp=60.0)
add_samples(0.0, room, env_room(0.25, 2.55, 0.45, T_ROOM_END), pan=0.0, peak=0.030)

# 2. riser (noise sweep + sub gliss) ---------------------------------------
riser = filtered_noise(T_HIT1 - T_RISER + 0.04, 200.0, 6200.0, q=1.5, hp=120.0)
add_samples(T_RISER, riser, env_ad(0.30, 1.5), pan=0.30, peak=0.150)
add(T_RISER, T_HIT1 - T_RISER + 0.03, sine_sweep(90.0, 260.0, T_HIT1 - T_RISER),
    env_ad(0.28, 1.7), pan=-0.15, peak=0.085)

# 3. HIT 1 -- the "ta" ------------------------------------------------------
add(T_HIT1, 0.45, sine_sweep(58.0, 38.0, 0.38), env_perc(10.0), peak=0.500, drive=1.5)
for f, d, p in ((A1, 0.0, 0.16), (E2, 4.0, 0.13), (A2, -3.0, 0.10), (C3, 6.0, 0.085)):
    add(T_HIT1, 0.52, saw_f(f, d), env_ad(0.006, 7.0), pan=(d / 30.0), peak=p)
add(T_HIT1, 0.52, sine_f(A2), env_perc(7.5), peak=0.20)
click = filtered_noise(0.030, 300.0, 240.0, q=0.7, hp=40.0)
add_samples(T_HIT1, click, env_perc(90.0), peak=0.30)
air1 = filtered_noise(0.07, 7000.0, 5000.0, q=0.7, hp=3000.0)
add_samples(T_HIT1, air1, env_perc(48.0), pan=0.2, peak=0.055)
add(T_HIT1, 0.78, sine_sweep(46.0, 40.0, 0.70), env_perc(4.6), peak=0.115)   # whump tail

# 4. sheen sweep (syncs with the specular pass over the logo) ---------------
sheen = filtered_noise(0.42, 2200.0, 9000.0, q=1.0, hp=800.0)
add_samples(T_SHEEN, sheen, env_ad(0.12, 5.2), pan=-0.25, peak=0.085)

# 5. micro ticks (wordmark / subtitle / rule) -------------------------------
for t_tick, pk in ((T_TICK1, 0.030), (T_TICK2, 0.026), (T_TICK3, 0.022)):
    tick = filtered_noise(0.010, 2600.0, 2200.0, q=0.8, hp=600.0)
    add_samples(t_tick, tick, env_perc(320.0), peak=pk)

# 6. HIT 2 -- the "dum" (a fifth up, major, brighter) -----------------------
add(T_HIT2, 1.00, sine_sweep(84.0, 55.0, 0.90), env_perc(3.6), peak=0.460, drive=1.4)
for f, d, p in ((E2, 0.0, 0.150), (B2, 5.0, 0.115), (E3, -4.0, 0.095), (GS3, 7.0, 0.070)):
    add(T_HIT2, 1.35, saw_f(f, d), env_ad(0.008, 2.6), pan=(d / 26.0), peak=p)
add(T_HIT2, 1.35, sine_f(E3), env_perc(3.0), peak=0.17)
add(T_HIT2, 1.35, sine_f(B2, 0.4), env_perc(3.2), peak=0.11)
bell(T_HIT2, E5, 1.20, 0.150, pan=-0.18, decay=4.6)
bell(T_HIT2, B5, 0.95, 0.085, pan=0.22, decay=5.2)
air2 = filtered_noise(0.07, 8000.0, 6000.0, q=0.7, hp=4000.0)
add_samples(T_HIT2, air2, env_perc(55.0), pan=-0.2, peak=0.045)

# 7. sustained pad (A-minor -> holds under the lockup) ----------------------
pad_env = env_pad(0.50, T_PAD_REL - T_PAD, 0.45)
for f, d, p in ((A2, 0.0, 0.075), (E3, -7.0, 0.060), (A3, 6.0, 0.045), (C4, -5.0, 0.038)):
    add(T_PAD, (T_PAD_REL - T_PAD) + 0.50, saw_f(f, d), pad_env, pan=(d / 18.0), peak=p)
add(T_PAD, (T_PAD_REL - T_PAD) + 0.50, sine_f(A2, 0.2), pad_env, peak=0.055)
pad_air = filtered_noise((T_PAD_REL - T_PAD) + 0.48, 900.0, 1400.0, q=0.8, hp=200.0)
add_samples(T_PAD, pad_air, pad_env, pan=0.0, peak=0.030)

# 8. sparkle dust (settle) --------------------------------------------------
bell(T_SPARKLE, E6, 0.55, 0.045, pan=0.35, decay=5.0)
bell(T_SPARKLE + 0.08, B6, 0.50, 0.034, pan=-0.40, decay=5.4)
bell(T_SPARKLE + 0.16, E7, 0.45, 0.026, pan=0.10, decay=5.8)

# 9. handoff chime ----------------------------------------------------------
bell(T_CHIME, E5, 1.05, 0.130, pan=0.0, decay=4.2)
bell(T_CHIME + 0.02, B5, 0.95, 0.090, pan=0.25, decay=4.6)
chime_air = filtered_noise(0.70, 3000.0, 6500.0, q=0.8, hp=1200.0)
add_samples(T_CHIME, chime_air, env_ad(0.12, 4.5), pan=0.0, peak=0.048)


# ==============================================================  FINALIZE
FADE_AT = T_SEQ_END - 0.25   # master fade-out begins here
FADE_END = T_END


def finalize(out_path: str, gain: float) -> None:
    peak = 0.0
    for i in range(len(L)):
        a = abs(L[i])
        b = abs(R[i])
        if a > peak:
            peak = a
        if b > peak:
            peak = b
    scale = (gain / peak) if peak > 0 else 1.0

    # soft ceiling so nothing ever clips digitally
    data = array("h")
    rms_acc = 0.0
    n = len(L)
    for i in range(n):
        t = i / SR
        if t <= FADE_AT:
            fade = 1.0
        elif t >= FADE_END:
            fade = 0.0
        else:
            x = (t - FADE_AT) / (FADE_END - FADE_AT)
            fade = 0.5 + 0.5 * math.cos(math.pi * x)   # raised-cosine fade
        sl = math.tanh(L[i] * scale * 1.02) * 0.985 * fade
        sr = math.tanh(R[i] * scale * 1.02) * 0.985 * fade
        rms_acc += sl * sl + sr * sr
        data.append(int(max(-32767, min(32767, sl * 32767))))
        data.append(int(max(-32767, min(32767, sr * 32767))))

    with wave.open(out_path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())

    rms = math.sqrt(rms_acc / (2 * n)) if n else 0.0
    print(f"wrote {out_path}")
    print(f"  duration : {n / SR:.2f} s @ {SR} Hz stereo 16-bit")
    print(f"  sequence : {T_SEQ_END:.2f} s animation + {T_END - T_SEQ_END:.2f} s tail")
    print(f"  pre-peak : {peak:.4f}   applied gain x{scale:.3f}")
    print(f"  peak     : {gain:.3f} (~{20 * math.log10(max(gain, 1e-9)):.2f} dBFS)")
    print(f"  rms      : {rms:.4f} (~{20 * math.log10(max(rms, 1e-9)):.2f} dBFS)")
    print(f"  bytes    : {len(data) * 2}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Render the media-server intro theme.")
    ap.add_argument("--out", default="intro-theme.wav")
    ap.add_argument("--gain", type=float, default=0.89, help="target peak 0..1")
    args = ap.parse_args()
    finalize(args.out, args.gain)
