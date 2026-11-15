/// Small preferences store.
///
/// Deliberately reuses [SecureStore] instead of `shared_preferences`: fewer
/// dependencies, one storage surface to wipe, and nothing leaves the Keystore-
/// protected file. These values are not secrets, but separating stores would
/// only add an unencrypted file for no benefit.
library;

import '../security/secure_store.dart';

enum NetworkMode { cloud, local }

class Prefs {
  Prefs(this._store);

  final SecureStore _store;

  Future<NetworkMode> networkMode() async {
    final raw = await _store.read(SecureKeys.networkMode);
    return raw == 'local' ? NetworkMode.local : NetworkMode.cloud;
  }

  Future<void> setNetworkMode(NetworkMode mode) =>
      _store.write(SecureKeys.networkMode, mode.name);

  Future<String?> wsUrlFor(NetworkMode mode) => _store.read(
    mode == NetworkMode.local ? SecureKeys.localWsUrl : SecureKeys.cloudWsUrl,
  );

  Future<void> setWsUrl(NetworkMode mode, String url) => _store.write(
    mode == NetworkMode.local ? SecureKeys.localWsUrl : SecureKeys.cloudWsUrl,
    url,
  );

  Future<int> bestStars(int difficultyId) async {
    final raw = await _store.read('${SecureKeys.gameBestStars}.$difficultyId');
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setBestStars(int difficultyId, int stars) =>
      _store.write('${SecureKeys.gameBestStars}.$difficultyId', '$stars');
}
