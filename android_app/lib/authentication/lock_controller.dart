/// Immediate locking.
///
/// Requirements this enforces:
///  * any real background transition ends the private session and clears UI
///    state before the content can be seen in recents;
///  * returning to the app always requires authentication again;
///  * transient system UI (biometric prompt, permission dialog, camera scanner)
///    does NOT lock, otherwise unlocking would be impossible.
///
/// The last point is why this listens to Android's own `onStop`/`onStart`
/// events through a Kotlin channel in addition to Flutter's lifecycle: Flutter
/// reports `inactive` for dialogs, which is not the same thing as being gone.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../security/native_bridge.dart';
import '../security/secure_store.dart';

enum LockPhase { locked, unlocked }

class LockState {
  const LockState({
    required this.phase,
    this.reason,
    this.overlayVisible = false,
  });

  final LockPhase phase;
  final String? reason;
  final bool overlayVisible;

  bool get isLocked => phase == LockPhase.locked;

  LockState copyWith({
    LockPhase? phase,
    String? reason,
    bool? overlayVisible,
  }) => LockState(
    phase: phase ?? this.phase,
    reason: reason ?? this.reason,
    overlayVisible: overlayVisible ?? this.overlayVisible,
  );
}

/// Callbacks the controller needs from the session layer, so locking never
/// depends on widget state.
abstract class LockSink {
  Future<void> endSessionForLock();
  Future<void> clearSessionState();
}

class LockController extends Notifier<LockState> {
  Timer? _graceTimer;
  StreamSubscription<bool>? _foregroundSub;
  StreamSubscription<String>? _nativeLockSub;
  AppLifecycleListener? _lifecycle;
  LockSink? _sink;
  NativeBridge? _native;

  /// Retained for API compatibility with callers; Android's native onStop
  /// signal is authoritative and locks immediately. Flutter's inactive/pause
  /// events alone are not used because system prompts also trigger them.
  static const Duration graceWindow = Duration.zero;

  @override
  LockState build() {
    ref.onDispose(() {
      _graceTimer?.cancel();
      _foregroundSub?.cancel();
      _nativeLockSub?.cancel();
      _lifecycle?.dispose();
    });
    return const LockState(phase: LockPhase.locked, reason: 'startup');
  }

  void attach({required LockSink sink, required NativeBridge native}) {
    if (_sink != null) return;
    _sink = sink;
    _native = native;

    _lifecycle = AppLifecycleListener(
      onHide: () => lockNow('app_hidden'),
      // Android's native onStop channel distinguishes a real background
      // transition from biometric/permission dialogs. Do not lock on pause.
      onPause: () {},
      onResume: () => cancelScheduledLock(),
      onDetach: () => lockNow('app_detached'),
    );

    _nativeLockSub = native.lockRequests.listen((reason) => lockNow(reason));
    _foregroundSub = native.foregroundStream.listen((foreground) {
      if (foreground) {
        cancelScheduledLock();
      } else {
        lockNow('backgrounded');
      }
    });
  }

  void scheduleLockCheck() {
    _graceTimer?.cancel();
    _graceTimer = Timer(graceWindow, () => lockNow('backgrounded'));
  }

  void cancelScheduledLock() {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (state.phase == LockPhase.locked && state.reason == 'backgrounded') {
      // The app came back within the grace window: stay locked but do not claim
      // a lock reason the user did not experience.
      state = state.copyWith(overlayVisible: false);
    }
  }

  void markAuthenticated() {
    _graceTimer?.cancel();
    state = const LockState(phase: LockPhase.unlocked);
  }

  void lockNow(String reason) {
    _graceTimer?.cancel();
    if (state.phase == LockPhase.locked) {
      if (state.reason == reason) return;
      state = state.copyWith(reason: reason, overlayVisible: true);
      return;
    }
    state = LockState(
      phase: LockPhase.locked,
      reason: reason,
      overlayVisible: true,
    );
    // The cover is committed synchronously above. Run teardown in order so
    // call disposal cannot race session disposal or signal-buffer clearing.
    final sink = _sink;
    if (sink != null) unawaited(_runSink(sink));
    unawaited(_secureFlag(true));
  }

  Future<void> _runSink(LockSink sink) async {
    try {
      await sink.endSessionForLock();
    } catch (_) {
      // The surface remains locked even if transport/native teardown fails.
    }
    try {
      await sink.clearSessionState();
    } catch (_) {
      // Do not expose content because cleanup reported an error.
    }
  }

  Future<void> _secureFlag(bool enabled) async {
    try {
      await _native?.setSecureFlag(enabled);
    } catch (_) {
      // Not fatal: FLAG_SECURE is defence in depth, the overlay is primary.
    }
  }

  /// Called when the private area is opened, before authentication completes.
  Future<void> preparePrivateSurface() => _secureFlag(true);
}

/// Serialises the wire reason for diagnostics without leaking content.
String describeLockReason(String reason) => switch (reason) {
  'app_hidden' => 'App hidden',
  'app_detached' => 'App closed',
  'backgrounded' => 'App left the foreground',
  'screen_off' => 'Screen turned off',
  'recents' => 'Recent apps opened',
  'user_exit' => 'You left the private area',
  'peer_lock' => 'The other device locked',
  'peer_exit' => 'The other device left',
  'timeout' => 'Connection timed out',
  _ => 'Locked',
};

/// Persists the last lock reason for the lock screen copy.
Future<void> rememberLockReason(SecureStore store, String reason) =>
    store.write(SecureKeys.lastLockReason, reason);

/// Validates that a lock really happened, for the security test checklist.
bool isLockedForPrivateContent(LockState state) =>
    state.phase == LockPhase.locked && state.overlayVisible;
