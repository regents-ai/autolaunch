"""Original frame-timed sound design. Python standard library, no samples."""
import array
import math
from pathlib import Path
import random
import wave

RATE = 48000
DURATION = 18.4
TAU = math.tau
rng = random.Random(831)
left = [0.0] * int(RATE * DURATION)
right = [0.0] * int(RATE * DURATION)

# Soft harmonic bed, phase reset only behind each crossfade.
for start, root in [(0, 110), (3.75, 130.8128), (7.5, 146.8324), (11.25, 110), (15, 130.8128)]:
    for i in range(int(4.2 * RATE)):
        n = int(start * RATE) + i
        if n >= len(left):
            break
        t = i / RATE
        env = min(1, t / 0.65) * min(1, max(0, (4.2 - t) / 0.8))
        for mult, amp in [(1, 0.022), (2, 0.028), (2.4, 0.018), (3, 0.018)]:
            left[n] += amp * env * math.sin(TAU * root * mult * t)
            right[n] += amp * env * math.sin(TAU * root * mult * 1.0008 * t)

# Transient placement follows the visual edit, not a repetitive stock beat.
for start, frequency, pan in [(0.1, 440, -0.1), (2.8, 220, 0), (4.75, 523.251, 0.15), (5.3, 659.255, -0.3), (6.65, 783.991, 0.3), (8.55, 523.251, -0.2), (9.1, 659.255, 0.2), (12.0, 783.991, 0.2), (15.27, 440, 0), (16.02, 880, 0)]:
    for i in range(int(1.1 * RATE)):
        n = int(start * RATE) + i
        if n >= len(left):
            break
        t = i / RATE
        env = min(1, t / 0.006) * math.exp(-6 * t)
        tone = 0.11 * env * (math.sin(TAU * frequency * t) + 0.2 * math.sin(TAU * frequency * 2 * t))
        left[n] += tone * (1 - pan)
        right[n] += tone * (1 + pan)

# Filtered-noise swooshes under morphs. Fixed seed makes the source repeatable.
for start, duration in [(2.62, 0.43), (3.65, 0.38), (6.55, 0.36), (8.43, 0.48), (11.8, 0.44), (14.96, 0.65)]:
    low = 0.0
    previous = 0.0
    for i in range(int(duration * RATE)):
        n = int(start * RATE) + i
        t = i / RATE
        p = t / duration
        low += (0.1 + p * 0.2) * (rng.uniform(-1, 1) - low)
        band = low - previous * 0.75
        previous = low
        value = band * (math.sin(math.pi * p) ** 2) * 0.1
        left[n] += value * (1.15 - 0.3 * p)
        right[n] += value * (0.85 + 0.3 * p)

peak = max(max(map(abs, left)), max(map(abs, right)))
gain = 0.58 / peak
samples = array.array('h')
for i, (l, r) in enumerate(zip(left, right)):
    t = i / RATE
    fade = min(1, t / 0.12) * min(1, max(0, (DURATION - t) / 1.0))
    samples.extend((round(l * gain * fade * 32767), round(r * gain * fade * 32767)))
if __import__('sys').byteorder != 'little':
    samples.byteswap()
output = Path(__file__).resolve().parent.parent / 'public/assets/launch.wav'
output.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(output), 'wb') as f:
    f.setnchannels(2)
    f.setsampwidth(2)
    f.setframerate(RATE)
    f.writeframes(samples.tobytes())
print(f'Generated {DURATION}s stereo original sound: {output.name}')
