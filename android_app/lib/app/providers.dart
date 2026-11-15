/// Dependency wiring.
///
/// Everything here is explicit and testable: no global singletons, no service
/// locator, no hidden network calls at import time.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../authentication/auth_service.dart';
import '../authentication/lock_controller.dart';
import '../core/rate_limiter.dart';
import '../cryptography/olm_service.dart';
import '../networking/pairing_service.dart';
import '../recovery/recovery_service.dart';
import '../security/native_bridge.dart';
import '../security/secure_store.dart';
import '../storage/prefs.dart';

/// False when the native Olm bindings failed to load. The private area must
/// refuse to open rather than pretend to be encrypted.
final cryptoReadyProvider = Provider<bool>((ref) => false);

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final nativeBridgeProvider = Provider<NativeBridge>((ref) => NativeBridge());

final rateLimiterProvider = Provider<AuthRateLimiter>(
  (ref) => AuthRateLimiter(),
);

final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(
    store: ref.watch(secureStoreProvider),
    limiter: ref.watch(rateLimiterProvider),
  ),
);

final prefsProvider = Provider<Prefs>(
  (ref) => Prefs(ref.watch(secureStoreProvider)),
);

final olmServiceProvider = Provider<OlmService>((ref) => OlmService());

final pairingServiceProvider = Provider<PairingService>(
  (ref) => PairingService(
    ref.watch(secureStoreProvider),
    olm: () => ref.watch(olmServiceProvider),
  ),
);

/// The 32-byte secret that encrypts the Olm identity pickle at rest. It never
/// leaves the Keystore-protected store and is never logged.
final deviceSecretProvider = FutureProvider<List<int>>(
  (ref) => ref.watch(authServiceProvider).deviceSecret(32),
);

final identityProvider = FutureProvider<OlmIdentity>((ref) async {
  // Do not load the long-term Olm account while the private surface is locked.
  // The lock state is watched so a successful unlock rebuilds this provider,
  // while a lock immediately invalidates any previously exposed identity.
  final lockState = ref.watch(lockControllerProvider);
  if (lockState.isLocked) {
    throw StateError('Device identity is available only after authentication.');
  }
  final secret = await ref.watch(deviceSecretProvider.future);
  return ref
      .watch(olmServiceProvider)
      .ensureIdentity(store: ref.watch(secureStoreProvider), pickleKey: secret);
});

final networkModeProvider = NotifierProvider<NetworkModeNotifier, NetworkMode>(
  NetworkModeNotifier.new,
);

class NetworkModeNotifier extends Notifier<NetworkMode> {
  static const _cloudBaseKey = 'sp.cloud.base';

  @override
  NetworkMode build() => NetworkMode.cloud;

  Future<void> load() async {
    state = await ref.read(prefsProvider).networkMode();

    // When Cloud mode is selected but the Cloudflare origin is unreachable,
    // switch to an already-paired local laptop relay if it is reachable. This
    // is deliberately fail-closed: merely seeing a Wi-Fi network is not enough.
    if (state == NetworkMode.cloud) {
      final store = ref.read(secureStoreProvider);
      final cloudBaseValue = await store.read(_cloudBaseKey);
      final cloudBase = cloudBaseValue == null ? null : _baseFromHttp(cloudBaseValue);
      final localWs = await store.read(SecureKeys.localWsUrl);
      final localPair = await store.read('sp.local.pairId');
      final localRole = await store.read('sp.local.role');
      final cloudReachable = cloudBase != null &&
          await _probeMode(cloudBase, expectedMode: 'cloud');
      if (!cloudReachable &&
          localWs != null &&
          localPair != null &&
          localRole != null) {
        final localBase = _baseFromWs(localWs);
        if (localBase != null &&
            await _probeMode(localBase, expectedMode: 'local')) {
          state = NetworkMode.local;
          await ref.read(prefsProvider).setNetworkMode(NetworkMode.local);
        }
      }
    }
    await _refreshIceServers();
  }

