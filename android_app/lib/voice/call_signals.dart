/// Decrypted call-signalling bus.
///
/// The session controller decrypts `signal` frames with the Olm ratchet and
/// pushes the plaintext JSON here. Nothing in this path touches the relay in
/// readable form, and payloads are dropped when the session ends.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CallSignal {
  const CallSignal(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  String? get sdp => data['sdp'] as String?;

  String? get candidate => data['candidate'] as String?;

  String? get sdpMid => data['sdpMid'] as String?;

  int? get sdpMLineIndex => (data['sdpMLineIndex'] as num?)?.toInt();
}

final callSignalsProvider = NotifierProvider<CallSignals, List<CallSignal>>(
  CallSignals.new,
);

class CallSignals extends Notifier<List<CallSignal>> {
  final StreamController<CallSignal> _controller =
      StreamController<CallSignal>.broadcast();

  Stream<CallSignal> get stream => _controller.stream;

  @override
  List<CallSignal> build() {
    ref.onDispose(() {
      unawaited(_controller.close());
    });
    return const [];
  }

  void push(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final type = decoded['type'];
    if (type is! String) return;
    // `sas` is the device-verification exchange; it rides the same encrypted
    // channel so the relay never sees either SAS public key in the clear.
    if (!const {
      'offer',
      'answer',
      'ice',
      'hangup',
      'ringing',
      'sas',
    }.contains(type))
      return;
    final signal = CallSignal(type, decoded);
    _controller.add(signal);
    state = [...state, signal].take(32).toList();
  }

  /// Remove verification-only material after mutual approval.
  void clearVerificationSignals() {
    state = state.where((signal) => signal.type != 'sas').toList();
  }

  /// Drop every buffered signal; used when the session ends or locks.
  void clear() {
    state = const [];
  }
}
