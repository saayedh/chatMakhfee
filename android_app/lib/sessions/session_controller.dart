/// The live, session-only private channel.
///
/// This controller owns the relay socket, the in-memory Olm ratchet, the
/// ephemeral message list and the session heartbeat. No message or call
/// content is written to persistent storage.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../authentication/lock_controller.dart';
import '../chat/message_model.dart';
import '../core/ids.dart';
import '../cryptography/olm_service.dart';
import '../networking/pairing_service.dart';
import '../networking/protocol.dart';
import '../networking/transport.dart';
import '../security/secure_store.dart';
import '../storage/prefs.dart';
import '../voice/call_signals.dart';
import 'session_state.dart';

class SessionView {
  const SessionView({
    required this.snapshot,
    required this.messages,
    this.peerVerified = false,
    this.peerConfirmed = false,
    this.notice,
  });

  final SessionSnapshot snapshot;
  final List<ChatMessage> messages;

  /// This device's user has compared and approved the SAS code.
  final bool peerVerified;

  /// The other device has independently approved the same session transcript.
  final bool peerConfirmed;

  final String? notice;

  /// Messaging and calls are disabled until verification is bilateral.
  bool get canSend => snapshot.canSend && peerVerified && peerConfirmed;

  SessionView copyWith({
    SessionSnapshot? snapshot,
    List<ChatMessage>? messages,
    bool? peerVerified,
    bool? peerConfirmed,
    String? notice,
    bool clearNotice = false,
  }) => SessionView(
    snapshot: snapshot ?? this.snapshot,
    messages: messages ?? this.messages,
    peerVerified: peerVerified ?? this.peerVerified,
    peerConfirmed: peerConfirmed ?? this.peerConfirmed,
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

final sessionProvider = NotifierProvider<SessionController, SessionView>(
  SessionController.new,
);

class SessionController extends Notifier<SessionView> {
  RelayTransport? _transport;
  SessionMachine _machine = SessionMachine();
  Timer? _ticker;
  OlmService? _olm;
  PairCredentials? _credentials;
  String? _peerOlmIdentity;
  String? _peerOneTimeKey;
  String? _peerDeviceId;
  String? _peerSigningKey;
  String? _localDeviceId;
  String? _localSigningKey;
  String? _localOlmIdentity;
  String? _localOneTimeKey;
  bool _bootstrapSent = false;

  @override
  SessionView build() {
    ref.onDispose(_teardown);
    return SessionView(snapshot: _machine.snapshot, messages: const []);
  }

  OlmService get olm {
    final current = _olm;
    if (current != null) return current;
    final created = ref.read(olmServiceProvider);
    _olm = created;
    return created;
  }

  SecureStore get _store => ref.read(secureStoreProvider);

  /// True when the two-device relay is live and the Olm session exists. This
  /// is the prerequisite for exchanging SAS verification messages.
  bool get canVerify => _machine.snapshot.canSend && olm.hasSession && verificationTranscript != null;

  /// True only after this user and the peer independently approve the same
  /// cryptographically context-bound SAS transcript.
  bool get canSignal => state.canSend && olm.hasSession;

  /// Canonical, order-independent context for the SAS comparison. Including
  /// the pair, shared relay session, both device IDs and both Ed25519 identity
  /// keys makes a split/mitm session display a different code on each device.
  String? get verificationTranscript {
    final credentials = _credentials;
    final sessionId = _machine.snapshot.sessionId;
    final localDevice = _localDeviceId;
    final localSigning = _localSigningKey;
    final localOlmIdentity = _localOlmIdentity;
    final localOneTime = _localOneTimeKey;
    final peerDevice = _peerDeviceId;
    final peerSigning = _peerSigningKey;
    final peerOlmIdentity = _peerOlmIdentity;
    final peerOneTime = _peerOneTimeKey;
    if (credentials == null ||
        sessionId == null ||
        localDevice == null ||
        localSigning == null ||
        localOlmIdentity == null ||
        localOneTime == null ||
        peerDevice == null ||
        peerSigning == null ||
        peerOlmIdentity == null ||
        peerOneTime == null) {
      return null;
    }
    final endpoints = [
      {
        'deviceId': localDevice,
        'signingKey': localSigning,
        'olmIdentityKey': localOlmIdentity,
        'oneTimeKey': localOneTime,
      },
      {
        'deviceId': peerDevice,
        'signingKey': peerSigning,
        'olmIdentityKey': peerOlmIdentity,
        'oneTimeKey': peerOneTime,
      },
    ]..sort((a, b) => (a['deviceId'] as String).compareTo(b['deviceId'] as String));
    return canonicalJson({
      'domain': 'secretplay.sas.transcript.v1',
      'protocol': Protocol.id,
      'version': Protocol.version,
      'pairId': credentials.pairId,
      'sessionId': sessionId,
      'endpoints': endpoints,
    });
  }

  /// Connect, authenticate, and wait for the other authorised device.
  Future<void> connect({
    required PairCredentials credentials,
    required bool cloudMode,
  }) async {
    if (ref.read(lockControllerProvider).isLocked) {
      throw StateError('Unlock SecretPlay before opening a secure session.');
    }
    if (_transport?.isConnected ?? false) return;

    _credentials = credentials;
    _peerOlmIdentity = credentials.peerOlmKey;
    _peerDeviceId = credentials.peerDeviceId;
    _peerOneTimeKey = null;
    _peerSigningKey = null;
    _bootstrapSent = false;
    _machine = SessionMachine();
    _machine.start();
    state = SessionView(snapshot: _machine.snapshot, messages: const []);

    final identity = await olm.ensureIdentity(
      store: _store,
      pickleKey: await ref.read(deviceSecretProvider.future),
    );
    _localDeviceId = identity.deviceId;
    _localSigningKey = identity.ed25519PublicKey;
    final olmKeys = olm.announceKeys();
    _localOlmIdentity = olmKeys['identityKey'];
    _localOneTimeKey = olmKeys['oneTimeKey'];

    final ts = DateTime.now().millisecondsSinceEpoch;
    final nonce = olm.newSessionNonce();
    final hello = Frame.helloSigned(
      pairId: credentials.pairId,
      deviceId: identity.deviceId,
      role: credentials.role,
      ts: ts,
      nonce: nonce,
      signature: olm.signHello(
        pairId: credentials.pairId,
        deviceId: identity.deviceId,
        role: credentials.role,
        ts: ts,
        nonce: nonce,
        olm: olmKeys,
      ),
      // The signature authenticates these exact Olm bootstrap keys.
      olm: olmKeys,
    );

    final transport = RelayTransport(url: credentials.wsUrl);
    _transport = transport;
    transport.events.listen(_onEvent);
    await transport.connect(hello);
    _startTicker();
    _publish();
  }

  void _clearNotice() {
    state = state.copyWith(clearNotice: true);
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_machine.timedOut) {
        _machine.end(EndReason.timeout);
        unawaited(_lock('timeout'));
        return;
      }
      if (_machine.needsPing) {
        try {
          _transport?.send(Frame.ping(DateTime.now().millisecondsSinceEpoch));
          _machine.onPingSent();
        } catch (_) {
          _machine.end(EndReason.transportError);
          unawaited(_lock('transport_error'));
        }
      }
      _publish();
    });
  }

  void _onEvent(TransportEvent event) {
    switch (event) {
      case FrameReceived(:final frame):
        _onFrame(frame);
      case TransportClosed():
        if (!_machine.snapshot.isLocked) {
          _machine.end(EndReason.transportError);
          unawaited(_lock('connection_lost'));
        }
    }
  }

  void _onFrame(ServerFrame frame) {
    if (!frame.isValid) {
      _machine.onError('bad_frame', null);
      _publish();
      return;
    }
    switch (frame.type) {
      case 'welcome':
        _capturePeerIdentity(frame.data['peer']);
        _machine.onWelcome(
          sessionId: '${frame.sessionId}',
          peerPresent: frame.peerPresent,
        );
        _maybeStartRatchet();
      case 'peer':
        if (frame.data['state'] == 'joined') {
          // A same-role reconnect gets a new Olm one-time key and a new
          // authenticated verification transcript. Never carry approval
          // forward from the previous socket/session.
          state = state.copyWith(peerVerified: false, peerConfirmed: false);
          _capturePeerIdentity(frame.data);
          _machine.onPeerJoined('${frame.data['deviceId'] ?? 'peer'}');
          _maybeStartRatchet();
        } else {
          _machine.end(EndReason.peerLeft);
          unawaited(_lock('peer_exit'));
        }
      case 'pong':
        _machine.onPong();
      case 'msg':
        _onIncomingMessage(frame.data);
      case 'signal':
        _machine.onRelayed();
        _onIncomingSignal(frame.data);
      case 'end':
        _machine.end(SessionMachine.reasonFromWire(frame.endReason));
        unawaited(
          _lock(frame.endReason == 'peer_locked' ? 'peer_lock' : 'peer_exit'),
        );
      case 'err':
        _machine.onError(
          frame.errorCode ?? 'error',
          frame.data['detail'] as String?,
        );
        if (frame.errorCode == 'unauthorized' ||
            frame.errorCode == 'device_revoked') {
          _machine.end(EndReason.revoked);
          unawaited(_lock('revoked'));
        }
    }
    _publish();
  }

  void _capturePeerIdentity(Object? value) {
    if (value is! Map<String, dynamic>) return;
    final identity = value['olmIdentityKey'];
    if (identity is String && identity.isNotEmpty) _peerOlmIdentity = identity;
    final oneTime = value['olmOneTimeKey'];
    if (oneTime is String && oneTime.isNotEmpty) _peerOneTimeKey = oneTime;
    final deviceId = value['deviceId'];
    if (deviceId is String && deviceId.isNotEmpty) _peerDeviceId = deviceId;
    final signingKey = value['publicKey'];
    if (signingKey is String && signingKey.isNotEmpty) {
      _peerSigningKey = signingKey;
    }
  }

  /// Role A creates the outbound Olm session and sends one encrypted bootstrap
  /// control message. Role B consumes that pre-key message to create its inbound
  /// session; it is not displayed or retained as chat history. Thereafter both
  /// roles can send normal Olm messages.
  void _maybeStartRatchet() {
    final credentials = _credentials;
    if (credentials == null || credentials.role != 'A') return;
    if (olm.hasSession || _bootstrapSent) return;
    final peerIdentity = _peerOlmIdentity;
    final peerOneTime = _peerOneTimeKey;
    final sessionId = _machine.snapshot.sessionId;
    if (peerIdentity == null || peerOneTime == null || sessionId == null) return;

    final started = olm.startOutboundSession(
      peerIdentityKey: peerIdentity,
      peerOneTimeKey: peerOneTime,
    );
    if (!started) {
      _appendNotice('Could not establish the encrypted session. Reconnect and verify the devices.');
      return;
    }

    final bootstrap = canonicalJson({
      'kind': 'secretplay.session-init',
      'version': 1,
      'pairId': credentials.pairId,
      'sessionId': sessionId,
    });
    final frameId = newFrameId(prefix: 'init');
    try {
      final envelope = olm.seal(bootstrap, frameId: frameId);
      _transport?.send(Frame.message(frameId, envelope));
      _bootstrapSent = true;
    } catch (_) {
      olm.forgetSession();
      _appendNotice('Could not initialize the encrypted session. Reconnect both devices.');
    }
  }

  bool _isBootstrap(String text) {
    try {
      final value = jsonDecode(text);
      return value is Map<String, dynamic> &&
          value['kind'] == 'secretplay.session-init' &&
          value['version'] == 1 &&
          value['pairId'] == _credentials?.pairId &&
          value['sessionId'] == _machine.snapshot.sessionId;
    } on FormatException {
      return false;
    }
  }

  void _onIncomingMessage(Map<String, dynamic> data) {
    final cipherJson = data['cipher'];
    if (cipherJson is! Map<String, dynamic>) return;
    try {
      final envelope = CipherEnvelope.fromJson(cipherJson);
      final text = olm.openEnvelope(envelope);
      if (_isBootstrap(text)) {
        // Successful pre-key decryption creates B's inbound session. Keep no
        // user-visible transcript entry for this protocol-control message.
        _publish();
        return;
      }
      if (!state.canSend) {
        _appendNotice('A message arrived before both devices completed verification and was discarded.');
        return;
      }
      _appendMessage(
        ChatMessage(
          id: envelope.msgId,
          direction: MessageDirection.incoming,
          text: text,
          at: DateTime.now(),
          status: MessageStatus.delivered,
        ),
      );
      _machine.onRelayed();
    } on Object {
      _appendNotice('A message could not be authenticated and was dropped.');
    }
  }

  /// The relay only transports ciphertext. A SAS packet is permitted before
  /// mutual verification; call signalling is not.
  Future<bool> sendSignal(String payload) async {
    if (!_machine.snapshot.canSend || !olm.hasSession) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return false;
    }
    if (decoded is! Map<String, dynamic>) return false;
    final type = decoded['type'];
    final allowedBeforeVerification = type == 'sas' || type == 'verify_ok';
    if (!allowedBeforeVerification && !canSignal) return false;
    if (type == 'verify_ok' && !state.peerVerified) return false;
    if (type == 'sas' && !canVerify) return false;

    final frameId = newFrameId(prefix: 's');
    try {
      final transport = _transport;
      if (transport == null || !transport.isConnected) return false;
      final envelope = olm.seal(payload, frameId: frameId);
      transport.send(Frame.signal(frameId, envelope));
      return true;
    } catch (_) {
      if (type != 'sas') {
        _appendNotice('A secure signalling message could not be sent.');
      }
      return false;
    }
  }

  void _onIncomingSignal(Map<String, dynamic> data) {
    final cipherJson = data['cipher'];
    if (cipherJson is! Map<String, dynamic>) return;
    try {
      final envelope = CipherEnvelope.fromJson(cipherJson);
      final text = olm.openEnvelope(envelope);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded['type'] == 'verify_ok') {
        final transcript = verificationTranscript;
        if (transcript != null &&
            decoded['sessionId'] == _machine.snapshot.sessionId &&
            decoded['transcript'] == transcript) {
          state = state.copyWith(peerConfirmed: true);
          if (state.peerVerified) {
            ref.read(callSignalsProvider.notifier).clearVerificationSignals();
          }
          _publish();
        }
        return;
      }
      ref.read(callSignalsProvider.notifier).push(text);
    } on Object {
      // Malformed, unauthenticated, replayed, or out-of-session signals drop.
    }
  }

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!canSignal) {
      _appendNotice(
        'Both devices must be connected and both participants must verify the security code first.',
      );
      return;
    }
    _clearNotice();
    final frameId = newFrameId();
    final message = ChatMessage(
      id: frameId,
      direction: MessageDirection.outgoing,
      text: trimmed,
      at: DateTime.now(),
    );
    _appendMessage(message);
    try {
      final transport = _transport;
      if (transport == null || !transport.isConnected) {
        throw StateError('relay is not connected');
      }
      final envelope = olm.seal(trimmed, frameId: frameId);
      transport.send(Frame.message(frameId, envelope));
      // The relay accepted the encrypted frame locally. This is not a remote
      // delivery receipt, so do not label it as delivered.
      message.status = MessageStatus.sent;
    } catch (_) {
      message.status = MessageStatus.failed;
      _appendNotice('Encryption failed; the message was not sent.');
    }
    _publish();
  }

  Future<bool> markPeerVerified() async {
    final transcript = verificationTranscript;
    final sessionId = _machine.snapshot.sessionId;
    if (!canVerify || transcript == null || sessionId == null) return false;
    state = state.copyWith(peerVerified: true);
    final sent = await sendSignal(
      jsonEncode({
        'type': 'verify_ok',
        'sessionId': sessionId,
        'transcript': transcript,
      }),
    );
    if (!sent) {
      state = state.copyWith(peerVerified: false, notice: 'Could not send verification approval.');
      _publish();
      return false;
    }
    if (state.peerConfirmed) {
      ref.read(callSignalsProvider.notifier).clearVerificationSignals();
    }
    _publish();
    return true;
  }

  Future<void> leave({String reason = 'user_exit'}) async {
    if (!_machine.snapshot.isLocked) {
      try {
        _transport?.send(Frame.bye(reason == 'lock' ? 'lock' : 'user_exit'));
      } catch (_) {
        // Best effort: socket closure also terminates the relay session.
      }
      _machine.end(EndReason.userExit);
    }
    await _teardown(lockReason: reason);
    state = SessionView(snapshot: _machine.snapshot, messages: const []);
  }

  /// Clear ephemeral view state without touching long-term device identity.
  Future<void> clearTransientState() async {
    ref.read(callSignalsProvider.notifier).clear();
    _ticker?.cancel();
    _ticker = null;
    state = SessionView(snapshot: _machine.snapshot, messages: const []);
  }

  /// Idempotent session teardown. This is used by all terminal paths.
  Future<void> _teardown({String? lockReason}) async {
    _ticker?.cancel();
    _ticker = null;
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.close(code: 1000, reason: lockReason ?? 'teardown');
      } catch (_) {
        // Local UI and keys are cleared even if the socket close handshake fails.
      }
    }
    try {
      olm.forgetSession();
    } catch (_) {
      // Crypto initialization may have failed before a session existed.
    }
    ref.read(callSignalsProvider.notifier).clear();
    _peerOlmIdentity = null;
    _peerOneTimeKey = null;
    _peerDeviceId = null;
    _peerSigningKey = null;
    _localDeviceId = null;
    _localSigningKey = null;
    _localOlmIdentity = null;
    _localOneTimeKey = null;
    _credentials = null;
    _bootstrapSent = false;
    state = SessionView(snapshot: _machine.snapshot, messages: const []);
  }

  Future<void> _lock(String reason) async {
    await _teardown(lockReason: reason);
    await rememberLockReason(_store, reason);
    // Cover the private UI before doing any network probing. If a Cloud
    // session died because global Internet access disappeared, probe an
    // already-paired laptop relay in the background. The next authenticated
    // entry will then load the Local profile; no session is resumed or replayed.
    final previousMode = ref.read(networkModeProvider);
    ref.read(lockControllerProvider.notifier).lockNow(reason);
    if (previousMode == NetworkMode.cloud &&
        (reason == 'connection_lost' ||
            reason == 'timeout' ||
            reason == 'transport_error')) {
      unawaited(ref.read(networkModeProvider.notifier).load());
    }
  }

  void _appendMessage(ChatMessage message) {
    final messages = [...state.messages, message];
    if (messages.length > kMaxMessagesInMemory) {
      messages.removeRange(0, messages.length - kMaxMessagesInMemory);
    }
    state = state.copyWith(messages: messages);
  }

  void _appendNotice(String notice) {
    state = state.copyWith(notice: notice);
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);

  void _publish() {
    state = state.copyWith(snapshot: _machine.snapshot);
  }
}
