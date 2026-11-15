/// Pairing: the only way a device becomes authorised.
///

/// Local mode: the laptop shows a QR with a one-time invitation; the phone
/// redeems it over the LAN and registers its public device identity.
/// Cloud mode: the first device creates the pair and displays a QR; the second
/// device redeems it. Afterwards the server holds exactly two public identities
/// and no third slot exists.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import '../cryptography/olm_service.dart';
import '../security/secure_store.dart';
import '../storage/prefs.dart';
import 'protocol.dart';

class PairingException implements Exception {
  PairingException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'PairingException($code): $message';
}

class PairCredentials {
  const PairCredentials({
    required this.pairId,
    required this.role,
    required this.wsUrl,
    required this.isLocal,
    this.peerDeviceId,
    this.peerOlmKey,
  });

  final String pairId;
  final String role;
  final String wsUrl;

  /// Network mode is explicit and is never inferred from a stored bearer token.
  final bool isLocal;

  final String? peerDeviceId;
  final String? peerOlmKey;
}

class CreatedPair {
  const CreatedPair({
    required this.credentials,
    required this.qrPayload,
    required this.expiresAt,
  });

  final PairCredentials credentials;
  final String qrPayload;
  final int expiresAt;
}

class PairingService {
  PairingService(this._store, {OlmService Function()? olm}) : _olm = olm;

  final SecureStore _store;

  /// Supplied lazily because the Olm account is created after the first unlock.
  final OlmService Function()? _olm;

  static const Duration _timeout = Duration(seconds: 12);

  /// Where the Worker lives, so revocation and reconnects do not need the user
  /// to paste the URL again.
  static const String _cloudBaseKey = 'sp.cloud.base';

