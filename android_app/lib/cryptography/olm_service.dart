/// End-to-end encryption.
///
/// Uses **vodozemac** (the Rust Olm/Double-Ratchet implementation maintained by
/// the Matrix project) through `flutter_vodozemac`. No cryptography is
/// implemented by hand here: this class only drives the library's
/// Account/Session/Sas APIs and the app's storage.
///
/// Design decisions that follow from "session only":
///  * the long-term Account (identity keys) is persisted, encrypted, because the
///    relay binds device ids to the Ed25519 identity key;
///  * the Olm *session* is never persisted. Every unlocked session starts a
///    fresh ratchet, and [forgetSession] destroys it on lock;
///  * one-time keys are generated per session and only their public halves
///    travel (through the relay, never stored).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_vodozemac/flutter_vodozemac.dart' as fv;
import 'package:vodozemac/vodozemac.dart';
import 'package:crypto/crypto.dart' as sha;

import '../core/ids.dart';
import '../networking/protocol.dart';
import '../security/secure_store.dart';

class OlmIdentity {
  const OlmIdentity({
    required this.deviceId,
    required this.ed25519PublicKey,
    required this.curve25519PublicKey,
  });

  final String deviceId;

  /// Base64url Ed25519 key: the relay authenticates this (cloud mode) and
  /// derives the device id from it.
  final String ed25519PublicKey;

  /// Base64url Curve25519 key: what the peer uses for Olm.
  final String curve25519PublicKey;
}

class OlmException implements Exception {
  OlmException(this.message);

  final String message;

  @override
  String toString() => 'OlmException: $message';
}

class DecryptedPayload {
  const DecryptedPayload({required this.type, required this.text});

  /// 0 = pre-key message (session bootstrap), 1 = normal ratchet message.
  final int type;
  final String text;
}

class OlmService {
  Account? _account;
  Session? _session;
  Sas? _sas;
  String? _peerIdentityKey;
  String? _announcedOneTimeKey;

  bool get hasSession => _session != null;

  String? get ed25519PublicKey => _account == null
      ? null
      : encodeB64u(_account!.ed25519Key.toBytes());

  static Future<void> initialise() async {
    if (!isInitialized()) {
      await fv.init();
    }
  }

  /// Loads the persisted Account or creates one. [pickleKey] is a 32-byte
  /// random secret held in the Keystore; it is the only thing that can decrypt
  /// the pickled identity at rest.
  Future<OlmIdentity> ensureIdentity({
    required SecureStore store,
    required List<int> pickleKey,
  }) async {
    await initialise();
    if (_account == null) {
      final stored = await store.read(SecureKeys.olmAccountPickle);
      if (stored != null) {
        _account = Account.fromPickleEncrypted(
          pickle: stored,
          pickleKey: Uint8List.fromList(pickleKey),
        );
      } else {
        _account = Account();
      }
    }

    final account = _account!;
    // Relays use strict unpadded Base64URL, while Vodozemac toBase64() uses
    // the standard Base64 alphabet. Encode raw key bytes through our shared
    // Base64URL helper so signatures, device IDs and relay validation agree.
    final ed = encodeB64u(account.ed25519Key.toBytes());
    final curve = encodeB64u(account.curve25519Key.toBytes());
    final deviceId = deviceIdFromEd25519(ed);

    final pickle = account.toPickleEncrypted(Uint8List.fromList(pickleKey));
    if (await store.read(SecureKeys.olmAccountPickle) != pickle) {
      await store.write(SecureKeys.olmAccountPickle, pickle);
    }
    if (await store.read(SecureKeys.deviceId) != deviceId) {
      await store.write(SecureKeys.deviceId, deviceId);
    }
    return OlmIdentity(
      deviceId: deviceId,
      ed25519PublicKey: ed,
      curve25519PublicKey: curve,
    );
  }

  /// Ed25519 signature over the canonical hello payload.
  ///
  /// The field order and domain string must match
  /// `crypto_core/src/auth.ts` exactly, or cloud-mode authentication fails.
  String signHello({
    required String pairId,
    required String deviceId,
    required String role,
    required int ts,
    required String nonce,
    required Map<String, String> olm,
  }) {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');
    final payload = canonicalJson({
      'domain': 'secretplay.hello.v1',
      'proto': 'sp1',
      'v': 1,
      'pairId': pairId,
      'deviceId': deviceId,
      'role': role,
      'ts': ts,
      'nonce': nonce,
      'olm': olm,
    });
    return encodeB64u(account.sign(payload).toBytes());
  }

