#!/usr/bin/env python3
"""Self-contained checks for segment_analyze boundary detection (run: python3 this).

No pytest in this repo; this is a plain assert script exercising the pure boundary
logic (novelty peaks + min/max-gap enforcement) on synthetic features.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import segment_analyze as sa

MIN_GAP = 60_000
MAX_GAP = 420_000


def gaps(bounds):
    b = sorted(bounds)
    return [b[i + 1] - b[i] for i in range(len(b) - 1)]


def test_enforce_max_gap_splits_long_stretch():
    # a single 15-min stretch with no candidate peaks must be split below MAX_GAP
    out = sa.enforce_max_gap([0, 900_000], [], MIN_GAP, MAX_GAP, 900_000)
    assert max(gaps(out)) <= MAX_GAP, f"gap exceeds max: {gaps(out)}"
    print("ok enforce_max_gap_splits_long_stretch", out)


def test_enforce_max_gap_prefers_a_peak():
    # given a strong peak inside the long gap, the split lands on it
    out = sa.enforce_max_gap([0, 600_000], [(500_000, 9.0), (480_000, 1.0)], MIN_GAP, MAX_GAP, 600_000)
    assert 500_000 in out, f"did not split on the strong peak: {out}"
    print("ok enforce_max_gap_prefers_a_peak", out)


def test_detect_boundaries_finds_real_transitions():
    # 360 s of features (2 s/col -> 180 cols): blocks change at 120 s and 240 s
    cols = 180
    feat = np.zeros((20, cols))
    feat[:, :60] = 1.0
    feat[:, 60:120] = -1.0
    alt = np.tile([1.0, -1.0], 10).reshape(-1, 1)
    feat[:, 120:] = alt
    norms = np.linalg.norm(feat, axis=0, keepdims=True)
    norms[norms == 0] = 1.0
    feat = feat / norms

    bounds = sa.detect_boundaries(feat, 360_000)
    assert any(abs(b - 120_000) <= 6_000 for b in bounds), f"no boundary ~120s: {bounds}"
    assert any(abs(b - 240_000) <= 6_000 for b in bounds), f"no boundary ~240s: {bounds}"
    # invariants: no segment longer than MAX_GAP, boundaries spaced >= MIN_GAP
    allb = [0] + sorted(bounds) + [360_000]
    assert max(gaps(allb)) <= MAX_GAP, f"a segment exceeds max: {gaps(allb)}"
    assert min(gaps(sorted(bounds))) >= MIN_GAP if len(bounds) > 1 else True
    print("ok detect_boundaries_finds_real_transitions", bounds)


def test_long_quiet_set_is_still_chopped():
    # featureless 20-min set (no transitions) must NOT come back as one segment
    feat = np.ones((20, 600))  # 1200 s at 2 s/col
    norms = np.linalg.norm(feat, axis=0, keepdims=True)
    feat = feat / norms
    bounds = sa.detect_boundaries(feat, 1_200_000)
    allb = [0] + sorted(bounds) + [1_200_000]
    assert max(gaps(allb)) <= MAX_GAP, f"quiet set left a huge segment: {gaps(allb)}"
    # ...but it must NOT be packed every min_gap — a featureless set has no transitions,
    # so it should only be chopped by the max-gap rule (chunks well above min_gap).
    assert min(gaps(allb)) >= 2 * MIN_GAP, f"quiet set over-segmented: {gaps(allb)}"
    print("ok long_quiet_set_is_still_chopped", bounds)


if __name__ == "__main__":
    test_enforce_max_gap_splits_long_stretch()
    test_enforce_max_gap_prefers_a_peak()
    test_detect_boundaries_finds_real_transitions()
    test_long_quiet_set_is_still_chopped()
    print("ALL PASS")
