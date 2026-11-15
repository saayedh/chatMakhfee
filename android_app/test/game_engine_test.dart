/// Game rules. Pure Dart, but run through `flutter test` because that is the
/// only runner available once the project has Flutter dependencies resolved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:secretplay/game/game_engine.dart';
import 'package:secretplay/game/models.dart';

void main() {
  group('scoring', () {
    test('counts exact matches', () {
      expect(GameEngine.score([1, 2, 3], [1, 2, 3]), const Feedback(3, 0));
    });

    test('counts colour-only matches', () {
      expect(GameEngine.score([1, 2, 3], [3, 1, 2]), const Feedback(0, 3));
    });

    test('consumes pegs so duplicates cannot be double counted', () {
      // Code has one 1; the guess has two, so the second must not match.
      expect(GameEngine.score([1, 1, 2], [1, 3, 3]), const Feedback(1, 0));
      expect(GameEngine.score([1, 1, 2], [1, 2, 3]), const Feedback(1, 1));
    });

    test('rejects mismatched lengths', () {
      expect(() => GameEngine.score([1], [1, 2]), throwsArgumentError);
    });
  });

  group('round lifecycle', () {
    test('does not accept an incomplete row', () {
      final engine = GameEngine(difficulty: Difficulty.warmup, seed: 1);
      engine.addPeg(0);
      expect(engine.canSubmit, isFalse);
      expect(engine.submit(), isNull);
    });

    test('a full correct row wins and scores stars', () {
      final engine = GameEngine(difficulty: Difficulty.warmup, seed: 7);
      final code = engine.debugCode;
      for (var row = 0; row < 3; row += 1) {
        code.forEach(engine.addPeg);
        engine.submit();
        if (engine.outcome != GameOutcome.inProgress) break;
      }
      expect(engine.outcome, GameOutcome.won);
      expect(engine.stars, greaterThan(0));
      expect(engine.revealedCode, code);
    });

    test('running out of rows loses and reveals the code', () {
      final engine = GameEngine(difficulty: Difficulty.warmup, seed: 3);
      final wrong = List<Peg>.filled(Difficulty.warmup.pegs, -1);
      // Build a guess that is guaranteed wrong by shifting each position.
      for (var row = 0; row < Difficulty.warmup.rows; row += 1) {
        for (var i = 0; i < Difficulty.warmup.pegs; i += 1) {
          engine.addPeg((engine.debugCode[i] + 1) % Difficulty.warmup.colors);
        }
        engine.submit();
      }
      expect(engine.outcome, GameOutcome.lost);
      expect(engine.stars, 0);
      expect(wrong.first, -1);
    });

    test('a hint costs a row', () {
      final engine = GameEngine(difficulty: Difficulty.warmup, seed: 11);
      final before = engine.rowsLeft;
      final hint = engine.takeHint();
      expect(hint, isNotNull);
      expect(engine.rowsLeft, lessThan(before));
    });
  });
}
