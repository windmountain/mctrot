#!/usr/bin/env python3
"""McTrot radio's holding loop: ten seconds of lounge music, synthesized.

    holding.py out.wav

Played on repeat before the show and after it (station/program.liq), so
it's made to loop without a seam: four bars at 96 BPM, exactly 10 s, with
every note's tail and echo wrapped round to the start.

- Electric piano (two-operator FM, a tine): Fmaj7, Em7, Dm7, Cmaj7, hit on
  the one and pushed on the and-of-two, with a tremolo that pans.
- Bass on the root, a soft kick on one and three, a quiet shaker on the
  off-beats.
- A bell (FM at 3.5:1) plays a small phrase over bars one and three,
  through a dotted-eighth echo.

host/radio.nix runs this when the box is built. Python's standard library
only; deterministic (the shaker's noise is seeded).
"""

import array
import math
import random
import sys
import wave

RATE = 44100
BPM = 96
BEAT = 60 / BPM  # 0.625 s
BAR = 4 * BEAT  # 2.5 s
LENGTH = 4 * BAR  # 10 s
FRAMES = round(LENGTH * RATE)
TAIL = 4.0  # seconds rendered past the end, then wrapped round

TAU = 2 * math.pi


def hz(midi):
    return 440 * 2 ** ((midi - 69) / 12)


class Mix:
    """A stereo buffer longer than the loop; `looped` folds the overhang back."""

    def __init__(self):
        n = FRAMES + round(TAIL * RATE)
        self.left = [0.0] * n
        self.right = [0.0] * n

    def add(self, start, samples, pan=0.0, gain=1.0):
        """Mono samples at `start` seconds; pan -1 (left) to 1 (right)."""
        lg = gain * math.cos((pan + 1) * math.pi / 4) * math.sqrt(2)
        rg = gain * math.sin((pan + 1) * math.pi / 4) * math.sqrt(2)
        i0 = round(start * RATE)
        for i, s in enumerate(samples):
            j = i0 + i
            if j >= len(self.left):
                break
            self.left[j] += s * lg
            self.right[j] += s * rg

    def add_stereo(self, start, left, right, gain=1.0):
        i0 = round(start * RATE)
        for i, (l, r) in enumerate(zip(left, right)):
            j = i0 + i
            if j >= len(self.left):
                break
            self.left[j] += l * gain
            self.right[j] += r * gain

    def looped(self):
        left, right = self.left[:FRAMES], self.right[:FRAMES]
        for j in range(FRAMES, len(self.left)):
            left[j % FRAMES] += self.left[j]
            right[j % FRAMES] += self.right[j]
        return left, right


def envelope(t, attack, decay):
    if t < attack:
        return t / attack
    return math.exp(-(t - attack) / decay)


def tine(freq, seconds, velocity, detune_cents=0.0):
    """An electric piano note: FM with a 1:1 modulator whose index fades."""
    f = freq * 2 ** (detune_cents / 1200)
    out = []
    for i in range(round(seconds * RATE)):
        t = i / RATE
        index = 1.4 * velocity * math.exp(-t / 0.35) + 0.15
        s = math.sin(TAU * f * t + index * math.sin(TAU * f * t))
        # A little bark at the start: the second partial, quickly gone.
        s += 0.25 * velocity * math.exp(-t / 0.08) * math.sin(TAU * 2 * f * t)
        out.append(s * envelope(t, 0.004, 1.6) * velocity)
    return out


def bell(freq, seconds, velocity):
    out = []
    for i in range(round(seconds * RATE)):
        t = i / RATE
        index = 2.2 * math.exp(-t / 0.5)
        s = math.sin(TAU * freq * t + index * math.sin(TAU * 3.5 * freq * t))
        out.append(s * envelope(t, 0.002, 0.9) * velocity)
    return out


def bass(freq, seconds, velocity):
    out = []
    for i in range(round(seconds * RATE)):
        t = i / RATE
        s = math.sin(TAU * freq * t) + 0.3 * math.sin(TAU * 2 * freq * t) * math.exp(-t / 0.3)
        # Let go cleanly at the note's end.
        release = min(1.0, (seconds - t) / 0.05)
        out.append(s * envelope(t, 0.01, 0.9) * release * velocity)
    return out


