/// Circuit Breaker — a Mastermind-style deduction game.
///
/// Rules are intentionally simple, deterministic and fully unit-testable:
///  * the code is [Difficulty.pegs] pegs chosen from [Difficulty.colors];
///  * duplicates are allowed and *are* significant;
///  * feedback is (exact matches, colour-only matches) computed with the
///    standard "consume the peg on a match" algorithm, so a repeated colour in
///    the guess cannot be counted twice;
///  * the round ends on a correct guess or when rows run out.
///
/// No Flutter imports here on purpose: `tool/logic_check.dart` runs this file
/// directly with the Dart VM.
library;

import 'dart:math';

import 'models.dart';

class GameEngine {
  GameEngine({
    required this.difficulty,
    required int seed,
    int? pegsOverride,
    List<Peg>? code,
  }) : _code = code ?? _generateCode(difficulty, Random(seed)),
       _pegs = pegsOverride ?? difficulty.pegs {
    if (_code.length != _pegs) {
      throw ArgumentError('code length must match the difficulty peg count');
    }
  }

  /// Start a fresh round with a deterministic seed (used by tests) or a random
  /// seed (used by the UI).
  factory GameEngine.newRound(Difficulty difficulty, {int? seed}) {
    final resolvedSeed = seed ?? DateTime.now().microsecondsSinceEpoch;
    return GameEngine(difficulty: difficulty, seed: resolvedSeed);
  }

  final Difficulty difficulty;
  final List<Peg> _code;
  final int _pegs;
  final List<Guess> _guesses = [];
  final List<Peg> _draft = [];
  GameOutcome _outcome = GameOutcome.inProgress;

  static List<Peg> _generateCode(Difficulty difficulty, Random random) {
    return List<Peg>.generate(
      difficulty.pegs,
      (_) => random.nextInt(difficulty.colors),
    );
  }

  int get pegs => _pegs;
  int get totalRows => difficulty.rows;
  int get rowsUsed => _guesses.length;
  int get rowsLeft => totalRows - rowsUsed;
  GameOutcome get outcome => _outcome;
  List<Guess> get guesses => List<Guess>.unmodifiable(_guesses);
  List<Peg> get draft => List<Peg>.unmodifiable(_draft);

  /// The secret, exposed only after the round ends (for the reveal animation).
  List<Peg>? get revealedCode =>
      _outcome == GameOutcome.inProgress ? null : List<Peg>.unmodifiable(_code);

  bool get canSubmit =>
      _outcome == GameOutcome.inProgress && _draft.length == _pegs;

  bool get isDraftFull => _draft.length == _pegs;

  /// Add a peg to the draft. Returns false when the row is already full or the
  /// round is over.
  bool addPeg(Peg peg) {
    if (_outcome != GameOutcome.inProgress) return false;
    if (_draft.length >= _pegs) return false;
    if (peg < 0 || peg >= difficulty.colors) {
      throw ArgumentError('peg $peg is outside the palette');
    }
    _draft.add(peg);
    return true;
  }

  void removeLastPeg() {
    if (_draft.isNotEmpty) _draft.removeLast();
  }

  void clearDraft() => _draft.clear();

  /// Submit the draft. Returns the feedback, or null when the draft is not a
  /// complete row.
  Feedback? submit() {
    if (!canSubmit) return null;
    final guess = List<Peg>.of(_draft);
    final feedback = score(guess, _code);
    _guesses.add(Guess(pegs: guess, feedback: feedback));
    _draft.clear();
    if (feedback.isSolved) {
      _outcome = GameOutcome.won;
    } else if (_guesses.length >= totalRows) {
      _outcome = GameOutcome.lost;
    }
    return feedback;
  }

  int get stars =>
      starsFor(rowsUsed: rowsUsed, totalRows: totalRows, outcome: _outcome);

  /// A hint reveals one position from the code that the latest guesses have not
  /// pinned yet. Costs a row so hints cannot be free information.
  Peg? takeHint() {
    if (_outcome != GameOutcome.inProgress) return null;
    final known = <int>{};
    for (final guess in _guesses) {
      if (guess.feedback.exact == 0 && guess.pegs.isNotEmpty) continue;
      for (var i = 0; i < guess.pegs.length; i += 1) {
        if (guess.pegs[i] == _code[i]) known.add(i);
      }
    }
    for (var i = 0; i < _code.length; i += 1) {
      if (!known.contains(i)) {
        _guesses.add(
          Guess(
            pegs: List<Peg>.filled(_pegs, -1),
            feedback: const Feedback(0, 0),
          ),
        );
        if (_guesses.length >= totalRows) _outcome = GameOutcome.lost;
        return _code[i];
      }
    }
    return null;
  }

  /// Standard Mastermind scoring with peg consumption.
  static Feedback score(List<Peg> guess, List<Peg> code) {
    if (guess.length != code.length) {
      throw ArgumentError('guess and code must have the same length');
    }
    final codeLeft = List<bool>.filled(code.length, false);
    final guessLeft = List<bool>.filled(guess.length, false);

    var exact = 0;
    for (var i = 0; i < code.length; i += 1) {
      if (guess[i] == code[i]) {
        exact += 1;
        codeLeft[i] = true;
        guessLeft[i] = true;
      }
    }

    var partial = 0;
    for (var i = 0; i < guess.length; i += 1) {
      if (guessLeft[i]) continue;
      for (var j = 0; j < code.length; j += 1) {
        if (codeLeft[j]) continue;
        if (code[j] == guess[i]) {
          partial += 1;
          codeLeft[j] = true;
          break;
        }
      }
    }
    return Feedback(exact, partial);
  }

  /// For the reveal animation and for tests.
  List<Peg> get debugCode => List<Peg>.unmodifiable(_code);
}
