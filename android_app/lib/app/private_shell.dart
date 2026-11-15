/// The private shell: its own navigation, its own palette, no game chrome.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../authentication/lock_controller.dart';
import '../sessions/session_controller.dart';
import '../sessions/session_state.dart';
import 'providers.dart';
import 'theme.dart';

class PrivateShell extends ConsumerWidget {
  const PrivateShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Never offer a private area that cannot actually encrypt. Silently running
    // without Olm would be worse than refusing to start.
    if (!ref.watch(cryptoReadyProvider)) {
      return Theme(
        data: buildPrivateTheme(),
        child: Scaffold(
          appBar: AppBar(title: const Text('Private')),
          body: const SafeArea(child: _CryptoUnavailable()),
        ),
      );
    }
    final session = ref.watch(sessionProvider);
    final phase = session.snapshot.phase;
    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Private'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: _StatusChip(phase: phase)),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const _Intro(),
              const SizedBox(height: 18),
              _Tile(
                icon: Icons.chat_bubble_outline,
                title: 'Private chat',
                subtitle: session.canSend
                    ? 'Verified session · ${session.messages.length} messages in memory'
                    : 'Connect from the chat screen to start a session',
                onTap: () => Navigator.of(context).pushNamed('/vault/chat'),
              ),
              _Tile(
                icon: Icons.call_outlined,
                title: 'Voice call',
                subtitle: 'Encrypted peer-to-peer audio · no recording',
                onTap: () => Navigator.of(context).pushNamed('/vault/call'),
              ),
              _Tile(
                icon: Icons.qr_code_scanner,
                title: 'Network & pairing',
                subtitle: 'Cloud or local relay, pair a device',
                onTap: () => Navigator.of(context).pushNamed('/vault/network'),
              ),
              _Tile(
                icon: Icons.verified_user_outlined,
                title: 'Verify devices',
                subtitle: 'Compare the six-digit security code',
                onTap: () => Navigator.of(context).pushNamed('/vault/verify'),
              ),
              _Tile(
                icon: Icons.monitor_heart_outlined,
                title: 'Connection status',
                subtitle: 'Phase, heartbeat, session limits',
                onTap: () => Navigator.of(context).pushNamed('/vault/status'),
              ),
              _Tile(
                icon: Icons.key_outlined,
                title: 'Recovery',
                subtitle: 'Encrypted package · no chat history',
                onTap: () => Navigator.of(context).pushNamed('/vault/recovery'),
              ),
              _Tile(
                icon: Icons.lock_outline,
                title: 'Security settings',
                subtitle: 'Passphrase, biometrics, device wipe',
                onTap: () => Navigator.of(context).pushNamed('/vault/security'),
              ),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: () async {
                  ref
                      .read(lockControllerProvider.notifier)
                      .lockNow('user_exit');
                  if (context.mounted)
                    Navigator.of(context).popUntil((route) => route.isFirst);
                },
                icon: const Icon(Icons.lock),
                label: const Text('Leave and lock now'),
              ),
              const SizedBox(height: 10),
              const Text(
                'Leaving ends the session for both devices. Messages are not kept anywhere, '
                'including on this phone.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFF6C7488)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CryptoUnavailable extends StatelessWidget {
  const _CryptoUnavailable();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.gpp_bad_outlined, size: 44, color: SpColors.coral),
          SizedBox(height: 16),
          Text(
            'Encryption is unavailable',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 10),
          Text(
            'The native Olm library did not load on this device, so the private area is '
            'refusing to open. Reinstall a build that includes the vodozemac native library '
            'for this phone\'s ABI. The game is unaffected.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF8C93A8),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF10231F), Color(0xFF11151F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: SpColors.privateLine),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Two people, two phones',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6),
          Text(
            'Everything in this area is end-to-end encrypted with Olm. The relay sees '
            'ciphertext and public keys only, and keeps no history.',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF9AA3B8),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: SpColors.privateAccent),
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 11, color: Color(0xFF8C93A8)),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          size: 18,
          color: Color(0xFF6C7488),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.phase});

  final SessionPhase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      SessionPhase.idle => ('idle', const Color(0xFF6C7488)),
      SessionPhase.connecting => ('connecting', SpColors.sky),
      SessionPhase.waitingForPeer => ('waiting', SpColors.sun),
      SessionPhase.active => ('live', SpColors.privateAccent),
      SessionPhase.ended => ('ended', SpColors.coral),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
