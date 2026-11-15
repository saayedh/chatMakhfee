/// Unlock policy.
///
///  * A private passphrase is required to enter the private area.
///  * It is never stored: only an Argon2id verifier (salt + parameters + hash)
///    is kept in the Keystore-protected store.
///  * Biometrics, when available, provide an additional local application
///    unlock step. This prompt alone does not bind the Olm pickle key to a
///    per-use biometric-authenticated Android Keystore operation.
///  * Failed attempts are throttled by [AuthRateLimiter].
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:local_auth/local_auth.dart';

import '../core/ids.dart';
import '../core/rate_limiter.dart';
import '../security/secure_store.dart';

class PassphrasePolicy {
  const PassphrasePolicy._();

  static const int minLength = 12;

  /// Rejects the obvious mistakes without pretending to measure entropy.
  static String? validate(String passphrase) {
    if (passphrase.length < minLength) {
      return 'Use at least $minLength characters.';
    }
    if (passphrase.trim().length != passphrase.length) {
      return 'Do not start or end with spaces.';
    }
    if (RegExp(r'^(.)\1+$').hasMatch(passphrase)) {
      return 'That is a single repeated character.';
    }
    final distinct = passphrase.split('').toSet().length;
    if (distinct < 5) return 'Use a wider variety of characters.';
    return null;
  }
}

class AuthResult {
  const AuthResult.success()
    : ok = true,
      message = null,
      retryAfter = null;
  const AuthResult.failure(this.message, {this.retryAfter}) : ok = false;

  final bool ok;
  final String? message;
  final Duration? retryAfter;
}

class AuthService {
  AuthService({
    required SecureStore store,
    required AuthRateLimiter limiter,
    LocalAuthentication? localAuth,
  }) : _store = store,
       _limiter = limiter,
       _localAuth = localAuth ?? LocalAuthentication();

  final SecureStore _store;
  final AuthRateLimiter _limiter;
  final LocalAuthentication _localAuth;

  static const int kdfMemoryKib = 65536;
  static const int kdfIterations = 3;
  static const int kdfParallelism = 1;
  static const String _failureCountKey = 'sp.auth.failures';
  static const String _lockedUntilKey = 'sp.auth.locked_until';
  bool _limiterHydrated = false;

  final Argon2id _argon2id = Argon2id(
    memory: kdfMemoryKib,
    iterations: kdfIterations,
    parallelism: kdfParallelism,
    hashLength: 32,
  );

  bool get isConfigured => _configured;
  bool _configured = false;

  Future<bool> refreshConfigured() async {
    _configured = (await _store.read(SecureKeys.passphraseVerifier)) != null;
    return _configured;
  }

  Future<void> setPassphrase(String passphrase) async {
    final problem = PassphrasePolicy.validate(passphrase);
    if (problem != null) throw ArgumentError(problem);
    final salt = randomBase64u(16);
    final key = await _derive(passphrase, salt);
    // Store salt + parameters alongside the verifier so a future parameter
    // change can be detected instead of silently failing.
    await _store.write(
      SecureKeys.passphraseSalt,
      '$salt:$kdfMemoryKib:$kdfIterations:$kdfParallelism',
    );
    await _store.write(SecureKeys.passphraseVerifier, base64Url.encode(key));
    _configured = true;
    _limiter.reset();
    _limiterHydrated = true;
    await _store.delete(_failureCountKey);
    await _store.delete(_lockedUntilKey);
  }

  Future<AuthResult> unlockWithPassphrase(
    String passphrase, {
    DateTime? now,
  }) async {
    final clock = now ?? DateTime.now();
    await _restoreLimiter();
    final decision = _limiter.check(clock);
    if (!decision.allowed) {
      return AuthResult.failure(
        'Too many attempts. Try again later.',
        retryAfter: decision.retryAfter,
      );
    }

    final stored = await _store.read(SecureKeys.passphraseSalt);
    final verifier = await _store.read(SecureKeys.passphraseVerifier);
    if (stored == null || verifier == null) {
      return const AuthResult.failure(
        'No passphrase is configured on this device.',
      );
    }
    final salt = stored.split(':').first;
    final derived = await _derive(passphrase, salt);
    final expected = base64Url.decode(verifier);

    if (!_constantTimeEquals(derived, expected)) {
      final delay = _limiter.registerFailure(clock);
      await _persistLimiter();
      if (delay == Duration.zero) {
        return AuthResult.failure(
          'Wrong passphrase. ${_remaining(clock)} attempts left before a delay.',
        );
      }
      return AuthResult.failure(
        'Wrong passphrase. Locked for ${delay.inSeconds}s.',
        retryAfter: delay,
      );
    }

    _limiter.reset();
    await _store.delete(_failureCountKey);
    await _store.delete(_lockedUntilKey);
    return const AuthResult.success();
  }


  Future<void> _restoreLimiter() async {
    if (_limiterHydrated) return;
    final failuresRaw = await _store.read(_failureCountKey);
    final lockedRaw = await _store.read(_lockedUntilKey);
    final failures = int.tryParse(failuresRaw ?? '') ?? 0;
    final lockedMillis = int.tryParse(lockedRaw ?? '');
    _limiter.restore(
      failures: failures,
      lockedUntil: lockedMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lockedMillis),
    );
    _limiterHydrated = true;
  }

  Future<void> _persistLimiter() async {
    await _store.write(_failureCountKey, '${_limiter.failures}');
    final lockedUntil = _limiter.lockedUntil;
    if (lockedUntil == null) {
      await _store.delete(_lockedUntilKey);
    } else {
      await _store.write(
        _lockedUntilKey,
        '${lockedUntil.millisecondsSinceEpoch}',
      );
    }
  }

  Future<bool> canUseBiometrics() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      final enrolled = await _localAuth.canCheckBiometrics;
      return supported && enrolled;
    } catch (_) {
      return false;
    }
  }

  Future<AuthResult> unlockWithBiometrics() async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock SecretPlay',
        biometricOnly: true,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
      return authenticated
          ? const AuthResult.success()
          : const AuthResult.failure('Biometric unlock was cancelled.');
    } catch (_) {
      return const AuthResult.failure(
        'Biometrics are unavailable. Use your passphrase.',
      );
    }
  }

  Future<List<int>> _derive(String passphrase, String salt) async {
    final key = await _argon2id.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: base64Url.decode(salt),
    );
    return key.extractBytes();
  }

  String _remaining(DateTime now) {
    final decision = _limiter.check(now);
    return '${decision.remainingFree}';
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i += 1) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Generates the random pickle key used to encrypt the Olm account at rest.
  /// It lives in the Keystore-protected store, never in logs or UI.
  Future<List<int>> deviceSecret(int bytes) async {
    final existing = await _store.read('sp.device.secret');
    if (existing != null) {
      final decoded = base64Url.decode(existing);
      if (decoded.length == bytes) return decoded;
    }
    final fresh = List<int>.generate(
      bytes,
      (_) => Random.secure().nextInt(256),
    );
    await _store.write('sp.device.secret', base64Url.encode(fresh));
    return fresh;
  }
}
