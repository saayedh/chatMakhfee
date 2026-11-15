/// Connection diagnostics: what the app believes about the session, without
/// leaking anything the peer wrote.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../sessions/session_controller.dart';
import '../sessions/session_state.dart';
import '../storage/prefs.dart';

class ConnectionStatusScreen extends ConsumerWidget {
  const ConnectionStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final snapshot = session.snapshot;
    final mode = ref.watch(networkModeProvider);
    final ice = ref.watch(iceServersProvider);

    return Theme(
      data: buildPrivateTheme(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Connection status')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              _Row(
                label: 'Mode',
                value: mode == NetworkMode.local
                    ? 'Local (laptop relay)'
                    : 'Cloud (Worker)',
              ),
              _Row(label: 'Phase', value: _phaseLabel(snapshot.phase)),
              _Row(
                label: 'Other device',
                value: snapshot.peerPresent ? 'connected' : 'not connected',
              ),
              _Row(label: 'Session id', value: snapshot.sessionId ?? '—'),
              _Row(label: 'Heartbeat', value: '5s ping · 20s timeout'),
              _Row(label: 'Can send', value: snapshot.canSend ? 'yes' : 'no'),
              _Row(
                label: 'Messages in memory',
                value: '${session.messages.length}',
              ),
              _Row(
                label: 'ICE servers',
                value: ice.isEmpty
                    ? 'none (LAN host candidates only)'
                    : '${ice.length}',
              ),
              if (snapshot.lastError != null)
                _Row(label: 'Last error', value: snapshot.lastError!),
              const SizedBox(height: 18),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Why messages pause',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'A session only relays while both authorised devices are connected. If the other '
                        'phone leaves or locks, this side is told immediately and locks too. Reconnecting '
                        'is always a new session: no messages are replayed, requested or restored.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8C93A8),
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await ref.read(sessionProvider.notifier).leave();
                },
                child: const Text('End this session'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _phaseLabel(SessionPhase phase) => switch (phase) {
    SessionPhase.idle => 'idle (locked)',
    SessionPhase.connecting => 'connecting',
    SessionPhase.waitingForPeer => 'waiting for peer',
    SessionPhase.active => 'active',
    SessionPhase.ended => 'ended',
  };
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8C93A8)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
