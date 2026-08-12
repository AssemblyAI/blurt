"""A progress meter for runs that spend minutes waiting on a paid API.

A candidate sweep is hundreds of model calls; without this the harness prints a
handful of lines and then goes silent, which is indistinguishable from a hang.
The meter answers the two questions worth asking mid-run: is it alive, and is the
remaining time worth waiting for or worth killing.

It renders differently depending on where it is pointed, because the same output
cannot serve both:

- **Terminal** — one line rewritten in place, so a long run occupies a single row.
- **Anything else** (a pipe, a log file, CI) — a line at each decile. Carriage
  returns in a log file produce one unreadable mega-line, which is exactly what
  made an earlier attempt at this worse than nothing.
"""

from __future__ import annotations

import sys
import threading
import time


def _duration(seconds: float) -> str:
    """`4m22s` / `18s` — short enough to sit inside a status line."""
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes, seconds = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


class Progress:
    """Counts completed units of work and renders how far along the run is.

    Ticks arrive from worker threads, so every mutation is under a lock.
    """

    def __init__(self, total: int, label: str = "", *, stream=None, width: int = 24):
        self.total = max(total, 1)
        self.label = label
        self.stream = stream or sys.stdout
        self.width = width
        self.done = 0
        self.started = time.monotonic()
        self._lock = threading.Lock()
        self._last_decile = 0
        self._live = bool(getattr(self.stream, "isatty", lambda: False)())

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self.started

    def _eta(self) -> str:
        """Remaining time, extrapolated from the rate so far.

        Deliberately naive: the work is uniform (one model call per unit) and a
        smarter estimator would still be wrong for the first few seconds, which is
        the only time anyone squints at it.
        """
        if self.done == 0:
            return "—"
        return _duration(self.elapsed / self.done * (self.total - self.done))

    def tick(self, note: str = "") -> None:
        """Record one finished unit and redraw."""
        with self._lock:
            self.done = min(self.done + 1, self.total)
            self._render(note)

    def _render(self, note: str) -> None:
        fraction = self.done / self.total
        detail = f"{self.done}/{self.total}"
        context = f"  {note}" if note else ""

        if self._live:
            filled = int(self.width * fraction)
            bar = "█" * filled + "░" * (self.width - filled)
            line = (
                f"  {bar} {fraction:4.0%}  {detail}{context}"
                f"  elapsed {_duration(self.elapsed)}  eta {self._eta()}"
            )
            self.stream.write(f"\r{line[:200]:<120}")
            self.stream.flush()
            return

        # Piped: one line per decile, so a CI log stays readable and still shows
        # the run advancing.
        decile = int(fraction * 10)
        if decile > self._last_decile:
            self._last_decile = decile
            self.stream.write(
                f"  progress {fraction:.0%} ({detail}){context}"
                f"  elapsed {_duration(self.elapsed)}  eta {self._eta()}\n"
            )
            self.stream.flush()

    def close(self) -> None:
        """Finish the meter, leaving the cursor on a fresh line."""
        with self._lock:
            if self._live:
                self.stream.write("\r" + " " * 120 + "\r")
            self.stream.write(f"  {self.label or 'done'} in {_duration(self.elapsed)}\n")
            self.stream.flush()

    def __enter__(self) -> Progress:
        if self.label:
            self.stream.write(f"\n{self.label} — {self.total} model calls\n")
            self.stream.flush()
        return self

    def __exit__(self, *_exc) -> None:
        self.close()
