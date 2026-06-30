#!/usr/bin/env python3
"""Segment a recorded DJ mix into tracks and analyze each — memory-bounded.

Decoding is driven by ffmpeg (fast input-seek + streamed PCM), so the whole file
is never loaded and any container ffmpeg reads (mp3/m4a/…) works. Duration via
ffprobe.

Modes:
  segment_analyze.py <audio_path> [<boundaries_json>]
      Segment + per-track BPM/key. boundaries_json = JSON array of start-ms ints;
      empty/absent => boundaries auto-detected from a streamed coarse pass.
  segment_analyze.py --mode dj-candidates <audio_path>
      Stream a coarse feature pass; print strongest novelty peaks as candidate
      DJ-change boundaries.

stdout line protocol (one JSON object per line):
  {"progress": {"stage": str, "done": int, "total": int}}     # zero or more
  {"segments":   [{start_ms,end_ms,bpm,key,mode}, ...]}        # final (default)
  {"candidates": [{start_ms, strength}, ...]}                  # final (dj mode)
"""
import sys
import json
import subprocess
import numpy as np
import librosa

MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

SR = 22050           # per-segment analysis rate
COARSE_SR = 11025    # coarse pass rate (cheaper)
COARSE_HOP_S = 2.0   # one coarse feature column per ~2 s

# DJ-set track-length priors: a track is ~1–7 min. Boundaries are real structural
# transitions, never closer than MIN_GAP, and any stretch longer than MAX_GAP is split.
MIN_GAP_MS = 60_000
MAX_GAP_MS = 420_000


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


