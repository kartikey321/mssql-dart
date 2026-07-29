import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline Bulk Load BCP encode tests (go-mssqldb bulkcopy.go / ms-tds).

Future<Uint8List> _captureBulk(
  List<BulkColumn> cols,
  List<List<Object?>> rows,
) async {
  final pair = await TdsSocketPair.open();
  final received = BytesBuilder(copy: false);
  final sub = pair.server.listen(received.add);
  final buf = TdsBuffer(pair.client);
  await BulkLoad.send(buf, cols, rows);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  await sub.cancel();
  await pair.close();
  return Uint8List.fromList(received.toBytes());
}

void main() {
  group('BulkLoad helpers', () {
    test('inferColumns from first non-null', () {
      final cols = BulkLoad.inferColumns(
        ['a', 'b', 'c', 'd', 'e'],
        [
          [null, null, null, null, null],
          [1, 'x', true, 1.5, DateTime.utc(2020, 1, 2)],
        ],
      );
      expect(cols.map((c) => c.type).toList(), [
        BulkColumnType.bigInt,
        BulkColumnType.nVarChar,
        BulkColumnType.bit,
        BulkColumnType.float64,
        BulkColumnType.dateTime2,
      ]);
    });

    test('insertBulkSql brackets names', () {
      final sql = BulkLoad.insertBulkSql('dbo.T', [
        const BulkColumn('Id', BulkColumnType.bigInt),
        const BulkColumn('Name', BulkColumnType.nVarChar),
      ]);
      expect(
        sql,
        'INSERT BULK [dbo].[T] ([Id] bigint, [Name] nvarchar(4000))',
      );
    });

    test('insertBulkSql re-quotes bracketed identifiers', () {
      final sql = BulkLoad.insertBulkSql('[dbo].[T]]x]', [
        const BulkColumn('[Id]]x]', BulkColumnType.bigInt),
      ]);
      expect(sql, 'INSERT BULK [dbo].[T]]x] ([Id]]x] bigint)');
    });

    test('insertBulkSql treats SQL metacharacters as identifier text', () {
      final sql = BulkLoad.insertBulkSql('dbo.Users; DROP TABLE dbo.Users--', [
        const BulkColumn(
          'Id] bigint); DROP TABLE dbo.Users--',
          BulkColumnType.bigInt,
        ),
        const BulkColumn(' Name With Spaces ', BulkColumnType.nVarChar),
      ]);
      expect(
        sql,
        'INSERT BULK [dbo].[Users; DROP TABLE dbo].[Users--] '
        '([Id]] bigint); DROP TABLE dbo.Users--] bigint, '
        '[Name With Spaces] nvarchar(4000))',
      );
    });

    test('insertBulkSql rejects invalid identifier parts', () {
      expect(
        () => BulkLoad.insertBulkSql('dbo..T', [
          const BulkColumn('Id', BulkColumnType.bigInt),
        ]),
        throwsArgumentError,
      );
      expect(
        () => BulkLoad.insertBulkSql('dbo.T', [
          const BulkColumn('Bad\nName', BulkColumnType.bigInt),
        ]),
        throwsArgumentError,
      );
      final overlong = List.filled(129, 'a').join();
      expect(
        () => BulkLoad.insertBulkSql('$overlong.T', [
          const BulkColumn('Id', BulkColumnType.bigInt),
        ]),
        throwsArgumentError,
      );
    });

    test('empty rows is caller no-op at API layer', () {
      // Connection.bulkInsert returns 0; encode path requires rows.
      expect(BulkLoad.inferColumns(['a'], []).single.type, BulkColumnType.nVarChar);
    });
  });

  group('BulkLoad wire encode', () {
    test('packet type packBulkLoadBCP with COLMETADATA/ROW/DONE', () async {
      final bytes = await _captureBulk(
        [
          const BulkColumn('Id', BulkColumnType.bigInt),
          const BulkColumn('Name', BulkColumnType.nVarChar),
          const BulkColumn('Ok', BulkColumnType.bit),
        ],
        [
          [42, 'hi', true],
          [null, null, false],
        ],
      );

      expect(bytes[0], packBulkLoadBCP);
      expect(bytes[1] & statusEOM, statusEOM);
      expect(bytes[headerSize], tokenColMetadata);
      final colCount = bytes[headerSize + 1] | (bytes[headerSize + 2] << 8);
      expect(colCount, 3);
      expect(bytes.contains(tokenRow), isTrue);
      expect(bytes.contains(tokenDone), isTrue);
    });

    test('bigint null uses BYTELEN 0 then value row', () async {
      final bytes = await _captureBulk(
        [const BulkColumn('Id', BulkColumnType.bigInt)],
        [
          [null],
          [7],
        ],
      );
      final body = bytes.sublist(headerSize);
      expect(body[0], tokenColMetadata);
      final row0 = body.indexOf(tokenRow);
      expect(body[row0 + 1], 0); // null
      final row1 = body.indexOf(tokenRow, row0 + 1);
      expect(body[row1 + 1], 8);
      expect(body[row1 + 2], 7);
    });
  });
}
