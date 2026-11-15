/// SecretPlay entry point.
///
/// The only startup work is initialising vodozemac's native bindings. If that
/// fails (for example a build without the Rust toolchain), the app still opens
/// but the private area reports the problem instead of pretending to be secure.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'cryptography/olm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var cryptoReady = true;
  try {
    await OlmService.initialise();
  } catch (_) {
    cryptoReady = false;
  }
  runApp(
    ProviderScope(
      overrides: [cryptoReadyProvider.overrideWithValue(cryptoReady)],
      child: const SecretPlayApp(),
    ),
  );
}
