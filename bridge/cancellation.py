#!/usr/bin/env python3
"""Thread-safe cancellation primitives for one active bridge turn."""

from __future__ import annotations

import threading


class OperationCancelledError(RuntimeError):
    """Raised when an active bridge operation is explicitly cancelled."""


class CancellationToken:
    def __init__(self) -> None:
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._reason = "cancelled"

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()

    @property
    def reason(self) -> str:
        with self._lock:
            return self._reason

    def cancel(self, reason: str = "cancelled") -> None:
        clean = " ".join(str(reason or "cancelled").strip().split())[:120] or "cancelled"
        with self._lock:
            if not self._event.is_set():
                self._reason = clean
            self._event.set()

    def raise_if_cancelled(self) -> None:
        if self._event.is_set():
            raise OperationCancelledError(self.reason)
