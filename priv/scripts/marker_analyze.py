#!/usr/bin/env python3
"""Detect DJ cue markers for ONE track: entry point, mix-out point, beat grid,
section cues — phrase-aware (v2).

v1 marked the outro where the ENERGY DIES (start of the final fade) and the
intro where the head first grows loud; transitions fired over a dying track
and skipped long real intros. v2 thinks like a DJ:

  intro_ms  first REAL sound (silence bound, Mixxx-style) — the incoming
            track enters from the top of the music, never mid-verse.
  outro_ms  where the LAST SECTION begins: the latest structural boundary
            that still leaves runway before the energy end. This is where a
            DJ starts mixing OUT, so the blend rides the outro instead of
            firing after the music is already gone.
  sections  strongest structural boundaries (Foote checkerboard novelty over
            beat-synchronous timbre+harmony, 16-beat kernel = phrase scale),
            beat-snapped — they feed the hot-cue pads.

Decoding is ffmpeg-driven (mono, low SR) so any container works and memory
stays small. Tracks the beat tracker can't grid (tiny clips, rubato) degrade
to the v1 energy heuristics instead of failing.

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
PHRASE_BEATS = 16     # forró phrases self-repeat at 16 beats (binary meter)
SOUND_DB = -50.0      # "there is music here" bound, dBFS-ish on mono RMS
MIN_TAIL_MS = 3000    # never mark past the final runway the console needs
OUTRO_FLOOR = 0.70    # a boundary in the front 70% is not an outro
OUTRO_RUNWAY_MS = 4000  # the outro must leave this much before the energy end


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
    """(bpm, beat times in seconds, beat frames). Empty when unbeatable."""
    try:
        tempo, beats = librosa.beat.beat_track(y=y, sr=SR, hop_length=HOP)
    except Exception:
        return None, np.array([]), np.array([], dtype=int)
    bpm = round(float(np.atleast_1d(tempo)[0]), 2) or None
    order = np.sort(beats)
    times = librosa.frames_to_time(order, sr=SR, hop_length=HOP)
    return bpm, times, order


def snap_ms(ms, beat_times):
    """Snap a millisecond position to the nearest beat (no-op without beats)."""
    if ms is None or beat_times.size == 0:
        return ms
    return int(round(float(beat_times[np.argmin(np.abs(beat_times - ms / 1000.0))]) * 1000))


def first_sustained(mask, hold):
    run = 0
    for i, v in enumerate(mask):
        run = run + 1 if v else 0
        if run >= hold:
            return i - run + 1
    return None


def rms_envelope(y):
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    times = librosa.frames_to_time(np.arange(rms.size), sr=SR, hop_length=HOP)
    return rms, times


def sound_bounds(rms, times):
    """First/last audible frame (> SOUND_DB for ~0.25 s) — the silence trim."""
    if rms.size == 0:
        return None, None
    db = librosa.amplitude_to_db(rms, ref=1.0)
    above = db > SOUND_DB
    hold = max(1, int(0.25 * SR / HOP))
    first = first_sustained(above, hold)
    last_rev = first_sustained(above[::-1], hold)
    first_ms = None if first is None else int(times[first] * 1000)
    last_ms = None if last_rev is None else int(times[rms.size - 1 - last_rev] * 1000)
    return first_ms, last_ms


def energy_end_ms(rms, times):
    """Where the track stops PLAYING properly: end of the last sustained-loud
    stretch (the v1 outro). Serves as the ceiling for the mix-out point."""
    if rms.size < 8:
        return None
    win = max(1, int(SR / HOP))
    s = np.convolve(rms, np.ones(win) / win, mode="same")
    thr = 0.5 * np.percentile(s, 75)
    hold = max(1, int(2 * SR / HOP))
    from_tail = first_sustained((s >= thr)[::-1], hold)
    if from_tail is None:
        return None
    return int(times[rms.size - 1 - from_tail] * 1000)


def structure_boundaries(y, beat_frames, beat_times):
    """Section starts as (ms, strength), via Foote checkerboard novelty on
    beat-synchronous MFCC+chroma. The 16-beat kernel makes phrase-scale
    changes peak while bar-level variation cancels out."""
    n_beats = min(beat_frames.size, beat_times.size)
    if n_beats < 3 * PHRASE_BEATS:
        return []
    mfcc = librosa.feature.mfcc(y=y, sr=SR, n_mfcc=13, hop_length=HOP)
    chroma = librosa.feature.chroma_stft(y=y, sr=SR, hop_length=HOP)
    feat = np.vstack([
        librosa.util.normalize(mfcc, norm=2, axis=0),
        librosa.util.normalize(chroma, norm=2, axis=0),
    ])
    sync = librosa.util.sync(feat, beat_frames)[:, :n_beats]
    sync = librosa.util.normalize(sync, norm=2, axis=0)
    ssm = sync.T @ sync

    k = PHRASE_BEATS
    taper = np.outer(np.hanning(2 * k), np.hanning(2 * k))
    checker = np.kron(np.array([[1.0, -1.0], [-1.0, 1.0]]), np.ones((k, k)))
    kernel = taper * checker
    n = ssm.shape[0]
    padded = np.pad(ssm, k, mode="edge")
    novelty = np.array([np.sum(padded[i:i + 2 * k, i:i + 2 * k] * kernel) for i in range(n)])
    novelty = np.maximum(novelty, 0.0)
    positive = novelty[novelty > 0]
    if positive.size == 0:
        return []
    thr = np.percentile(positive, 70)

    peaks = [i for i in range(1, n - 1)
             if novelty[i] >= thr and novelty[i] >= novelty[i - 1] and novelty[i] >= novelty[i + 1]]
    kept = []
    for p in sorted(peaks, key=lambda i: -novelty[i]):
        if all(abs(p - q) >= PHRASE_BEATS // 2 for q in kept):
            kept.append(p)
    return sorted((int(round(beat_times[p] * 1000)), float(novelty[p])) for p in kept)


def phrase_len_ms(beat_times):
    """One phrase in ms from the median beat gap (8 s when unknowable)."""
    if beat_times.size < 2:
        return 8000
    return int(round(float(np.median(np.diff(beat_times))) * 1000)) * PHRASE_BEATS


def choose_outro(bounds, dur_ms, energy_end, intro_ms, beat_times):
    """The mix-out point: the LAST section start that still leaves runway
    before the energy end; without one, ride the final phrase out."""
    base_end = energy_end if energy_end is not None else dur_ms
    phrase = phrase_len_ms(beat_times)
    # A boundary further back than ~2 phrases before the energy end is a last
    # CHORUS start, not an outro — firing there steals the payoff (the sin
    # every automix gets hated for). Ride at most two phrases under the blend.
    floor = max(int(dur_ms * OUTRO_FLOOR), base_end - 2 * phrase - OUTRO_RUNWAY_MS)
    ceiling = base_end - OUTRO_RUNWAY_MS
    candidates = [ms for ms, _strength in bounds if floor <= ms <= ceiling]

    if candidates:
        outro = candidates[-1]
    else:
        outro = snap_ms(max(floor, base_end - phrase), beat_times)

    if outro is None:
        return None
    outro = min(outro, dur_ms - MIN_TAIL_MS)
    if outro <= 0:
        return None
    if intro_ms is not None and outro <= intro_ms:
        return None
    return outro


def section_cues(bounds, dur_ms, intro_ms, outro_ms):
    """A few strongest structural cues (~1/min, cap 6), clear of intro/outro."""
    top = max(0, min(6, round(dur_ms / 1000 / 60)))
    anchors = [ms for ms in (intro_ms, outro_ms) if ms is not None]
    picked = []
    for ms, _strength in sorted(bounds, key=lambda b: -b[1]):
        if len(picked) >= top:
            break
        if all(abs(ms - a) >= 3000 for a in anchors + picked):
            picked.append(ms)
    return sorted(picked)


def main():
    path = sys.argv[1]
    dur = duration_ms(path)
    progress("decoding", 0, 1)
    y = decode(path)
    progress("decoding", 1, 1)
    bpm, beat_times, beat_frames = beat_grid(y)
    progress("beats", 1, 1)

    rms, times = rms_envelope(y)
    first_sound, _last_sound = sound_bounds(rms, times)
    energy_end = energy_end_ms(rms, times)
    intro_ms = snap_ms(first_sound, beat_times)

    bounds = structure_boundaries(y, beat_frames, beat_times)
    outro_ms = choose_outro(bounds, dur, energy_end, intro_ms, beat_times)
    if outro_ms is None and energy_end is not None:
        rescue = min(snap_ms(energy_end, beat_times), dur - MIN_TAIL_MS)
        outro_ms = rescue if rescue > 0 else None
    secs = section_cues(bounds, dur, intro_ms, outro_ms)
    progress("structure", 1, 1)

    beat_ms = None
    if beat_times.size >= 2:
        beat_ms = int(round(float(np.median(np.diff(beat_times))) * 1000))
    emit({"markers": {"intro_ms": intro_ms, "outro_ms": outro_ms,
                      "beat_ms": beat_ms, "bpm": bpm, "sections": secs}})


if __name__ == "__main__":
    main()
