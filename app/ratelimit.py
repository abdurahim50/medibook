"""Throttling of failed sign-in attempts (MB-002).

Failures are counted per account and per client address inside a sliding window.
Once a limit is reached, further attempts are refused with 429 until the oldest
failure leaves the window. This is a temporary throttle, not a permanent lockout.

State is held in memory, so each running container keeps its own counters.
The edge rate limit (AWS WAF) is the shared control across containers.
"""
import hashlib
import logging
import math
import threading
import time
from collections import deque

ACCOUNT_MAX_FAILURES = 5
CLIENT_MAX_FAILURES = 20
WINDOW_SECONDS = 15 * 60
# Upper bound on keys held per limiter (MB-010). Each key costs a few hundred
# bytes, so this caps the limiter at tens of MB however many emails or
# addresses an attacker cycles through.
MAX_TRACKED_KEYS = 100_000

logger = logging.getLogger("medibook.ratelimit")


class FailureLimiter:
    """Count failures per key in a sliding window.

    Keys are kept in order of their latest failure, so expired keys are always at
    the front: every write removes them first, and memory follows recent
    activity instead of growing forever (MB-010).
    """

    def __init__(self, max_failures: int, window_seconds: float, clock=time.monotonic,
                 max_keys: int = MAX_TRACKED_KEYS):
        self.max_failures = max_failures
        self.window = window_seconds
        self.max_keys = max_keys
        self._clock = clock
        self._failures: dict[str, deque] = {}
        self._at_capacity = False
        self._lock = threading.Lock()

    def __len__(self) -> int:
        return len(self._failures)

    def _expired(self, failures: deque, now: float) -> bool:
        return now - failures[-1] >= self.window

    def _sweep(self, now: float) -> None:
        """Drop keys whose latest failure has left the window (oldest first)."""
        while self._failures:
            oldest = next(iter(self._failures))
            if not self._expired(self._failures[oldest], now):
                break
            del self._failures[oldest]

    def _prune(self, key: str, now: float) -> deque:
        failures = self._failures.get(key)
        if failures is None:
            return deque()
        while failures and now - failures[0] >= self.window:
            failures.popleft()
        if not failures:
            del self._failures[key]
        return failures

    def retry_after(self, key: str) -> int:
        """Seconds until the key may try again; 0 if it is not blocked."""
        with self._lock:
            now = self._clock()
            failures = self._prune(key, now)
            if len(failures) < self.max_failures:
                return 0
            return max(1, math.ceil(self.window - (now - failures[0])))

    def record_failure(self, key: str) -> None:
        with self._lock:
            now = self._clock()
            self._sweep(now)
            failures = self._prune(key, now)
            if key in self._failures:
                del self._failures[key]  # re-inserted below: newest goes last
            elif len(self._failures) >= self.max_keys:
                # Full of live keys: forget the one idle longest. Reaching this
                # needs more distinct keys in 15 minutes than the edge rate limit
                # allows from thousands of addresses, so it is logged as an attack.
                del self._failures[next(iter(self._failures))]
                if not self._at_capacity:
                    logger.warning("sign-in limiter at capacity: %d keys", self.max_keys)
                self._at_capacity = True
            else:
                self._at_capacity = False
            failures = failures or deque(maxlen=self.max_failures)
            failures.append(now)
            self._failures[key] = failures

    def reset(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)


class SigninLimiter:
    """Per-account and per-client limits for /auth/signin."""

    def __init__(self, clock=time.monotonic):
        self.account = FailureLimiter(ACCOUNT_MAX_FAILURES, WINDOW_SECONDS, clock)
        self.client = FailureLimiter(CLIENT_MAX_FAILURES, WINDOW_SECONDS, clock)

    @staticmethod
    def account_key(email: str) -> str:
        # Keyed on the submitted email whether or not the account exists, so the
        # limit behaves the same for real and unknown accounts (no enumeration).
        # Only a digest is kept in memory.
        return hashlib.sha256(email.lower().encode()).hexdigest()

    def retry_after(self, email: str, client: str) -> int:
        return max(
            self.account.retry_after(self.account_key(email)),
            self.client.retry_after(client),
        )

    def record_failure(self, email: str, client: str) -> None:
        self.account.record_failure(self.account_key(email))
        self.client.record_failure(client)

    def record_success(self, email: str) -> None:
        self.account.reset(self.account_key(email))