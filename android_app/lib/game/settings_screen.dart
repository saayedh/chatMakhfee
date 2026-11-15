/// Game settings. Public by nature: nothing here touches private data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../storage/prefs.dart';

class GameSettingsScreen extends ConsumerWidget {
  const GameSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(networkModeProvider);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Game settings'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'How rounds work',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              'Pick colours with the palette, submit a full row, and read the feedback: '
              'a filled dot is the right colour in the right place, an outline is the right colour '
              'in the wrong place. Duplicates count once. A hint costs a row.',
              style: TextStyle(color: Color(0xFF9AA3B8), height: 1.5),
            ),
            const SizedBox(height: 26),
            const Text(
              'Network mode',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            SegmentedButton<NetworkMode>(
              segments: const [
                ButtonSegment(
                  value: NetworkMode.cloud,
                  label: Text('Cloud'),
                  icon: Icon(Icons.cloud_outlined),
                ),
                ButtonSegment(
                  value: NetworkMode.local,
                  label: Text('Local'),
                  icon: Icon(Icons.wifi_tethering),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) {
                ref.read(networkModeProvider.notifier).select(selection.first);
              },
            ),
            const SizedBox(height: 10),
            Text(
              mode == NetworkMode.local
                  ? 'Local mode talks only to the laptop relay on your network. Audio stays on the LAN, and no external STUN/TURN is used.'
                  : 'Cloud mode uses the deployed Worker and Durable Object, with Cloudflare STUN for calls.',
              style: const TextStyle(
                color: Color(0xFF8C93A8),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 30),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),
            const Row(
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 18,
                  color: Color(0xFF6C7488),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No analytics, no ads, no crash reporting. The game has no network code except the mode switch above.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6C7488),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: SpColors.privateLine),
              ),
              child: const Text(
                'Your best star ratings are stored in the encrypted app store, not in a game save file.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8C93A8)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
