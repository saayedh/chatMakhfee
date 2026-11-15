/// Coordinates immediate lock teardown across calls, relay sessions and UI state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../authentication/lock_controller.dart';
import '../voice/call_controller.dart';
import '../voice/call_signals.dart';
import '../cryptography/olm_service.dart';
import '../app/providers.dart';
import 'session_controller.dart';

class SessionLockSink implements LockSink {
  SessionLockSink(this.ref);

  final WidgetRef ref;

  @override
  Future<void> endSessionForLock() async {
    // Stop microphone/media first, then close the encrypted relay session.
    try {
      await ref.read(callProvider.notifier).resetForLock();
    } finally {
      await ref.read(sessionProvider.notifier).leave(reason: 'lock');
    }
  }

  @override
  Future<void> clearSessionState() async {
    ref.read(callSignalsProvider.notifier).clear();
    await ref.read(sessionProvider.notifier).clearTransientState();
    ref.read(olmServiceProvider).unloadIdentity();
    ref.invalidate(identityProvider);
  }
}
