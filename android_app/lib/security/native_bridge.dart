/// Bridge to the small amount of Android-native code this app needs:
///
///  * reliable foreground/background signals (Flutter lifecycle alone can miss
///    task switches and OEM quirks);
///  * secure-flag management so private content never appears in recents;
///  * microphone permission requests without an extra plugin;
///  * foreground-service start/stop for calls, with the required notification.
///
/// See android/app/src/main/kotlin/app/secretplay/MainActivity.kt.
library;

import 'dart:async';

import 'package:flutter/services.dart';

class NativeBridge {
  NativeBridge({
    MethodChannel? methodChannel,
    EventChannel? lifecycleChannel,
    EventChannel? lockChannel,
  }) : _method = methodChannel ?? const MethodChannel('app.secretplay/native'),
       _lifecycle =
           lifecycleChannel ?? const EventChannel('app.secretplay/lifecycle'),
       _lock = lockChannel ?? const EventChannel('app.secretplay/lock');

  final MethodChannel _method;
  final EventChannel _lifecycle;
  final EventChannel _lock;

  Stream<bool> get foregroundStream =>
      _lifecycle.receiveBroadcastStream().map((event) => event == 'foreground');

  /// Fired when Android itself believes the private surface must be covered:
  /// recents opened, screen off, or the activity is no longer visible.
  Stream<String> get lockRequests =>
      _lock.receiveBroadcastStream().map((event) => '$event');

  Future<void> setSecureFlag(bool enabled) async {
    await _method.invokeMethod<void>('setSecureFlag', {'enabled': enabled});
  }

  Future<bool> requestMicrophonePermission() async {
    final granted = await _method.invokeMethod<bool>(
      'requestMicrophonePermission',
    );
    return granted ?? false;
  }

  Future<void> startCallService(String peerLabel) async {
    await _method.invokeMethod<void>('startCallService', {
      'peerLabel': peerLabel,
    });
  }

  Future<void> stopCallService() async {
    await _method.invokeMethod<void>('stopCallService');
  }

  Future<String> androidVersion() async {
    final value = await _method.invokeMethod<String>('androidVersion');
    return value ?? 'unknown';
  }
}
