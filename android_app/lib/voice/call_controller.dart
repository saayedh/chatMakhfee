/// One-to-one voice calls.
///
/// Flow (both modes use the same one, only the ICE configuration differs):
///   caller: request mic -> foreground service -> offer over Olm -> ICE
///   callee: incoming offer -> accept -> answer -> ICE
/// Media goes phone-to-phone. If the two networks cannot reach each other and
/// TURN is disabled, the call fails with an explicit message instead of
/// silently degrading.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app/providers.dart';
import '../sessions/session_controller.dart';
import 'call_signals.dart';
import 'webrtc_service.dart';

enum CallPhase { idle, outgoing, incoming, connecting, active, ended }

class CallState {
  const CallState({
    required this.phase,
    this.muted = false,
    this.speaker = true,
    this.startedAt,
    this.error,
  });

  final CallPhase phase;
  final bool muted;
  final bool speaker;
  final DateTime? startedAt;
  final String? error;

  bool get inCall => phase == CallPhase.active;

  bool get isBusy =>
      phase == CallPhase.outgoing ||
      phase == CallPhase.incoming ||
      phase == CallPhase.connecting ||
      phase == CallPhase.active;

  Duration get duration =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  CallState copyWith({
    CallPhase? phase,
    bool? muted,
    bool? speaker,
    DateTime? startedAt,
    String? error,
  }) => CallState(
    phase: phase ?? this.phase,
    muted: muted ?? this.muted,
    speaker: speaker ?? this.speaker,
    startedAt: startedAt ?? this.startedAt,
    error: error ?? this.error,
  );
}

final callProvider = NotifierProvider<CallController, CallState>(
  CallController.new,
);

class CallController extends Notifier<CallState> {
  WebRtcService? _rtc;
  StreamSubscription<CallSignal>? _signals;
  Timer? _ticker;
  String? _pendingOfferSdp;
  bool _remoteDescriptionReady = false;
  final List<RTCIceCandidate> _pendingIceCandidates = [];
  static const int _maxPendingIceCandidates = 64;

  @override
  CallState build() {
    _signals = ref.read(callSignalsProvider.notifier).stream.listen(_onSignal);
    ref.onDispose(() {
      _signals?.cancel();
      _ticker?.cancel();
      unawaited(_rtc?.dispose());
    });
    return const CallState(phase: CallPhase.idle);
  }

  WebRtcConfig get _config =>
      WebRtcConfig(iceServers: ref.read(iceServersProvider));

  Future<void> startCall() async {
    if (state.isBusy) return;
    final session = ref.read(sessionProvider.notifier);
    if (!session.canSignal) {
      state = state.copyWith(
        phase: CallPhase.idle,
        error: 'Connect both devices and verify the matching security code before calling.',
      );
      return;
    }

    final granted = await ref
        .read(nativeBridgeProvider)
        .requestMicrophonePermission();
    if (!granted) {
      state = state.copyWith(
        phase: CallPhase.idle,
        error: 'Microphone permission is required for calls.',
      );
      return;
    }

    _remoteDescriptionReady = false;
    _pendingIceCandidates.clear();
    state = const CallState(phase: CallPhase.outgoing);
    try {
      await ref.read(nativeBridgeProvider).startCallService('SecretPlay call');
      final rtc = WebRtcService();
      _rtc = rtc;
      await rtc.initialise(
        config: _config,
        onIceCandidate: _sendCandidate,
        onRemoteStream: (_) {},
        onConnectionState: _onConnectionState,
      );
      await rtc.setSpeaker(true);
      final offer = await rtc.createOffer();
      final sent = await session.sendSignal(jsonEncode({'type': 'offer', 'sdp': offer}));
      if (!sent) throw StateError('secure call offer was not sent');
      state = state.copyWith(phase: CallPhase.connecting);
    } catch (_) {
      await _fail('Could not start the call.');
    }
  }

  Future<void> acceptCall() async {
    if (state.phase != CallPhase.incoming) return;
    _remoteDescriptionReady = false;
    final granted = await ref
        .read(nativeBridgeProvider)
        .requestMicrophonePermission();
    if (!granted) {
      await rejectCall();
      return;
    }
    try {
      await ref.read(nativeBridgeProvider).startCallService('SecretPlay call');
      final rtc = WebRtcService();
      _rtc = rtc;
      await rtc.initialise(
        config: _config,
        onIceCandidate: _sendCandidate,
        onRemoteStream: (_) {},
        onConnectionState: _onConnectionState,
      );
      await rtc.setSpeaker(state.speaker);
      final offer = _pendingOfferSdp;
      if (offer == null) throw StateError('no pending offer');
      await _setRemoteDescriptionAndDrain(rtc, offer, 'offer');
      final answer = await rtc.createAnswer();
      final sent = await ref
          .read(sessionProvider.notifier)
          .sendSignal(jsonEncode({'type': 'answer', 'sdp': answer}));
      if (!sent) throw StateError('secure call answer was not sent');
      state = state.copyWith(phase: CallPhase.connecting);
    } catch (_) {
      await _fail('Could not answer the call.');
    }
  }

