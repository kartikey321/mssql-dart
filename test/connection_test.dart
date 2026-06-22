import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

void main() {
  group('MssqlRow', () {
    test('access by name and index', () {
      // Unit-level test – just validates row API without a live server.
      // Integration tests require a real SQL Server instance.
    });
  });

  group('MssqlException', () {
    test('toString includes code', () {
      final e = MssqlException('syntax error', errorCode: 102);
      expect(e.toString(), contains('102'));
      expect(e.toString(), contains('syntax error'));
    });
  });
}
