/// Game home. Playful by design: this is the part anyone can see.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import 'models.dart';

class GameHomeScreen extends ConsumerWidget {
  const GameHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(networkModeProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Row(
              children: [
                const _Badge(text: 'SECRETPLAY'),
                const Spacer(),
                IconButton(
                  tooltip: 'Game settings',
                  onPressed: () => Navigator.of(context).pushNamed('/settings'),
                  icon: const Icon(Icons.tune, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Circuit Breaker',
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
            ),
            const SizedBox(height: 6),
            const Text(
              'Crack the code. Four colours, ten rows, one very smug machine.',
              style: TextStyle(color: Color(0xFF9AA3B8), fontSize: 15),
            ),
            const SizedBox(height: 26),
            _PlayCard(
              onPlay: () => Navigator.of(context).pushNamed('/game'),
              onLevels: () => Navigator.of(context).pushNamed('/levels'),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    label: 'Mode',
                    value: mode.name == 'local' ? 'Local' : 'Cloud',
                    hint: mode.name == 'local'
                        ? 'Laptop relay'
                        : 'Cloudflare relay',
                    color: mode.name == 'local' ? SpColors.sun : SpColors.sky,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: _StatCard(
                    label: 'Levels',
                    value: '4',
                    hint: 'Warm-up → Mastermind',
                    color: SpColors.grape,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 26),
            const _SectionTitle('The other half'),
            const SizedBox(height: 10),
            _VaultCard(onOpen: () => Navigator.of(context).pushNamed('/vault')),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      letterSpacing: 2,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: Color(0xFF6C7488),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: SpColors.mint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: SpColors.mint,
          fontSize: 11,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _PlayCard extends StatelessWidget {
  const _PlayCard({required this.onPlay, required this.onLevels});

  final VoidCallback onPlay;
  final VoidCallback onLevels;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E2540), Color(0xFF2A1F4D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(
              6,
              (index) => Container(
                margin: const EdgeInsets.only(right: 8),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: SpColors.pegPalette[index],
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Quick round',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Standard rules · 5 pegs · 7 colours',
            style: TextStyle(color: Color(0xFF9AA3B8)),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: onLevels,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: const Text('Levels'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.color,
  });

  final String label;
  final String value;
  final String hint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SpColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 1.4,
              color: Color(0xFF6C7488),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8C93A8)),
          ),
        ],
      ),
    );
  }
}

class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: const Color(0xFF0C0F17),
          border: Border.all(color: SpColors.privateLine),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: SpColors.privateAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.shield_moon_outlined,
                color: SpColors.privateAccent,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Private area',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Two devices · encrypted · nothing kept',
                    style: TextStyle(fontSize: 12, color: Color(0xFF7D8598)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF7D8598)),
          ],
        ),
      ),
    );
  }
}

/// Colours used by the level cards, kept here so the palette has one home.
List<Color> pegPaletteFor(Difficulty difficulty) =>
    SpColors.pegPalette.take(difficulty.colors).toList();