  Future<Map<String, dynamic>> _postJson(
    String url,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(Uri.parse(url)).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();
      if (text.isEmpty) {
        throw PairingException(
          'The relay sent an empty response.',
          code: 'empty_response',
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw PairingException(
          'The relay response was not JSON.',
          code: 'bad_response',
        );
      }
      if (response.statusCode >= 400) {
        throw PairingException(
          '${decoded['detail'] ?? 'The relay refused the request.'}',
          code: '${decoded['error'] ?? response.statusCode}',
        );
      }
      return decoded;
    } on SocketException {
      throw PairingException(
        'Cannot reach the relay. Check the hotspot and the address.',
        code: 'unreachable',
      );
    } on TimeoutException {
      throw PairingException(
        'The relay did not answer in time.',
        code: 'timeout',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();
      if (text.isEmpty) {
        throw PairingException('The relay sent an empty response.', code: 'empty_response');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw PairingException('The relay response was not JSON.', code: 'bad_response');
      }
      if (response.statusCode >= 400) {
        throw PairingException(
          '${decoded['detail'] ?? 'The relay refused the request.'}',
          code: '${decoded['error'] ?? response.statusCode}',
        );
      }
      return decoded;
    } on SocketException {
      throw PairingException('Cannot reach the local relay. Check the hotspot and address.', code: 'unreachable');
    } on TimeoutException {
      throw PairingException('The local relay did not answer in time.', code: 'timeout');
    } finally {
      client.close(force: true);
    }
  }

  /// Local / offline mode: prove possession of the QR invitation over a
  /// one-use challenge. The raw invitation is never sent over cleartext LAN.
  Future<PairCredentials> joinLocal({
    required PairingPayload payload,
    required OlmIdentity identity,
  }) async {
    if (payload.isExpired) {
      throw PairingException(
        'This pairing code has expired. Ask for a fresh one.',
        code: 'expired',
      );
    }
    final base = payload.httpUrl;
    if (base == null) {
      throw PairingException(
        'The pairing code is missing the local server address.',
        code: 'bad_payload',
      );
    }
    final challengeResponse = await _getJson(
      '$base/v1/pair/challenge?pairId=${Uri.encodeQueryComponent(payload.pairId)}',
    );
    final challenge = challengeResponse['challenge'];
    final challengePairId = challengeResponse['pairId'];
    final expiresAt = challengeResponse['expiresAt'];
    if (challenge is! String ||
        challenge.length < 24 ||
        challengePairId != payload.pairId ||
        expiresAt is! num ||
        expiresAt.toInt() <= DateTime.now().millisecondsSinceEpoch) {
      throw PairingException('The local relay returned an invalid pairing challenge.', code: 'bad_challenge');
    }

    final proofContext = <String, dynamic>{
      'domain': 'secretplay.local-pairing.v1',
      'pairId': payload.pairId,
      'challenge': challenge,
      'deviceId': identity.deviceId,
      'publicKey': identity.ed25519PublicKey,
      'olmKey': identity.curve25519PublicKey,
    };
    final inviteKey = crypto.sha256
        .convert(utf8.encode('secretplay.invite.v1|${payload.invite}'))
        .bytes;
    final proof = crypto.Hmac(crypto.sha256, inviteKey)
        .convert(utf8.encode(canonicalJson(proofContext)))
        .bytes;

    final response = await _postJson('$base/v1/pair/register', {
      'challenge': challenge,
      'proof': encodeB64u(proof),
      'deviceId': identity.deviceId,
      'publicKey': identity.ed25519PublicKey,
      'olmKey': identity.curve25519PublicKey,
    });
    // The response arrives over the local bootstrap transport. Do not accept
    // a relay URL or pair identifier that differs from the physically scanned
    // QR payload; this prevents a LAN response from redirecting the client.
    if (response['pairId'] != payload.pairId || response['wsUrl'] != payload.wsUrl) {
      throw PairingException(
        'The local relay response did not match the scanned pairing code.',
        code: 'pairing_mismatch',
      );
    }
    if (response['role'] != 'A' && response['role'] != 'B') {
      throw PairingException('The local relay returned an invalid device slot.', code: 'bad_response');
    }

    final credentials = PairCredentials(
      pairId: '${response['pairId']}',
      role: '${response['role']}',
      wsUrl: '${response['wsUrl'] ?? payload.wsUrl}',
      isLocal: true,
      peerDeviceId: _peerField(response, 'deviceId'),
      peerOlmKey: _peerField(response, 'olmIdentityKey'),
    );
    await _persist(credentials, NetworkMode.local);
    return credentials;
  }


  String _normaliseHttpsOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw PairingException(
        'Cloud mode requires an HTTPS origin without a path, query, or credentials.',
        code: 'invalid_cloud_origin',
      );
    }
    return uri.replace(path: '').toString().replaceFirst(RegExp(r'/+$'), '');
  }

  /// Cloud mode, first device: create the pair and show the QR.
  Future<CreatedPair> createCloud({
    required String cloudBaseUrl,
    required OlmIdentity identity,
  }) async {
    final cloudOrigin = _normaliseHttpsOrigin(cloudBaseUrl);
    final response = await _postJson('$cloudOrigin/v1/pair/create', {
      'deviceId': identity.deviceId,
      'publicKey': identity.ed25519PublicKey,
      'olmKey': identity.curve25519PublicKey,
    });
    final credentials = PairCredentials(
      pairId: '${response['pairId']}',
      role: '${response['role']}',
      wsUrl: '${response['wsUrl']}',
      isLocal: false,
    );
    await _store.write(_cloudBaseKey, cloudOrigin);
    await _persist(credentials, NetworkMode.cloud);
    return CreatedPair(
      credentials: credentials,
      qrPayload: '${response['qr']}',
      expiresAt: (response['inviteExpiresAt'] as num).toInt(),
    );
  }

  /// Cloud mode, second device: scan the first device's QR.
  Future<PairCredentials> joinCloud({
    required String cloudBaseUrl,
    required PairingPayload payload,
    required OlmIdentity identity,
  }) async {
    final cloudOrigin = _normaliseHttpsOrigin(cloudBaseUrl);
    if (payload.isExpired) {
      throw PairingException('This pairing code has expired.', code: 'expired');
    }
    final response = await _postJson('$cloudOrigin/v1/pair/register', {
      'pairId': payload.pairId,
      'invite': payload.invite,
      'deviceId': identity.deviceId,
      'publicKey': identity.ed25519PublicKey,
      'olmKey': identity.curve25519PublicKey,
    });
    if (response['pairId'] != payload.pairId ||
        response['wsUrl'] != payload.wsUrl ||
        response['role'] != 'A' && response['role'] != 'B') {
      throw PairingException('The relay response did not match the scanned pairing code.', code: 'pairing_mismatch');
    }
    final credentials = PairCredentials(
      pairId: '${response['pairId']}',
      role: '${response['role']}',
      wsUrl: '${response['wsUrl'] ?? payload.wsUrl}',
      isLocal: false,
      peerDeviceId: _peerField(response, 'deviceId'),
      peerOlmKey: _peerField(response, 'olmIdentityKey'),
    );
    await _store.write(_cloudBaseKey, cloudOrigin);
    await _persist(credentials, NetworkMode.cloud);
    return credentials;
  }

  String? _peerField(Map<String, dynamic> response, String key) {
    final peer = response['peer'];
    if (peer is Map<String, dynamic>) return peer[key]?.toString();
    return null;
  }

  String _modeKey(NetworkMode mode, String suffix) => 'sp.${mode.name}.$suffix';

  Future<void> _persist(PairCredentials credentials, NetworkMode mode) async {
    // Keep Cloud and Local credentials independently namespaced. The generic
    // keys are mirrored only for compatibility with recovery/export UI.
    await _store.write(_modeKey(mode, 'pairId'), credentials.pairId);
    await _store.write(_modeKey(mode, 'role'), credentials.role);
    await _store.write(_modeKey(mode, 'wsUrl'), credentials.wsUrl);
    await _store.write(SecureKeys.networkMode, mode.name);
    if (credentials.peerDeviceId != null) {
      await _store.write(_modeKey(mode, 'peerDeviceId'), credentials.peerDeviceId!);
      await _store.write(SecureKeys.peerDeviceId, credentials.peerDeviceId!);
    } else {
      await _store.delete(_modeKey(mode, 'peerDeviceId'));
      await _store.delete(SecureKeys.peerDeviceId);
    }
    if (credentials.peerOlmKey != null) {
      await _store.write(_modeKey(mode, 'peerOlmKey'), credentials.peerOlmKey!);
      await _store.write(SecureKeys.peerPublicKey, credentials.peerOlmKey!);
    } else {
      await _store.delete(_modeKey(mode, 'peerOlmKey'));
      await _store.delete(SecureKeys.peerPublicKey);
    }

    await _store.write(SecureKeys.pairId, credentials.pairId);
    await _store.write(SecureKeys.role, credentials.role);
    await _store.write(
      mode == NetworkMode.local ? SecureKeys.localWsUrl : SecureKeys.cloudWsUrl,
      credentials.wsUrl,
    );
    // Remove legacy bearer-token artifacts. WebSocket authentication is a
    // signed Ed25519 hello in both modes; no bearer secret is persisted.
    if (mode == NetworkMode.local) await _store.delete('sp.local.token');
  }

  /// Load credentials only from the selected transport's namespace. Legacy
  /// metadata is migrated only if its stored active mode matches.
  Future<PairCredentials?> loadSaved({NetworkMode? mode}) async {
    final rawMode = await _store.read(SecureKeys.networkMode);
    final resolved =
        mode ?? (rawMode == 'local' ? NetworkMode.local : NetworkMode.cloud);
    final canMigrateLegacy = rawMode == resolved.name;

    Future<String?> readProfile(String suffix, String legacyKey) async {
      final stored = await _store.read(_modeKey(resolved, suffix));
      if (stored != null) return stored;
      if (!canMigrateLegacy) return null;
      final legacy = await _store.read(legacyKey);
      if (legacy != null) await _store.write(_modeKey(resolved, suffix), legacy);
      return legacy;
    }

    final pairId = await readProfile('pairId', SecureKeys.pairId);
    final role = await readProfile('role', SecureKeys.role);
    final wsUrl = await readProfile(
      'wsUrl',
      resolved == NetworkMode.local ? SecureKeys.localWsUrl : SecureKeys.cloudWsUrl,
    );
    if (pairId == null || role == null || wsUrl == null) return null;

    return PairCredentials(
      pairId: pairId,
      role: role,
      wsUrl: wsUrl,
      isLocal: resolved == NetworkMode.local,
      peerDeviceId: await readProfile('peerDeviceId', SecureKeys.peerDeviceId),
      peerOlmKey: await readProfile('peerOlmKey', SecureKeys.peerPublicKey),
    );
  }

  /// Local-mode shortcut kept for older call sites.
  Future<PairCredentials?> loadLocal() => loadSaved(mode: NetworkMode.local);

  /// Revoke the other device's slot through the Worker, signed with this
  /// device's Ed25519 identity. The Worker verifies the signature against the
  /// public key it registered; nothing secret leaves the phone.
  Future<String> revokePeerFromCloud() async {
    final base = await _store.read(_cloudBaseKey);
    final pairId = await _store.read(_modeKey(NetworkMode.cloud, 'pairId'));
    final role = await _store.read(_modeKey(NetworkMode.cloud, 'role'));
    final deviceId = await _store.read(SecureKeys.deviceId);
    if (base == null || pairId == null || role == null || deviceId == null) {
      throw PairingException(
        'This device has no cloud pairing to revoke.',
        code: 'not_paired',
      );
    }
    final targetRole = role == 'A' ? 'B' : 'A';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final nonce = randomBase64u(12);
    final service = _olm?.call();
    if (service == null) {
      throw PairingException(
        'The identity is not loaded yet. Unlock and try again.',
        code: 'no_identity',
      );
    }
    final signature = service.signRevoke(
      pairId: pairId,
      role: role,
      deviceId: deviceId,
      targetRole: targetRole,
      ts: ts,
      nonce: nonce,
    );
    final origin = _normaliseHttpsOrigin(base);
    final response = await _postJson('$origin/v1/pair/revoke', {
      'pairId': pairId,
      'request': {
        'requesterRole': role,
        'requesterDeviceId': deviceId,
        'targetRole': targetRole,
        'ts': ts,
        'nonce': nonce,
        'sig': signature,
      },
    });
    final revoked = response['revoked'];
    final revokedRole = revoked is Map ? revoked['role'] : targetRole;
    final newInvite = response['invite'];
    await forgetMode(NetworkMode.cloud);
    if (newInvite != null) {
      return 'Slot $revokedRole was revoked on the relay. New invitation: ' + newInvite + '. Scan the QR to pair again.';
    }
    return 'Slot $revokedRole was revoked on the relay. Re-pair to use it again.';
  }

  Future<void> _forgetMode(NetworkMode mode) async {
    for (final suffix in [
      'pairId', 'role', 'wsUrl', 'token', 'peerDeviceId', 'peerOlmKey',
    ]) {
      await _store.delete(_modeKey(mode, suffix));
    }
    await _store.delete(
      mode == NetworkMode.local ? SecureKeys.localWsUrl : SecureKeys.cloudWsUrl,
    );
    if (mode == NetworkMode.cloud) await _store.delete(_cloudBaseKey);
  }

  /// Forget one transport profile without destroying the other profile.
  Future<void> forgetMode(NetworkMode mode) async {
    await _forgetMode(mode);
    final active = await _store.read(SecureKeys.networkMode);
    if (active == mode.name) {
      final other = mode == NetworkMode.cloud ? NetworkMode.local : NetworkMode.cloud;
      final replacement = await loadSaved(mode: other);
      if (replacement != null) {
        await _store.write(SecureKeys.pairId, replacement.pairId);
        await _store.write(SecureKeys.role, replacement.role);
        if (replacement.peerDeviceId != null) {
          await _store.write(SecureKeys.peerDeviceId, replacement.peerDeviceId!);
        } else {
          await _store.delete(SecureKeys.peerDeviceId);
        }
        if (replacement.peerOlmKey != null) {
          await _store.write(SecureKeys.peerPublicKey, replacement.peerOlmKey!);
        } else {
          await _store.delete(SecureKeys.peerPublicKey);
        }
      } else {
        await _store.delete(SecureKeys.pairId);
        await _store.delete(SecureKeys.role);
        await _store.delete(SecureKeys.peerDeviceId);
        await _store.delete(SecureKeys.peerPublicKey);
      }
    }
  }

  /// Forget both network profiles and their compatibility metadata.
  Future<void> forget() async {
    for (final mode in NetworkMode.values) {
      await _forgetMode(mode);
    }
    await _store.delete(SecureKeys.pairId);
    await _store.delete(SecureKeys.role);
    await _store.delete('sp.local.token');
    await _store.delete(SecureKeys.peerDeviceId);
    await _store.delete(SecureKeys.peerPublicKey);
    await _store.delete(SecureKeys.localWsUrl);
    await _store.delete(SecureKeys.cloudWsUrl);
  }
}
