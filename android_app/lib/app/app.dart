/// Root widget: two shells, one lock.
///
/// The game shell uses the playful theme; every private route is wrapped in the
/// private theme. A single overlay covers the whole app whenever
/// [LockController] says it is locked, so private content can never be seen or
/// tapped in the background — including during the recents animation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../authentication/lock_controller.dart';
import '../authentication/passphrase_screen.dart';
import '../game/game_screen.dart';
import '../game/home_screen.dart';
import '../game/levels_screen.dart';
import '../game/settings_screen.dart';
import '../networking/connection_status_screen.dart';
import '../networking/device_verification_screen.dart';
import '../networking/network_mode_screen.dart';
import '../networking/qr_scanner_screen.dart';
import '../recovery/recovery_screen.dart';
import '../security/security_settings_screen.dart';
import '../sessions/session_controller.dart';
import '../sessions/session_lock_sink.dart';
import 'private_shell.dart';
import 'providers.dart';
import 'theme.dart';
import '../chat/chat_screen.dart';
import '../voice/call_screen.dart';

class SecretPlayApp extends ConsumerStatefulWidget {
  const SecretPlayApp({super.key});

  @override
  ConsumerState<SecretPlayApp> createState() => _SecretPlayAppState();
}

class _SecretPlayAppState extends ConsumerState<SecretPlayApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(lockControllerProvider.notifier)
          .attach(
            sink: SessionLockSink(ref),
            native: ref.read(nativeBridgeProvider),
          );
      ref.read(networkModeProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(lockControllerProvider).isLocked;
    return MaterialApp(
      title: 'SecretPlay',
      debugShowCheckedModeBanner: false,
      theme: buildGameTheme(),
      initialRoute: '/',
      routes: {
        '/': (_) => const GameHomeScreen(),
        '/levels': (_) => const GameLevelsScreen(),
        '/game': (_) => const GameScreen(),
        '/settings': (_) => const GameSettingsScreen(),
        '/vault': (_) => const PrivateShell(),
        '/vault/chat': (_) => const PrivateFrame(child: ChatScreen()),
        '/vault/call': (_) => const PrivateFrame(child: VoiceCallScreen()),
        '/vault/network': (_) => const PrivateFrame(child: NetworkModeScreen()),
        '/vault/scan': (_) => const PrivateFrame(child: QrScannerScreen()),
        '/vault/status': (_) =>
            const PrivateFrame(child: ConnectionStatusScreen()),
        '/vault/verify': (_) =>
            const PrivateFrame(child: DeviceVerificationScreen()),
        '/vault/recovery': (_) => const PrivateFrame(child: RecoveryScreen()),
        '/vault/security': (_) =>
            const PrivateFrame(child: SecuritySettingsScreen()),
      },
      builder: (context, child) {
        return Stack(
          textDirection: TextDirection.ltr,
          children: [
            if (child != null) child,
            if (locked) const Positioned.fill(child: _LockCover()),
          ],
        );
      },
    );
  }
}

/// Opaque cover shown instead of private content. It is a separate route-level
/// widget so no private widget can paint over it.
class _LockCover extends StatelessWidget {
  const _LockCover();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SpColors.privateInk,
      child: const PassphraseScreen(insideCover: true),
    );
  }
}

/// Applies the private palette and a distinct app bar to private routes.
class PrivateFrame extends StatelessWidget {
  const PrivateFrame({required this.child, this.title, super.key});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: title == null
            ? null
            : AppBar(
                title: Text(title!),
                leading: BackButton(
                  color: SpColors.privateAccent,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
        body: SafeArea(child: child),
      ),
    );
  }
}

/// Test hook used by the security checklist.
bool isPrivateSurfaceLocked(WidgetRef ref) =>
    ref.read(lockControllerProvider).isLocked;
