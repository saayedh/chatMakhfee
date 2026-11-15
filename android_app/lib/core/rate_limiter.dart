/// Authentication throttling.
///
/// Pure Dart so the policy can be executed and verified without a device:
/// `tool/logic_check.dart` drives it directly.
///
/// Policy: `freeAttempts` failures are allowed immediately; each further
/// failure doubles the wait, starting at [baseDelay] and capped at [maxDelay].
/// A successful unlock clears the state.
library;

class AttemptDecision {
  const AttemptDecision({
    required this.allowed,
    required this.remainingFree,
    this.retryAfter,
  });

  final bool allowed;
  final int remainingFree;
  final Duration? retryAfter;
}

class AuthRateLimiter {
  AuthRateLimiter({
    this.freeAttempts = 5,
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(minutes: 30),
  });

  final int freeAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  int _failures = 0;
  DateTime? _lockedUntil;

  int get failures => _failures;
  DateTime? get lockedUntil => _lockedUntil;
  bool get isLocked =>
      _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);

  /// How long the caller must wait, or null when an attempt may proceed now.
  Duration? retryAfter(DateTime now) {
    final until = _lockedUntil;
    if (until == null) return null;
    if (!now.isBefore(until)) return null;
    return until.difference(now);
  }

  /// Check before showing the passphrase field. Side-effect free.
  AttemptDecision check(DateTime now) {
    final wait = retryAfter(now);
    if (wait != null) {
      return AttemptDecision(
        allowed: false,
        remainingFree: 0,
        retryAfter: wait,
      );
    }
    final remaining = freeAttempts - _failures;
    return AttemptDecision(
      allowed: true,
      remainingFree: remaining < 0 ? 0 : remaining,
    );
  }

  /// Record a failed unlock and compute the next allowed time.
  Duration registerFailure(DateTime now) {
    _failures += 1;
    if (_failures <= freeAttempts) {
      _lockedUntil = null;
      return Duration.zero;
    }
    final exponent = _failures - freeAttempts - 1;
    var delayMs = baseDelay.inMilliseconds * (1 << exponent);
    if (delayMs > maxDelay.inMilliseconds) delayMs = maxDelay.inMilliseconds;
    final delay = Duration(milliseconds: delayMs);
    _lockedUntil = now.add(delay);
    return delay;
  }

  /// Restore persisted throttling after an application/process restart.
  void restore({required int failures, DateTime? lockedUntil}) {
    _failures = failures < 0 ? 0 : failures;
    _lockedUntil = lockedUntil;
  }

  void reset() {
    _failures = 0;
    _lockedUntil = null;
  }
}
