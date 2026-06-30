#!/usr/bin/env python3
"""Detect cue markers for ONE track: intro end, outro start, beat grid, sections.

Decoding is ffmpeg-driven (mono, low SR) so any container works and memory stays
small. Intro/outro come from the smoothed RMS energy envelope (the first sustained
rise after the quiet head; the last sustained drop before the tail), snapped to the
nearest detected beat so transitions land on-beat. Sections are the strongest
structural novelty peaks (chroma+MFCC), also beat-snapped.

Usage: marker_analyze.py <audio_path>

stdout (one JSON object per line):
  {"progress": {"stage": str, "done": int, "total": int}}      # zero or more
  {"markers": {"intro_ms": int|null, "outro_ms": int|null,
               "beat_ms": int|null, "bpm": float|null,
               "sections": [int, ...]}}                          # final
"""
import sys
import json
import subprocess
import numpy as np
import librosa

SR = 11025            # mono analysis rate — plenty for energy/beat/structure
HOP = 512             # RMS/feature hop
COARSE_HOP_S = 2.0    # one structural feature column per ~2 s


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def progress(stage, done, total):
    emit({"progress": {"stage": stage, "done": done, "total": total}})


def duration_ms(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nokey=1:noprint_wrappers=1", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return int(float(out) * 1000)


def decode(path):
    """Decode the whole file to mono float32 at SR via ffmpeg."""
    cmd = ["ffmpeg", "-v", "error", "-nostdin", "-i", path,
           "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def beat_grid(y):
    """(bpm, sorted beat times in seconds). Empty/None when unbeatable."""
    try:
        tempo, beats = librosa.beat.beat_track(y=y, sr=SR, hop_length=HOP)
    except Exception:
        return None, np.array([])
    bpm = round(float(np.atleast_1d(tempo)[0]), 2) or None
    times = librosa.frames_to_time(beats, sr=SR, hop_length=HOP)
    return bpm, np.sort(times)


def snap_ms(ms, beat_times):
    """Snap a millisecond position to the nearest beat (no-op without beats)."""
    if ms is None or beat_times.size == 0:
        return ms
    return int(round(float(beat_times[np.argmin(np.abs(beat_times - ms / 1000.0))]) * 1000))


def intro_outro(y, beat_times):
    """First sustained energy rise / last sustained drop, in ms (beat-snapped)."""
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    if rms.size < 8:
        return None, None
    # smooth ~1s
    win = max(1, int(SR / HOP))
    kern = np.ones(win) / win
    s = np.convolve(rms, kern, mode="same")
    thr = 0.5 * np.percentile(s, 75)          # "the track is properly playing" level
    hold = max(1, int(2 * SR / HOP))          # must stay over/under for ~2 s
    above = s >= thr

    def first_sustained(mask):
        run = 0
        for i, v in enumerate(mask):
            run = run + 1 if v else 0
            if run >= hold:
                return i - run + 1
        return None

    intro_f = first_sustained(above)
    outro_end_f = first_sustained(above[::-1])  # from the tail
    times = librosa.frames_to_time(np.arange(rms.size), sr=SR, hop_length=HOP)
    intro_ms = None if intro_f is None else int(times[intro_f] * 1000)
    outro_ms = None if outro_end_f is None else int(times[rms.size - 1 - outro_end_f] * 1000)
    return snap_ms(intro_ms, beat_times), snap_ms(outro_ms, beat_times)


def sections(y, dur_ms, beat_times):
    """A few strongest structural novelty peaks, beat-snapped (cue markers)."""
    hop = int(SR * COARSE_HOP_S)
    cols = []
    for start in range(0, len(y), hop):
        chunk = y[start:start + hop]
        if len(chunk) < SR // 2:
            break
        chroma = librosa.feature.chroma_cqt(y=chunk, sr=SR).mean(axis=1)
        mfcc = librosa.feature.mfcc(y=chunk, sr=SR, n_mfcc=8).mean(axis=1)
        cols.append(np.concatenate([chroma, mfcc]))
    if len(cols) < 3:
        return []
    feat = np.array(cols).T
    norms = np.linalg.norm(feat, axis=0, keepdims=True)
    norms[norms == 0] = 1.0
    feat = feat / norms
    d = np.linalg.norm(np.diff(feat, axis=1), axis=0)
    s = np.convolve(d, np.ones(3) / 3, mode="same")
    thr = np.percentile(s, 90)
    peaks = [(int((i + 1) * COARSE_HOP_S * 1000), float(s[i]))
             for i in range(1, len(s) - 1)
             if s[i] >= thr and s[i] >= s[i - 1] and s[i] >= s[i + 1]]
    peaks.sort(key=lambda p: -p[1])
    top = max(0, min(6, round(dur_ms / 1000 / 60)))   # ~1 per minute, cap 6
    return sorted(snap_ms(ms, beat_times) for ms, _ in peaks[:top])


def main():
    path = sys.argv[1]
    dur = duration_ms(path)
    progress("decoding", 0, 1)
    y = decode(path)
    progress("decoding", 1, 1)
    bpm, beats = beat_grid(y)
    progress("beats", 1, 1)
    intro_ms, outro_ms = intro_outro(y, beats)
    secs = sections(y, dur, beats)
    progress("structure", 1, 1)
    beat_ms = None
    if beats.size >= 2:
        beat_ms = int(round(float(np.median(np.diff(beats))) * 1000))
    emit({"markers": {"intro_ms": intro_ms, "outro_ms": outro_ms,
                      "beat_ms": beat_ms, "bpm": bpm, "sections": secs}})


if __name__ == "__main__":
    main()
