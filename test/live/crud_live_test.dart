import 'live_test_database.dart';
import 'live_test_gate.dart';
import 'live_test_helpers.dart';
import 'package:test/test.dart';

void main() {
  if (!beginLiveSuite()) return;

  late LiveTestDatabase database;
  late dynamic connection;

  setUpAll(() async {
    await waitForSqlServer();
    database = await LiveTestDatabase.create();
    connection = await database.open();
    await connection.execute(
      'CREATE TABLE live_test.person ('
      'id bigint IDENTITY PRIMARY KEY, name nvarchar(200) NOT NULL, '
      'age int NULL, active bit NOT NULL, version rowversion)',
    );
  });
  tearDownAll(() async {
    await connection.close();
    await database.dispose();
  });

  test('insert, select, update, and delete use parameterized values', () async {
    final inserted = await connection.query(
      'INSERT INTO live_test.person (name, age, active) '
      'OUTPUT INSERTED.id, INSERTED.version VALUES (@name, @age, @active)',
      {'name': "O'Brien", 'age': 30, 'active': true},
    );
    final id = inserted.single['id'] as int;
    final version = inserted.single['version'] as List<int>;

    final updated = await connection.query(
      'UPDATE live_test.person SET age = @age OUTPUT INSERTED.age '
      'WHERE id = @id AND version = @version',
      {'age': 31, 'id': id, 'version': version},
    );
    expect(updated.single['age'], 31);

    final deleted = await connection.query(
      'DELETE FROM live_test.person OUTPUT DELETED.name WHERE id = @id',
      {'id': id},
    );
    expect(deleted.single['name'], "O'Brien");
  });
}
