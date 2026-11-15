/// Device verification with an Olm SAS code.
///
/// Both phones derive the same six digits from an ephemeral Diffie-Hellman
/// exchange that travels *inside* the encrypted session. The relay never sees
/// either SAS public key in a usable form, and the code is never stored.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../sessions/session_controller.dart';
import '../voice/call_signals.dart';

class DeviceVerificationScreen extends ConsumerStatefulWidget {
  const DeviceVerificationScreen({super.key});

  @override
  ConsumerState<DeviceVerificationScreen> createState() =>
      _DeviceVerificationScreenState();
}

class _DeviceVerificationScreenState
    extends ConsumerState<DeviceVerificationScreen> {
  StreamSubscription<CallSignal>? _subscription;
  String? _code;
  String? _error;
  bool _sent = false;
  bool _started = false;
  bool _approved = false;
  bool _sasProcessed = false;
  String? _pendingPeerSasKey;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(callSignalsProvider.notifier)
        .stream
        .listen(_onSignal);
    // A peer SAS frame may arrive before this screen has finished starting
    // its local SAS exchange. Preserve and process it once both sides are ready.
    final buffered = ref.read(callSignalsProvider).where((s) => s.type == 'sas');
    if (buffered.isNotEmpty) {
      final key = buffered.last.data['key'];
      if (key is String) _pendingPeerSasKey = key;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  Future<void> _begin() async {
    final session = ref.read(sessionProvider.notifier);
    if (_started || !session.canVerify) return;
    _started = true;
    try {
      final publicKey = ref.read(olmServiceProvider).beginSas();
      final sent = await session.sendSignal(jsonEncode({'type': 'sas', 'key': publicKey}));
      if (!sent) throw StateError('verification signal was not sent');
      if (mounted) setState(() { _sent = true; _error = null; });
      final pending = _pendingPeerSasKey;
      if (pending != null) _processPeerSas(pending);
    } catch (_) {
      _started = false;
      if (mounted) setState(() => _error = 'Could not start verification.');
    }
  }

  void _onSignal(CallSignal signal) {
    if (signal.type != 'sas') return;
    final peerKey = signal.data['key'];
    if (peerKey is! String) return;
    _pendingPeerSasKey = peerKey;
    if (_started) _processPeerSas(peerKey);
  }

  void _processPeerSas(String peerKey) {
    if (_sasProcessed || !mounted) return;
    try {
      final transcript = ref.read(sessionProvider.notifier).verificationTranscript;
      if (transcript == null) return;
      final code = ref.read(olmServiceProvider).sasCode(
        peerKey,
        transcript: transcript,
      );
      _sasProcessed = true;
      setState(() {
        _code = code;
        _error = null;
      });
    } catch (_) {
      // The Olm session may still be completing on role B. Keep the peer key
      // buffered so the next state rebuild can retry after bootstrap.
      if (mounted) setState(() => _error = 'The verification exchange is not ready yet.');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionView = ref.watch(sessionProvider);
    // Role B may receive the peer's encrypted Olm bootstrap after this screen
    // is first shown. Retry automatically when the session becomes verifiable.
    if (!_started && ref.read(sessionProvider.notifier).canVerify) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _begin(); });
    } else if (_started && _code == null && _pendingPeerSasKey != null &&
        ref.read(sessionProvider.notifier).canVerify && !_sasProcessed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _processPeerSas(_pendingPeerSasKey!);
      });
    }
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Verify devices')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Read this code out loud',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Both phones must show exactly the same six digits. If they differ, someone '
                  'may be intercepting the connection — lock both devices and re-pair.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8C93A8),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 26),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: SpColors.privateSurface,
                    border: Border.all(color: SpColors.privateLine),
                  ),
                  child: Center(
                    child: _code == null
                        ? Text(
                            _error ??
                                (_sent
                                    ? 'Waiting for the other device…'
                                    : 'Starting…'),
                            style: TextStyle(
                              color: _error == null
                                  ? const Color(0xFF8C93A8)
                                  : SpColors.coral,
                              fontSize: 13,
                            ),
                          )
                        : Text(
                            '${_code!.substring(0, 3)} ${_code!.substring(3)}',
                            style: const TextStyle(
                              fontSize: 40,
                              letterSpacing: 8,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                if (_code != null) ...[
                  FilledButton.icon(
                    onPressed: _approved || sessionView.peerVerified
                        ? null
                        : () async {
                            final sent = await ref.read(sessionProvider.notifier).markPeerVerified();
                            if (!mounted) return;
                            if (!sent) {
                              setState(() => _error = 'Could not send your approval. Try again.');
                              return;
                            }
                            setState(() => _approved = true);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Your approval was sent. Waiting for the other device.'),
                              ),
                            );
                          },
                    icon: Icon(sessionView.canSend ? Icons.verified : Icons.verified_user),
                    label: Text(
                      sessionView.canSend
                          ? 'Both devices verified'
                          : (sessionView.peerVerified || _approved
                              ? 'Waiting for other device…'
                              : 'Codes match'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      ref
                          .read(sessionProvider.notifier)
                          .leave(reason: 'user_exit');
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    child: const Text('Codes do not match — stop'),
                  ),
                ],
                if (sessionView.peerVerified && sessionView.peerConfirmed) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Both devices verified. Encrypted chat and calls are now enabled for this session.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SpColors.privateAccent, fontSize: 12),
                  ),
                ],
                const Spacer(),
                const Text(
                  'Verification is per session. Because no long-term trust state is stored, '
                  'you compare the code each time you start talking.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6C7488),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
