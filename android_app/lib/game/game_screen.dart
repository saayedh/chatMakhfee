/// The playable round: board, palette, feedback, hint, reveal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import 'game_engine.dart';
import 'models.dart';

class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({this.difficulty, super.key});

  final Difficulty? difficulty;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  late GameEngine _engine;
  String? _message;

  Difficulty get _difficulty => widget.difficulty ?? Difficulty.standard;

  @override
  void initState() {
    super.initState();
    _engine = GameEngine.newRound(_difficulty);
  }

  void _restart() {
    setState(() {
      _engine = GameEngine.newRound(_difficulty);
      _message = null;
    });
  }

  Future<void> _submit() async {
    if (!_engine.canSubmit) return;
    setState(() {
      _engine.submit();
      _message = null;
    });
    if (_engine.outcome != GameOutcome.inProgress) {
      await ref.read(prefsProvider).setBestStars(_difficulty.id, _engine.stars);
      if (!mounted) return;
      ref.invalidate(levelStarsProvider(_difficulty.id));
      await _showResult();
    }
  }

  Future<void> _showResult() async {
    final won = _engine.outcome == GameOutcome.won;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: SpColors.surface,
        title: Text(won ? 'Cracked it!' : 'The machine wins'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              won
                  ? 'Solved in ${_engine.rowsUsed} rows · ${'★' * _engine.stars}'
                  : 'The code was:',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final peg in _engine.debugCode)
                  CircleAvatar(
                    radius: 9,
                    backgroundColor: SpColors.pegPalette[peg],
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _restart();
            },
            child: const Text('Again'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = SpColors.pegPalette.take(_difficulty.colors).toList();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('${_difficulty.label} · ${_difficulty.pegs} pegs'),
        actions: [
          IconButton(
            tooltip: 'Restart',
            onPressed: _restart,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                itemCount: _difficulty.rows,
                itemBuilder: (context, index) => _Row(
                  index: index,
                  guess: index < _engine.guesses.length
                      ? _engine.guesses[index]
                      : null,
                  draft:
                      index == _engine.guesses.length &&
                          _engine.outcome == GameOutcome.inProgress
                      ? _engine.draft
                      : null,
                  pegs: _difficulty.pegs,
                ),
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Text(
                  _message!,
                  style: const TextStyle(color: SpColors.sun),
                ),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
              decoration: const BoxDecoration(
                color: SpColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      for (var i = 0; i < palette.length; i += 1)
                        _PegButton(
                          color: palette[i],
                          onTap: () => setState(() {
                            if (!_engine.addPeg(i)) {
                              _message = 'That row is full. Submit it or undo.';
                            } else {
                              _message = null;
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Undo',
                        onPressed: () => setState(_engine.removeLastPeg),
                        icon: const Icon(Icons.backspace_outlined),
                      ),
                      IconButton(
                        tooltip: 'Clear row',
                        onPressed: () => setState(_engine.clearDraft),
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        tooltip: 'Hint (costs a row)',
                        onPressed: () => setState(() {
                          final hint = _engine.takeHint();
                          _message = hint == null
                              ? 'No hint available.'
                              : 'Position ${_engine.rowsUsed} hint: one peg is ${_difficulty.label} colour #${hint + 1}.';
                        }),
                        icon: const Icon(Icons.lightbulb_outline),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: _engine.canSubmit ? _submit : null,
                        child: const Text('Submit'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.index,
    required this.guess,
    required this.draft,
    required this.pegs,
  });

  final int index;
  final Guess? guess;
  final List<Peg>? draft;
  final int pegs;

  @override
  Widget build(BuildContext context) {
    final active = draft != null;
    final values = guess?.pegs ?? draft ?? const <Peg>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: active ? SpColors.surface : Colors.transparent,
        border: Border.all(
          color: active ? SpColors.mint.withValues(alpha: 0.4) : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: const TextStyle(color: Color(0xFF6C7488), fontSize: 12),
            ),
          ),
          for (var i = 0; i < pegs; i += 1)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CircleAvatar(
                radius: 11,
                backgroundColor: i < values.length
                    ? SpColors.pegPalette[values[i] %
                          SpColors.pegPalette.length]
                    : Colors.black26,
              ),
            ),
          const Spacer(),
          if (guess != null) _FeedbackPegs(feedback: guess!.feedback),
        ],
      ),
    );
  }
}

class _FeedbackPegs extends StatelessWidget {
  const _FeedbackPegs({required this.feedback});

  final Feedback feedback;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < feedback.exact; i += 1)
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.circle, size: 10, color: SpColors.mint),
          ),
        for (var i = 0; i < feedback.partial; i += 1)
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.circle_outlined, size: 10, color: SpColors.sun),
          ),
        if (feedback.exact == 0 && feedback.partial == 0)
          const Text(
            'none',
            style: TextStyle(fontSize: 10, color: Color(0xFF6C7488)),
          ),
      ],
    );
  }
}

class _PegButton extends StatelessWidget {
  const _PegButton({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
    );
  }
}
