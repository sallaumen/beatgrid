#!/usr/bin/env python3
"""Local BPM + key analysis for one audio file. Prints JSON {bpm, key, mode}.

key is a pitch class (0=C … 11=B), mode is 1=major / 0=minor — matching the
Beatgrid.Soundcharts.Camelot.from_key/2 convention. Key is estimated with the
Krumhansl-Schmuckler profiles correlated against the mean chroma vector.
"""
import sys
import json
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import librosa

# Krumhansl-Schmuckler key profiles (index 0 = tonic).
MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def best_key(profile, chroma_mean):
    cors = [np.corrcoef(np.roll(profile, i), chroma_mean)[0, 1] for i in range(12)]
    i = int(np.argmax(cors))
    return i, cors[i]


def analyze(path):
    y, sr = librosa.load(path, mono=True)

    tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
    bpm = round(float(np.atleast_1d(tempo)[0]), 2)

    chroma_mean = librosa.feature.chroma_cqt(y=y, sr=sr).mean(axis=1)
    maj_i, maj_c = best_key(MAJOR, chroma_mean)
    min_i, min_c = best_key(MINOR, chroma_mean)
    key, mode = (maj_i, 1) if maj_c >= min_c else (min_i, 0)

    return {"bpm": bpm, "key": key, "mode": mode}


if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1])))
