/// WebRTC audio calls.
///
/// Media is peer-to-peer and protected by DTLS-SRTP, which WebRTC negotiates as
/// part of the connection. In local mode the phone gathers host candidates only
/// (no STUN/TURN, no Internet). In cloud mode it uses the ICE servers the Worker
/// returned — Cloudflare STUN always, TURN only if the operator enabled it.
///
/// The relay never carries media: it only forwards encrypted offer/answer/ICE
/// messages through the Olm channel.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcConfig {
  const WebRtcConfig({required this.iceServers});

  /// Each entry is `{'urls': ['stun:...']}`, optionally with username/credential.
  final List<Map<String, dynamic>> iceServers;

  Map<String, dynamic> toRtcConfiguration() => {
    'iceServers': iceServers,
    'sdpSemantics': 'unified-plan',
    // IceCandidatePoolSize speeds up reconnection on the same LAN.
    'iceCandidatePoolSize': 2,
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
  };
}

class WebRtcService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _muted = false;

  bool get isReady => _pc != null;

  Future<void> initialise({
    required WebRtcConfig config,
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(RTCPeerConnectionState state) onConnectionState,
  }) async {
    final pc = await createPeerConnection(config.toRtcConfiguration(), {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    });
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      unawaited(onIceCandidate(candidate));
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) onRemoteStream(event.streams.first);
    };
    pc.onConnectionState = onConnectionState;

    // Audio only: the microphone is opened here, which is why the UI must have
    // requested the runtime permission and started the foreground service first.
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    _localStream = stream;
    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  Future<String> createOffer() async {
    final pc = _requirePc();
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  Future<String> createAnswer() async {
    final pc = _requirePc();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  Future<void> setRemoteDescription(String sdp, String type) async {
    final pc = _requirePc();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    final pc = _requirePc();
    await pc.addCandidate(candidate);
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
  }

  bool get isMuted => _muted;

  /// Android routes audio through the earpiece by default; calls normally want
  /// the speaker, and the UI can toggle back.
  Future<void> setSpeaker(bool on) async {
    await Helper.setSpeakerphoneOn(on);
  }

  Future<void> dispose() async {
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    // Never leave the mic indicator on after a call.
    await Helper.setSpeakerphoneOn(false);
  }

  RTCPeerConnection _requirePc() {
    final pc = _pc;
    if (pc == null) throw StateError('WebRTC is not initialised');
    return pc;
  }
}