  Future<void> select(NetworkMode mode) async {
    state = mode;
    await ref.read(prefsProvider).setNetworkMode(mode);
    await _refreshIceServers();
  }

  Uri? _baseFromWs(String wsUrl) {
    try {
      final parsed = Uri.parse(wsUrl);
      if (parsed.scheme != 'ws' || parsed.host.isEmpty) return null;
      return parsed.replace(scheme: 'http', path: '', query: null, fragment: null);
    } catch (_) {
      return null;
    }
  }

  Uri? _baseFromHttp(String value) {
    try {
      final parsed = Uri.parse(value);
      if (parsed.scheme != 'https' || parsed.host.isEmpty) {
        return null;
      }
      return parsed.replace(path: '', query: null, fragment: null);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final body = await response.transform(utf8.decoder).join().timeout(
        const Duration(seconds: 3),
      );
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _probeMode(Uri base, {required String expectedMode}) async {
    final health = await _getJson(base.replace(path: '/health'));
    return health?['status'] == 'ok' && health?['mode'] == expectedMode;
  }

  List<Map<String, dynamic>> _validatedIceServers(Object? value) {
    if (value is! List) return const [];
    final result = <Map<String, dynamic>>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final urls = entry['urls'];
      final validUrls = urls is String
          ? urls.isNotEmpty
          : urls is List && urls.isNotEmpty && urls.every((url) => url is String && url.isNotEmpty);
      if (!validUrls) continue;
      final item = <String, dynamic>{'urls': urls};
      if (entry['username'] is String) item['username'] = entry['username'];
      if (entry['credential'] is String) item['credential'] = entry['credential'];
      result.add(item);
    }
    return result;
  }

  /// Fetch short-lived Cloudflare TURN credentials when configured. Local mode
  /// only uses the LAN server's advertised ICE entries; an empty list means
  /// direct host candidates, not a dependency on public STUN/TURN.
  Future<void> _refreshIceServers() async {
    final store = ref.read(secureStoreProvider);
    if (state == NetworkMode.local) {
      final wsUrl = await store.read(SecureKeys.localWsUrl);
      final base = wsUrl == null ? null : _baseFromWs(wsUrl);
      if (base == null) {
        ref.read(iceServersProvider.notifier).set(const []);
        return;
      }
      final info = await _getJson(base.replace(path: '/v1/info'));
      ref.read(iceServersProvider.notifier).set(
        _validatedIceServers(info?['iceServers']),
      );
      return;
    }

    final cloudBaseValue = await store.read(_cloudBaseKey);
    final cloudBase = cloudBaseValue == null ? null : _baseFromHttp(cloudBaseValue);
    if (cloudBase == null) {
      ref.read(iceServersProvider.notifier).set(const [
        {'urls': ['stun:stun.cloudflare.com:3478']},
      ]);
      return;
    }
    final info = await _getJson(cloudBase.replace(path: '/v1/info'));
    final servers = _validatedIceServers(info?['iceServers']);
    ref.read(iceServersProvider.notifier).set(
      servers.isNotEmpty
          ? servers
          : const [
              {'urls': ['stun:stun.cloudflare.com:3478']},
            ],
    );
  }
}

final iceServersProvider =
    NotifierProvider<IceServers, List<Map<String, dynamic>>>(IceServers.new);

class IceServers extends Notifier<List<Map<String, dynamic>>> {
  @override
  List<Map<String, dynamic>> build() => const [
    {
      'urls': ['stun:stun.cloudflare.com:3478'],
    },
  ];

  void set(List<Map<String, dynamic>> servers) => state = servers;
}

final lockControllerProvider = NotifierProvider<LockController, LockState>(
  LockController.new,
);

/// Best star rating per difficulty. Lives here so both the level list and the
/// play screen can read and invalidate the same provider.
final levelStarsProvider = FutureProvider.family<int, int>(
  (ref, difficultyId) => ref.watch(prefsProvider).bestStars(difficultyId),
);

/// Stateless recovery package service. No message history is persisted.
final recoveryServiceProvider = Provider<RecoveryService>(
  (ref) => RecoveryService(),
);
