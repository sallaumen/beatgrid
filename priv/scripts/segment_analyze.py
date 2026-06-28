#!/usr/bin/env python3
"""Segment a recorded DJ mix into tracks and analyze each one.

Usage: segment_analyze.py <audio_path> [<boundaries_json>]
  boundaries_json: JSON array of start-ms ints. If absent/empty, boundaries are
  auto-detected from the audio (agglomerative clustering over a CQT).

Output (stdout): JSON array of {start_ms, end_ms, bpm, key, mode}. BPM/key are
computed on the inner 20%-85% of each segment to avoid blended transition edges;
segments too short to analyze get null bpm/key/mode.
"""
import sys
import json
import numpy as np
import librosa

# Krumhansl-Schmuckler profiles (same as analyze.py).
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def best_key(profile, chroma_mean):
    cors = [np.corrcoef(np.roll(profile, i), chroma_mean)[0, 1] for i in range(12)]
    i = int(np.argmax(cors))
    return i, cors[i]


def analyze_window(y, sr):
    tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
    bpm = round(float(np.atleast_1d(tempo)[0]), 2)
    # beat_track returns 0.0 on segments with no detectable beat (fades/ambient) —
    # report that as "unknown" (null) rather than a misleading 0 BPM.
    bpm = None if bpm == 0.0 else bpm
    chroma_mean = librosa.feature.chroma_cqt(y=y, sr=sr).mean(axis=1)
    maj_i, maj_c = best_key(MAJOR, chroma_mean)
    min_i, min_c = best_key(MINOR, chroma_mean)
    if maj_c >= min_c:
        return bpm, maj_i, 1
    return bpm, min_i, 0


def detect_boundaries(y, sr, dur_ms):
    # ~one segment per 4 minutes as a heuristic count, clamped to [2, 40].
    n = max(2, min(40, round(dur_ms / 1000 / 240)))
    cqt = np.abs(librosa.cqt(y=y, sr=sr))
    frames = librosa.segment.agglomerative(cqt, n)
    times = librosa.frames_to_time(frames, sr=sr)
    return [int(t * 1000) for t in times]


def main():
    path = sys.argv[1]
    boundaries = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else []

    y, sr = librosa.load(path, mono=True)
    dur_ms = int(len(y) / sr * 1000)

    if not boundaries:
        boundaries = detect_boundaries(y, sr, dur_ms)

    starts = sorted(set([0] + [b for b in boundaries if 0 < b < dur_ms]))

    segs = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else dur_ms
        inner_a = start + int((end - start) * 0.20)
        inner_b = start + int((end - start) * 0.85)
        ys = y[int(inner_a / 1000 * sr): int(inner_b / 1000 * sr)]
        if len(ys) < sr:  # < 1s of audio: too short to analyze reliably
            bpm = key = mode = None
        else:
            bpm, key, mode = analyze_window(ys, sr)
        segs.append({"start_ms": start, "end_ms": end, "bpm": bpm, "key": key, "mode": mode})

    print(json.dumps(segs))


if __name__ == "__main__":
    main()
