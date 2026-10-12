"""Wall-clock limits that hold on a loaded test machine.

Some tests check that a hook or command returns promptly (it doesn't wait for something it
shouldn't). A shared CI box under heavy load slows every process alike, so a fixed limit fails
at random there. `limit(s)` keeps `s` on a quiet machine and stretches it by the 1-minute load
per core when the machine is busier, capped below the 30 s the tests' subprocesses may take.
"""
from __future__ import annotations

import os

CAP = 25.0


def load_factor() -> float:
    try:
        per_core = os.getloadavg()[0] / (os.cpu_count() or 1)
    except (OSError, AttributeError):
        return 1.0
    return max(1.0, per_core)


def limit(seconds: float) -> float:
    """`seconds`, stretched on a loaded machine (never less, at most CAP unless `seconds` is)."""
    return max(seconds, min(seconds * load_factor(), CAP))
