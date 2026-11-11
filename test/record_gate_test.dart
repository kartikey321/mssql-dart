import 'package:mssql/src/tds/buf.dart';
import 'package:test/test.dart';

void main() {
  group('RecordGate', () {
    test('completes once the target count is reached', () async {
      final gate = RecordGate();
      var done = false;
      final wait =
          gate.waitFor(2, const Duration(seconds: 1)).then((_) => done = true);

      gate.recordForwarded();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      gate.recordForwarded();
      await wait;
      expect(done, isTrue);
    });

    test('a reached target completes at once', () async {
      final gate = RecordGate()..recordForwarded();
      await gate.waitFor(1, const Duration(seconds: 1));
      expect(gate.count, 1);
    });

    test('times out instead of hanging when no record arrives', () async {
      final gate = RecordGate();
      final stopwatch = Stopwatch()..start();
      await gate.waitFor(1, const Duration(milliseconds: 50));
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(40));

      // A late record after the timeout does not throw.
      gate.recordForwarded();
    });
  });
}
