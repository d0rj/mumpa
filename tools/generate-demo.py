"""Reproducible original demo music. No external recordings or downloads."""
import math
import struct
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "assets" / "demo"
OUT.mkdir(parents=True, exist_ok=True)
RATE = 22050
for index, (name, root) in enumerate([("01 - First light.wav", 220), ("02 - Slow orbit.wav", 196), ("03 - After hours.wav", 174.614)]):
    # Keep the WAV payload intact; .bin avoids Android's WAV no-compress rule.
    with wave.open(str(OUT / (name + ".bin")), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        frames = bytearray()
        duration = 24
        for sample in range(RATE * duration):
            t = sample / RATE
            chord = [1, 1.25, 1.5, 2][int(t / 3) % 4]
            fade = min(1, t / 2, (duration - t) / 3)
            pad = sum(math.sin(2 * math.pi * root * ratio * t + index) for ratio in [1, 1.25, 1.5]) * .11
            pulse = math.exp(-((t * 2) % 1) * 7) * math.sin(2 * math.pi * root * chord * 2 * t) * .10
            bass = math.sin(2 * math.pi * root / 2 * t) * .13
            left = int(32767 * fade * (pad + pulse + bass))
            right = int(32767 * fade * (pad * .9 + pulse + bass))
            frames.extend(struct.pack("<hh", left, right))
        audio.writeframes(frames)
print("Generated 3 original 24-second demo tracks")
