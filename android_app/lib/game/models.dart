/// Pure Dart game models for "Circuit Breaker", the small game in SecretPlay's
/// public shell. No Flutter imports: this file is executed by
/// `tool/logic_check.dart` to verify the rules.
library;

/// Four difficulty tiers, each a real rules change rather than a reskin.
enum Difficulty {
  warmup('Warm-up', 4, 6, 10, '4 pegs · 6 colours · 10 rows'),
  standard('Standard', 5, 7, 10, '5 pegs · 7 colours · 10 rows'),
  sharp('Sharp', 6, 8, 9, '6 pegs · 8 colours · 9 rows'),
  mastermind('Mastermind', 6, 6, 8, '6 pegs · 6 colours · 8 rows');

  const Difficulty(
    this.label,
    this.pegs,
    this.colors,
    this.rows,
    this.description,
  );

  final String label;
  final int pegs;
  final int colors;
  final int rows;
  final String description;

  int get id => index;

  static Difficulty fromId(int id) => id >= 0 && id < Difficulty.values.length
      ? Difficulty.values[id]
      : Difficulty.standard;
}

/// A colour peg is just an index into the current difficulty's palette.
typedef Peg = int;

/// Feedback for one row: exact matches, colour-only matches.
class Feedback {
  const Feedback(this.exact, this.partial);

  final int exact;
  final int partial;

  bool get isSolved => exact > 0 && partial == 0;

  @override
  bool operator ==(Object other) =>
      other is Feedback && other.exact == exact && other.partial == partial;

  @override
  int get hashCode => Object.hash(exact, partial);

  @override
  String toString() => 'Feedback($exact exact, $partial partial)';
}

/// One submitted attempt.
class Guess {
  const Guess({required this.pegs, required this.feedback});

  final List<Peg> pegs;
  final Feedback feedback;

  bool get solved => feedback.isSolved;
}

/// Outcome of a finished round, used for the star rating on the levels screen.
enum GameOutcome { inProgress, won, lost }

/// Pure scoring for the level cards: 3 stars for a win in the fewest rows,
/// 2 for a win in the second half, 1 for any win, 0 for a loss.
int starsFor({
  required int rowsUsed,
  required int totalRows,
  required GameOutcome outcome,
}) {
  if (outcome != GameOutcome.won) return 0;
  if (rowsUsed <= (totalRows / 2).ceil()) return 3;
  if (rowsUsed <= totalRows) return 2;
  return 1;
}
