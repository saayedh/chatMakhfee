/// Level selection. Each tier changes the rules, not just the colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import 'game_screen.dart';
import 'models.dart';

class GameLevelsScreen extends ConsumerWidget {
  const GameLevelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Levels'),
      ),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: Difficulty.values.length,
          separatorBuilder: (_, __) => const SizedBox(height: 14),
          itemBuilder: (context, index) {
            final difficulty = Difficulty.values[index];
            return _LevelCard(
              difficulty: difficulty,
              index: index,
              onPlay: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GameScreen(difficulty: difficulty),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _LevelCard extends ConsumerWidget {
  const _LevelCard({
    required this.difficulty,
    required this.index,
    required this.onPlay,
  });

  final Difficulty difficulty;
  final int index;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stars = ref.watch(levelStarsProvider(difficulty.id)).valueOrNull ?? 0;
    return Container(
      decoration: BoxDecoration(
        color: SpColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: SpColors.pegPalette[index % SpColors.pegPalette.length]
                  .withValues(alpha: 0.16),
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: SpColors.pegPalette[index % SpColors.pegPalette.length],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  difficulty.label,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  difficulty.description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8C93A8),
                  ),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Text(
                '★' * stars + '☆' * (3 - stars),
                style: const TextStyle(color: SpColors.sun, fontSize: 16),
              ),
              const SizedBox(height: 6),
              TextButton(onPressed: onPlay, child: const Text('Play')),
            ],
          ),
        ],
      ),
    );
  }
}