  /// Ed25519 signature over the canonical revoke payload.
  ///
  /// Field order and domain string must match `crypto_core/src/admin.ts`.
  String signRevoke({
    required String pairId,
    required String role,
    required String deviceId,
    required String targetRole,
    required int ts,
    required String nonce,
  }) {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');
    final payload = canonicalJson({
      'domain': 'secretplay.revoke.v1',
      'proto': 'sp1',
      'v': 1,
      'pairId': pairId,
      'requesterRole': role,
      'requesterDeviceId': deviceId,
      'targetRole': targetRole,
      'ts': ts,
      'nonce': nonce,
    });
    return encodeB64u(account.sign(payload).toBytes());
  }

  /// Stable device id: SHA-256 of the Ed25519 key, first 16 bytes, base64url,
  /// `d_` prefix — identical to `deviceIdFromPublicKey` on the relays.
  static String deviceIdFromEd25519(String base64Key) {
    final digest = sha.sha256.convert(decodeB64u(base64Key)).bytes;
    return 'd_${encodeB64u(digest.sublist(0, 16))}';
  }

  /// Generate fresh one-time keys and return the public material to announce in
  /// the hello frame.
  Map<String, String> announceKeys() {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');
    // Discard stale, unused keys from previous sessions. This application has
    // no offline delivery, so a previous session's pre-key must never be reused.
    for (final oldKey in account.oneTimeKeys.values.toList()) {
      account.removeOneTimeKey(oldKey.toBase64());
    }
    account.generateOneTimeKeys(1);
    final keys = account.oneTimeKeys;
    if (keys.isEmpty) throw OlmException('no one-time keys were generated');
    final entry = keys.entries.first;
    _announcedOneTimeKey = entry.value.toBase64();
    account.markKeysAsPublished();
    return {
      'identityKey': encodeB64u(account.curve25519Key.toBytes()),
      'oneTimeKey': encodeB64u(entry.value.toBytes()),
    };
  }

  /// Role A initiates: create the outbound session from the peer's identity and
  /// one-time key. Returns false when the peer's material is missing.
  Curve25519PublicKey _curveKeyFromB64u(String value) {
    final bytes = decodeB64u(value);
    if (bytes.length != 32) {
      throw OlmException('Curve25519 public keys must be exactly 32 bytes');
    }
    return Curve25519PublicKey.fromBytes(Uint8List.fromList(bytes));
  }

  bool startOutboundSession({
    required String peerIdentityKey,
    required String peerOneTimeKey,
  }) {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');
    if (peerIdentityKey.isEmpty || peerOneTimeKey.isEmpty) return false;
    try {
      _session = account.createOutboundSession(
        identityKey: _curveKeyFromB64u(peerIdentityKey),
        oneTimeKey: _curveKeyFromB64u(peerOneTimeKey),
      );
      _peerIdentityKey = peerIdentityKey;
      return true;
    } catch (_) {
      _session = null;
      return false;
    }
  }

  /// Encrypt for the peer. Throws if there is no session yet, so callers cannot
  /// accidentally send plaintext.
  ({String ciphertext, int messageType}) encrypt(String plaintext) {
    final session = _session;
    if (session == null) throw OlmException('no Olm session: refusing to send');
    final result = session.encrypt(plaintext);
    return (
      ciphertext: standardBase64ToB64u(result.ciphertext),
      messageType: result.messageType,
    );
  }

  /// Decrypt an incoming envelope. Pre-key messages (type 0) bootstrap the
  /// inbound session; [senderIdentityKey] must match what the relay announced.
  DecryptedPayload decrypt({
    required int messageType,
    required String ciphertext,
    required String senderIdentityKey,
  }) {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');

    if (_session != null &&
        _peerIdentityKey != null &&
        _peerIdentityKey != senderIdentityKey) {
      // A different device cannot be part of this pair's session.
      throw OlmException('sender identity does not match the paired device');
    }

    // Olm wire envelopes use Base64URL; the Vodozemac API expects standard
    // Base64. Decode and re-encode explicitly at this boundary.
    final standardCiphertext = b64uToStandardBase64(ciphertext);
    if (messageType == 0) {
      final result = account.createInboundSession(
        theirIdentityKey: _curveKeyFromB64u(senderIdentityKey),
        preKeyMessageBase64: standardCiphertext,
      );
      _session = result.session;
      _peerIdentityKey = senderIdentityKey;
      final consumedKey = _announcedOneTimeKey;
      if (consumedKey != null) {
        try {
          account.removeOneTimeKey(consumedKey);
        } catch (_) {
          // The inbound-session API may already have consumed it.
        }
        _announcedOneTimeKey = null;
      }
      return DecryptedPayload(type: messageType, text: result.plaintext);
    }

    final session = _session;
    if (session == null) throw OlmException('no Olm session for this message');
    final text = session.decrypt(
      messageType: messageType,
      ciphertext: standardCiphertext,
    );
    return DecryptedPayload(type: messageType, text: text);
  }

