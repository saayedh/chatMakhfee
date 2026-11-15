/// Android Keystore-backed storage.
///
/// `flutter_secure_storage` 11 uses RSA-OAEP key wrapping plus AES-GCM under a
/// hardware-backed Keystore key by default. Only *long-term* material lives
/// here (identity pickle, passphrase verifier, pairing metadata, preferences).
/// Chat content never does: there is no message key in this class on purpose.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureKeys {
  const SecureKeys._();

  static const String deviceId = 'sp.device.id';
  static const String pairId = 'sp.pair.id';
  static const String role = 'sp.role';
  static const String peerDeviceId = 'sp.peer.device.id';
  static const String peerPublicKey = 'sp.peer.public.key';
  static const String olmAccountPickle = 'sp.olm.account';
  static const String olmSessionPickle = 'sp.olm.session';
  static const String passphraseVerifier = 'sp.passphrase.verifier';
  static const String passphraseSalt = 'sp.passphrase.salt';
  static const String recoveryHint = 'sp.recovery.hint';
  static const String networkMode = 'sp.network.mode';
  static const String localWsUrl = 'sp.local.ws';
  static const String cloudWsUrl = 'sp.cloud.ws';
  static const String gameBestStars = 'sp.game.stars';
  static const String lastLockReason = 'sp.lock.reason';
}

class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              // RSA-OAEP key wrapping + AES-GCM storage cipher, Keystore-backed.
              keyCipherAlgorithm:
                  KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
              storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
            ),
          );

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);

  /// Wipe all long-term material. Used by "forget this device".
  Future<void> wipe() async {
    await _storage.deleteAll();
  }

  Future<bool> hasIdentity() async =>
      (await read(SecureKeys.olmAccountPickle)) != null;
}