  Future<void> rejectCall() async {
    await ref
        .read(sessionProvider.notifier)
        .sendSignal(jsonEncode({'type': 'hangup'}));
    await _cleanup(phase: CallPhase.idle);
  }

  Future<void> hangUp() async {
    await ref
        .read(sessionProvider.notifier)
        .sendSignal(jsonEncode({'type': 'hangup'}));
    await _cleanup(phase: CallPhase.ended);
  }

  Future<void> toggleMute() async {
    final next = !state.muted;
    await _rtc?.setMuted(next);
    state = state.copyWith(muted: next);
  }

  Future<void> toggleSpeaker() async {
    final next = !state.speaker;
    await _rtc?.setSpeaker(next);
    state = state.copyWith(speaker: next);
  }

  void _onSignal(CallSignal signal) {
    // The call controller listens to the same decrypted signal bus as SAS.
    // Never act on offers, answers, ICE candidates or hangups until both users
    // have approved the exact same authenticated verification transcript.
    if (!ref.read(sessionProvider.notifier).canSignal) return;
    switch (signal.type) {
      case 'offer':
        if (state.isBusy && state.phase != CallPhase.connecting) return;
        _remoteDescriptionReady = false;
        _pendingIceCandidates.clear();
        _pendingOfferSdp = signal.sdp;
        state = state.copyWith(phase: CallPhase.incoming);
      case 'answer':
        final sdp = signal.sdp;
        final rtc = _rtc;
        if (sdp == null || rtc == null) return;
        unawaited(_setRemoteDescriptionAndDrain(rtc, sdp, 'answer'));
        state = state.copyWith(phase: CallPhase.connecting);
      case 'ice':
        final rtc = _rtc;
        final candidate = signal.candidate;
        if (candidate == null) return;
        final ice = RTCIceCandidate(
          candidate,
          signal.sdpMid ?? '0',
          signal.sdpMLineIndex ?? 0,
        );
        // The callee may receive ICE after the offer but before the user taps
        // Accept, when no RTCPeerConnection exists yet. Preserve a bounded
        // queue until the remote SDP is installed; otherwise early candidates
        // are silently lost and LAN calls can fail nondeterministically.
        if (!_remoteDescriptionReady || rtc == null) {
          if (_pendingIceCandidates.length < _maxPendingIceCandidates) {
            _pendingIceCandidates.add(ice);
          }
        } else {
          unawaited(rtc.addIceCandidate(ice));
        }
      case 'hangup':
        unawaited(_cleanup(phase: CallPhase.ended));
    }
  }

  Future<void> _sendCandidate(RTCIceCandidate candidate) async {
    await ref.read(sessionProvider.notifier).sendSignal(
      jsonEncode({
        'type': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }),
    );
  }

  Future<void> _setRemoteDescriptionAndDrain(
    WebRtcService rtc,
    String sdp,
    String type,
  ) async {
    await rtc.setRemoteDescription(sdp, type);
    _remoteDescriptionReady = true;
    final queued = List<RTCIceCandidate>.of(_pendingIceCandidates);
    _pendingIceCandidates.clear();
    for (final candidate in queued) {
      await rtc.addIceCandidate(candidate);
    }
  }

  void _onConnectionState(RTCPeerConnectionState connectionState) {
    switch (connectionState) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (state.phase == CallPhase.active) state = state.copyWith();
        });
        state = state.copyWith(
          phase: CallPhase.active,
          startedAt: DateTime.now(),
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        unawaited(
          _fail(
            'The call could not connect. If TURN is disabled, these networks may not allow a direct path.',
          ),
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        state = state.copyWith(
          phase: CallPhase.connecting,
          error: 'Connection interrupted. WebRTC may recover briefly; end and restart the call if it remains disconnected.',
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        unawaited(_cleanup(phase: CallPhase.ended));
      default:
        break;
    }
  }

  Future<void> _fail(String message) async {
    state = state.copyWith(phase: CallPhase.ended, error: message);
    await _cleanup(phase: CallPhase.ended);
  }

  /// Drops the peer connection, stops the mic, and removes the foreground
  /// service and its notification.
  Future<void> _cleanup({required CallPhase phase, bool clearError = false}) async {
    _ticker?.cancel();
    _ticker = null;
    _pendingOfferSdp = null;
    _remoteDescriptionReady = false;
    _pendingIceCandidates.clear();
    final rtc = _rtc;
    _rtc = null;
    try {
      await rtc?.dispose();
    } catch (_) {
      // Continue to stop Android's microphone foreground service.
    }
    try {
      await ref.read(nativeBridgeProvider).stopCallService();
    } catch (_) {
      // The WebRTC tracks have already been disposed where possible.
    }
    state = CallState(
      phase: phase,
      muted: false,
      speaker: true,
      error: clearError ? null : state.error,
    );
  }

  /// Called by the lock path: a locked app cannot keep the microphone open.
  Future<void> resetForLock() => _cleanup(phase: CallPhase.idle, clearError: true);
}