def kick(velocity):
    out, phase = [], 0.0
    for i in range(round(0.35 * RATE)):
        t = i / RATE
        f = 45 + 60 * math.exp(-t / 0.04)
        phase += TAU * f / RATE
        out.append(math.sin(phase) * math.exp(-t / 0.12) * velocity)
    return out


def shaker(rng, velocity):
    out, previous = [], 0.0
    for i in range(round(0.09 * RATE)):
        t = i / RATE
        noise = rng.uniform(-1, 1)
        # First difference: a crude high-pass, so it hisses rather than rumbles.
        s, previous = noise - previous, noise
        out.append(s * envelope(t, 0.012, 0.025) * velocity)
    return out


def main(path):
    rng = random.Random(21)  # November 21
    mix = Mix()

    chords = [
        (41, [53, 57, 60, 64, 69]),  # Fmaj7 (add the 3rd on top)
        (40, [52, 55, 59, 62, 67]),  # Em7
        (38, [50, 53, 57, 60, 65]),  # Dm7
        (36, [48, 52, 55, 59, 64]),  # Cmaj7
    ]

    for bar, (root, notes) in enumerate(chords):
        start = bar * BAR
        # Electric piano: on the one, then pushed on the and-of-two, softer.
        for hit, velocity, length in [(0, 0.55, 1.6), (1.5 * BEAT, 0.38, 2.2)]:
            for k, note in enumerate(notes):
                # Spread the voicing a little across the stereo field, and
                # roll the chord upward by a few milliseconds.
                pan = -0.35 + 0.7 * k / (len(notes) - 1)
                mix.add(start + hit + 0.006 * k, tine(hz(note), length, velocity, detune_cents=(k - 2) * 1.5), pan=pan, gain=0.13)
        # Bass: the root on the one, and again on the and-of-three.
        mix.add(start, bass(hz(root), 1.5 * BEAT, 0.9), gain=0.32)
        mix.add(start + 2.5 * BEAT, bass(hz(root + 12 if bar % 2 else root), 1.4 * BEAT, 0.7), gain=0.32)
        # Soft kick on one and three.
        for beat in (0, 2):
            mix.add(start + beat * BEAT, kick(0.8), gain=0.35)
        # Shaker on every off-beat, panned right, with a little swing.
        for beat in range(4):
            mix.add(start + (beat + 0.56) * BEAT, shaker(rng, 1.0), pan=0.45, gain=0.05)

    # The bell's phrase, over bars one and three: (bar, beat, note).
    phrase = [
        (0, 0.0, 81), (0, 1.5, 84), (0, 2.5, 79), (0, 3.0, 76),
        (2, 0.0, 77), (2, 1.0, 81), (2, 1.5, 84), (2, 3.0, 79),
    ]
    dry = Mix()
    for bar, beat, note in phrase:
        dry.add(bar * BAR + beat * BEAT, bell(hz(note), 1.6, 0.8), pan=-0.15, gain=0.09)
    bell_left, bell_right = dry.looped()
    # The echo: a dotted eighth, ping-ponging, fading. On the looped bell, so
    # it carries round the end too.
    delay = round(0.75 * BEAT * RATE)
    echo_left, echo_right = bell_left[:], bell_right[:]
    for _ in range(2):  # twice round, so the feedback wraps cleanly
        for j in range(FRAMES):
            echo_left[j] = bell_left[j] + 0.38 * echo_right[(j - delay) % FRAMES]
            echo_right[j] = bell_right[j] + 0.38 * echo_left[(j - delay) % FRAMES]
    left, right = mix.looped()
    left = [a + b for a, b in zip(left, echo_left)]
    right = [a + b for a, b in zip(right, echo_right)]

    # The tremolo: a gentle pan wobble at eighth notes (32 times round in
    # the 10 s, so it loops too), on everything.
    for j in range(FRAMES):
        wobble = 0.08 * math.sin(TAU * 3.2 * j / RATE)
        left[j] *= 1 - wobble
        right[j] *= 1 + wobble

    # Soft-clip, then bring the peak to -3 dBFS.
    left = [math.tanh(s) for s in left]
    right = [math.tanh(s) for s in right]
    peak = max(max(map(abs, left)), max(map(abs, right)))
    scale = 10 ** (-3 / 20) / peak * 32767
    pcm = array.array("h")
    for l, r in zip(left, right):
        pcm.append(round(l * scale))
        pcm.append(round(r * scale))
    if sys.byteorder != "little":
        pcm.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    main(sys.argv[1])
