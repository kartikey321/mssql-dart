import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline tests for [MssqlIsolationLevel] and savepoint name validation.
void main() {
  group('MssqlIsolationLevel', () {
    test('sqlName matches T-SQL SET TRANSACTION ISOLATION LEVEL', () {
      expect(
        MssqlIsolationLevel.readUncommitted.sqlName,
        equals('READ UNCOMMITTED'),
      );
      expect(
        MssqlIsolationLevel.readCommitted.sqlName,
        equals('READ COMMITTED'),
      );
      expect(
        MssqlIsolationLevel.repeatableRead.sqlName,
        equals('REPEATABLE READ'),
      );
      expect(MssqlIsolationLevel.snapshot.sqlName, equals('SNAPSHOT'));
      expect(
        MssqlIsolationLevel.serializable.sqlName,
        equals('SERIALIZABLE'),
      );
    });
  });

  group('assertSavepointName', () {
    test('accepts simple identifiers', () {
      expect(() => assertSavepointName('sp1'), returnsNormally);
      expect(() => assertSavepointName('_x'), returnsNormally);
      expect(() => assertSavepointName('SavePoint_2'), returnsNormally);
    });

    test('rejects empty, too long, and unsafe names', () {
      expect(() => assertSavepointName(''), throwsArgumentError);
      expect(() => assertSavepointName('a' * 33), throwsArgumentError);
      expect(() => assertSavepointName('sp-1'), throwsArgumentError);
      expect(() => assertSavepointName('sp;DROP'), throwsArgumentError);
      expect(() => assertSavepointName('1sp'), throwsArgumentError);
    });
  });
}