def decode_window(path, start_ms, dur_ms, sr):
    """Decode [start_ms, start_ms+dur_ms) to a mono float32 array via ffmpeg."""
    cmd = [
        "ffmpeg", "-v", "error", "-nostdin",
        "-ss", f"{start_ms / 1000:.3f}", "-t", f"{dur_ms / 1000:.3f}",
        "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def coarse_features(path, dur_ms):
    """Stream a coarse mono PCM at COARSE_SR through ffmpeg, computing one feature
    column per COARSE_HOP_S. Memory bounded to one hop chunk + the compact matrix."""
    hop = int(COARSE_SR * COARSE_HOP_S)
    cmd = [
        "ffmpeg", "-v", "error", "-nostdin", "-i", path,
        "-ac", "1", "-ar", str(COARSE_SR), "-f", "f32le", "-",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    cols = []
    total = max(1, dur_ms // 1000)
    try:
        while True:
            buf = proc.stdout.read(hop * 4)  # 4 bytes per float32
            if not buf:
                break
            y = np.frombuffer(buf, dtype=np.float32)
            if len(y) < COARSE_SR // 2:  # < 0.5 s tail: skip
                break
            chroma = librosa.feature.chroma_cqt(y=y, sr=COARSE_SR).mean(axis=1)
            mfcc = librosa.feature.mfcc(y=y, sr=COARSE_SR, n_mfcc=8).mean(axis=1)
            cols.append(np.concatenate([chroma, mfcc]))
            done_ms = len(cols) * int(COARSE_HOP_S * 1000)
            progress("boundaries", min(done_ms // 1000, total), total)
    finally:
        proc.stdout.close()
        proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed in coarse_features with exit code {proc.returncode}")
    if not cols:
        return np.zeros((20, 1))
    feat = np.array(cols).T
    # L2-normalize columns so cosine geometry is well-behaved.
    norms = np.linalg.norm(feat, axis=0, keepdims=True)
    norms[norms == 0] = 1.0
    return feat / norms


def novelty_curve(feat):
    """Smoothed consecutive-column distance — high where the music structurally changes."""
    if feat.shape[1] < 3:
        return np.array([])
    d = np.linalg.norm(np.diff(feat, axis=1), axis=0)
    k = 5
    return np.convolve(d, np.ones(k) / k, mode="same")


def enforce_max_gap(bounds, peaks, min_gap, max_gap, dur_ms):
    """Insert boundaries so no two are more than max_gap apart. Prefer the strongest
    novelty peak inside the gap (respecting min_gap from both ends); else split the middle."""
    bounds = sorted(set(bounds))
    changed = True
    while changed:
        changed = False
        out = [bounds[0]]
        for nxt in bounds[1:]:
            prev = out[-1]
            if nxt - prev > max_gap:
                lo, hi = prev + min_gap, nxt - min_gap
                inside = [(st, ms) for ms, st in peaks if lo <= ms <= hi]
                ms = max(inside)[1] if inside else (prev + nxt) // 2
                if prev < ms < nxt:
                    out.append(ms)
                    changed = True
            out.append(nxt)
        bounds = sorted(set(out))
    return bounds


def detect_boundaries(feat, dur_ms, min_gap=MIN_GAP_MS, max_gap=MAX_GAP_MS):
    """Real DJ-track boundaries: strong novelty peaks, spaced >= min_gap, with any
    stretch longer than max_gap force-split (so a 15-min 'track' can't happen)."""
    s = novelty_curve(feat)
    chosen = []
    if s.size:
        # Strict `> thr` so a flat/steady stretch (where the 75th pct collapses to the
        # baseline) yields NO peaks — those regions get chopped only by the max-gap rule,
        # not packed every min_gap.
        thr = np.percentile(s, 75)
        peaks = [
            (int((i + 1) * COARSE_HOP_S * 1000), float(s[i]))
            for i in range(1, len(s) - 1)
            if s[i] > thr and s[i] >= s[i - 1] and s[i] >= s[i + 1]
        ]
        for ms, _st in sorted(peaks, key=lambda p: -p[1]):
            if min_gap <= ms <= dur_ms - min_gap and all(abs(ms - c) >= min_gap for c in chosen):
                chosen.append(ms)
    else:
        peaks = []
    bounds = enforce_max_gap([0] + sorted(chosen) + [dur_ms], peaks, min_gap, max_gap, dur_ms)
    return [b for b in bounds if 0 < b < dur_ms]


def novelty_peaks(feat, dur_ms):
    """Strongest structural jumps as candidate DJ boundaries."""
    if feat.shape[1] < 3:
        return []
    d = np.linalg.norm(np.diff(feat, axis=1), axis=0)  # consecutive-column distance
    # smooth with a small moving average
    k = 5
    kernel = np.ones(k) / k
    s = np.convolve(d, kernel, mode="same")
    thr = np.percentile(s, 90)
    peaks = []
    for i in range(1, len(s) - 1):
        if s[i] >= thr and s[i] >= s[i - 1] and s[i] >= s[i + 1]:
            peaks.append((int((i + 1) * COARSE_HOP_S * 1000), float(s[i])))
    peaks.sort(key=lambda p: -p[1])
    top = max(2, min(20, round(dur_ms / 1000 / 1200)))  # ~1 candidate / 20 min
    peaks = sorted(peaks[:top], key=lambda p: p[0])
    return [{"start_ms": ms, "strength": round(st, 4)} for ms, st in peaks]


def analyze_window(path, start_ms, end_ms):
    inner_a = start_ms + int((end_ms - start_ms) * 0.20)
    inner_b = start_ms + int((end_ms - start_ms) * 0.85)
    if inner_b - inner_a < 1000:
        return None, None, None
    y = decode_window(path, inner_a, inner_b - inner_a, SR)
    if len(y) < SR:  # < 1 s decoded: too short
        return None, None, None
    tempo, _ = librosa.beat.beat_track(y=y, sr=SR)
    bpm = round(float(np.atleast_1d(tempo)[0]), 2)
    bpm = None if bpm == 0.0 else bpm
    chroma = librosa.feature.chroma_cqt(y=y, sr=SR).mean(axis=1)
    maj_i = int(np.argmax([np.corrcoef(np.roll(MAJOR, i), chroma)[0, 1] for i in range(12)]))
    min_i = int(np.argmax([np.corrcoef(np.roll(MINOR, i), chroma)[0, 1] for i in range(12)]))
    maj_c = np.corrcoef(np.roll(MAJOR, maj_i), chroma)[0, 1]
    min_c = np.corrcoef(np.roll(MINOR, min_i), chroma)[0, 1]
    return (bpm, maj_i, 1) if maj_c >= min_c else (bpm, min_i, 0)


def run_segment(path, boundaries):
    dur = duration_ms(path)
    if not boundaries:
        feat = coarse_features(path, dur)
        boundaries = detect_boundaries(feat, dur)
    starts = sorted(set([0] + [b for b in boundaries if 0 < b < dur]))
    segs = []
    total = len(starts)
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else dur
        bpm, key, mode = analyze_window(path, start, end)
        segs.append({"start_ms": start, "end_ms": end, "bpm": bpm, "key": key, "mode": mode})
        progress("segments", i + 1, total)
    emit({"segments": segs})


def run_dj_candidates(path):
    dur = duration_ms(path)
    feat = coarse_features(path, dur)
    emit({"candidates": novelty_peaks(feat, dur)})


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--mode" and sys.argv[2] == "dj-candidates":
        run_dj_candidates(sys.argv[3])
        return
    path = sys.argv[1]
    boundaries = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else []
    run_segment(path, boundaries)


if __name__ == "__main__":
    main()