  /// Build the Olm envelope that travels through the relay.
  CipherEnvelope seal(String plaintext, {required String frameId}) {
    final result = encrypt(plaintext);
    final identity = encodeB64u(_account!.curve25519Key.toBytes());
    return CipherEnvelope(
      senderKey: identity,
      kind: result.messageType,
      body: result.ciphertext,
      msgId: frameId,
      sentAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  String openEnvelope(CipherEnvelope envelope) => decrypt(
    messageType: envelope.kind,
    ciphertext: envelope.body,
    senderIdentityKey: envelope.senderKey,
  ).text;

  /// SAS verification. Both devices show the same six digits; the relay never
  /// sees either SAS key.
  String beginSas() {
    _sas = Sas();
    return _sas!.publicKey;
  }

  /// Derive a 6-digit code from the established SAS bytes.
  String sasCode(
    String theirSasPublicKey, {
    required String transcript,
  }) {
    final sas = _sas;
    if (sas == null) throw OlmException('call beginSas first');
    final established = sas.establishSasSecret(theirSasPublicKey);
    // Bind the ephemeral SAS secret to the authenticated pair, session, and
    // both stable signing identities. A relay-created split session therefore
    // produces different comparison codes on the two devices.
    final sasBytes = established.generateBytes(
      'secretplay.sas-code.v1|$transcript',
      32,
    );
    final digest = sha.sha256.convert(sasBytes).bytes;
    final value =
        ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) &
        0x7fffffff;
    return (value % 1000000).toString().padLeft(6, '0');
  }

  /// Clears the ratchet. Called on lock and on session end — the next session
  /// starts from new one-time keys.
  void forgetSession() {
    _session = null;
    _peerIdentityKey = null;
    _sas = null;
    final account = _account;
    final unusedKey = _announcedOneTimeKey;
    if (account != null && unusedKey != null) {
      try {
        account.removeOneTimeKey(unusedKey);
      } catch (_) {
        // Best effort: vodozemac may already have consumed the one-time key.
      }
    }
    _announcedOneTimeKey = null;
  }

  /// Drop the long-lived account object from application reachability on lock.
  /// The encrypted pickle remains in secure storage and is reloaded only after
  /// the next successful local authentication. Physical RAM erasure cannot be
  /// guaranteed by Dart/FFI garbage collection.
  void unloadIdentity() {
    forgetSession();
    _account = null;
  }

  /// Used by recovery to describe the identity without exporting private keys.
  String? get identityFingerprint {
    final account = _account;
    if (account == null) return null;
    final digest = sha.sha256
        .convert(account.ed25519Key.toBytes())
        .bytes;
    return encodeB64u(digest.sublist(0, 8));
  }

  /// Restores an identity from a recovery package's encrypted pickle blob.
  Future<void> restoreIdentity({
    required SecureStore store,
    required List<int> pickleKey,
    required String encryptedPickle,
  }) async {
    await initialise();
    // Validating before overwriting prevents a corrupt package from destroying
    // a working identity.
    final restored = Account.fromPickleEncrypted(
      pickle: encryptedPickle,
      pickleKey: Uint8List.fromList(pickleKey),
    );
    _account = restored;
    await store.write(
      SecureKeys.olmAccountPickle,
      restored.toPickleEncrypted(Uint8List.fromList(pickleKey)),
    );
  }

  /// Exports the current identity for an encrypted recovery package. The caller
  /// encrypts it with Argon2id + XChaCha20-Poly1305 before it leaves the device;
  /// it never goes to the server.
  String exportIdentityPickle(List<int> pickleKey) {
    final account = _account;
    if (account == null) throw OlmException('identity is not loaded');
    return base64Encode(
      utf8.encode(account.toPickleEncrypted(Uint8List.fromList(pickleKey))),
    );
  }

  String newSessionNonce() => randomBase64u(12);
}
