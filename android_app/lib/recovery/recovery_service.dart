/// Encrypted recovery.
///
/// A recovery package is a small JSON document sealed with Argon2id (key
/// derivation) + XChaCha20-Poly1305 (AEAD). It is byte-compatible with
/// `crypto_core/src/recovery.ts`, so the command-line tooling can inspect it.
///
/// It contains only pair membership metadata: pair id, slot, the old device's
/// *public* identity key, the peer's public key and timestamps. It contains no
/// messages, no ratchet state and no private key. Restoring it re-establishes
/// which pair to rejoin; the new device generates a fresh identity and the peer
/// must approve it through the SAS flow.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../networking/protocol.dart';

class RecoveryException implements Exception {
  RecoveryException(this.message);

  final String message;

  @override
  String toString() => 'RecoveryException: $message';
}

class RecoveryInfo {
  const RecoveryInfo({
    required this.pairId,
    required this.role,
    required this.oldDeviceId,
    required this.oldIdentityPublicKey,
    required this.peerDeviceId,
    required this.peerPublicKey,
    required this.createdAt,
    required this.recoveryId,
    this.label = '',
  });

  final String pairId;
  final String role;
  final String oldDeviceId;
  final String oldIdentityPublicKey;
  final String peerDeviceId;
  final String peerPublicKey;
  final int createdAt;
  final String recoveryId;
  final String label;

  Map<String, dynamic> toJson() => {
    'pairId': pairId,
    'role': role,
    'oldDeviceId': oldDeviceId,
    'oldIdentityPublicKey': oldIdentityPublicKey,
    'peerDeviceId': peerDeviceId,
    'peerPublicKey': peerPublicKey,
    'createdAt': createdAt,
    'recoveryId': recoveryId,
    'label': label,
  };

  static RecoveryInfo fromJson(Map<String, dynamic> json) {
    String req(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw RecoveryException('recovery package is missing $key');
      }
      return value;
    }

    final createdAt = json['createdAt'];
    if (createdAt is! int)
      throw RecoveryException('recovery package has an invalid createdAt');
    for (final key in ['oldIdentityPublicKey', 'peerPublicKey']) {
      final decoded = base64Decode(req(key));
      if (decoded.length != 32)
        throw RecoveryException('recovery package has an invalid $key');
    }
    if (json['role'] != 'A' && json['role'] != 'B') {
      throw RecoveryException('recovery package has an invalid role');
    }
    return RecoveryInfo(
      pairId: req('pairId'),
      role: json['role'] as String,
      oldDeviceId: req('oldDeviceId'),
      oldIdentityPublicKey: req('oldIdentityPublicKey'),
      peerDeviceId: req('peerDeviceId'),
      peerPublicKey: req('peerPublicKey'),
      createdAt: createdAt,
      recoveryId: req('recoveryId'),
      label: (json['label'] as String?) ?? '',
    );
  }
}

class RecoveryService {
  static const int kdfMemoryKib = 65536;
  static const int kdfIterations = 3;
  static const int kdfParallelism = 1;
  static const String aadContext = 'secretplay.recovery.v1';

  final Argon2id _kdf = Argon2id(
    memory: kdfMemoryKib,
    iterations: kdfIterations,
    parallelism: kdfParallelism,
    hashLength: 32,
  );
  final Xchacha20 _aead = Xchacha20.poly1305Aead();

  /// Seals the package. The passphrase is chosen by the user and is the only
  /// way to open it.
  Future<String> seal({
    required String passphrase,
    required RecoveryInfo info,
  }) async {
    if (passphrase.length < 12) {
      throw RecoveryException(
        'The recovery passphrase must be at least 12 characters.',
      );
    }
    final salt = _randomBytes(16);
    final nonce = _aead.newNonce();
    final key = await _deriveKey(passphrase, salt);
    final plaintext = utf8.encode(canonicalJson(info.toJson()));
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode('$aadContext|v1'),
    );
    return jsonEncode({
      'v': 1,
      'kind': 'sp1-recovery-sealed',
      'kdf': {
        'name': 'argon2id',
        'm': kdfMemoryKib,
        't': kdfIterations,
        'p': kdfParallelism,
        'dkLen': 32,
      },
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'aad': aadContext,
      'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
    });
  }

  Future<RecoveryInfo> open({
    required String sealedJson,
    required String passphrase,
  }) async {
    Object? decoded;
    try {
      decoded = jsonDecode(sealedJson);
    } on FormatException {
      throw RecoveryException('This is not a SecretPlay recovery package.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw RecoveryException('This is not a SecretPlay recovery package.');
    }
    if (decoded['v'] != 1 || decoded['kind'] != 'sp1-recovery-sealed') {
      throw RecoveryException('Unsupported recovery package version.');
    }
    final kdf = decoded['kdf'];
    if (kdf is! Map<String, dynamic> ||
        kdf['name'] != 'argon2id' ||
        kdf['dkLen'] != 32) {
      throw RecoveryException('Unsupported key derivation in this package.');
    }
    final memory = kdf['m'];
    if (memory is! int || memory < 8 || memory > 1048576) {
      throw RecoveryException('Refusing implausible KDF parameters.');
    }

    final salt = base64Decode('${decoded['salt']}');
    final nonce = base64Decode('${decoded['nonce']}');
    final combined = base64Decode('${decoded['ct']}');
    if (salt.length != 16 || nonce.length != 24 || combined.length < 17) {
      throw RecoveryException('The recovery package is malformed.');
    }
    final cipherText = combined.sublist(0, combined.length - 16);
    final mac = combined.sublist(combined.length - 16);

    final key = await _deriveKey(passphrase, salt);
    List<int> plaintext;
    try {
      plaintext = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: utf8.encode('$aadContext|v1'),
      );
    } catch (_) {
      throw RecoveryException('Wrong passphrase, or the package was modified.');
    }

    Object? payload;
    try {
      payload = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      throw RecoveryException('The recovery package payload is corrupt.');
    }
    if (payload is! Map<String, dynamic>) {
      throw RecoveryException('The recovery package payload is corrupt.');
    }
    return RecoveryInfo.fromJson(payload);
  }

  Future<List<int>> _deriveKey(String passphrase, List<int> salt) async {
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    return key.extractBytes();
  }

  List<int> _randomBytes(int length) {
    final algorithm = _aead.newNonce(); // 24 secure bytes
    return [...algorithm].take(length).toList();
  }
}
