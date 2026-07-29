import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// TVP encode tests — go-mssqldb `TVP.encode` / ms-tds §2.2.5.5.5.

Future<Uint8List> _captureRpc(Map<String, Object?> params) async {
  final pair = await TdsSocketPair.open();
  final completer = Completer<Uint8List>();
  final chunks = BytesBuilder(copy: false);
  pair.server.listen((data) {
    chunks.add(data);
    final all = chunks.toBytes();
    if (all.length >= headerSize) {
      final size = (all[2] << 8) | all[3];
      if (all.length >= size && !completer.isCompleted) {
        completer.complete(Uint8List.fromList(all));
      }
    }
  });
  await RpcRequest.sendExecuteSql(
    TdsBuffer(pair.client),
    'SELECT 1 FROM @t',
    params,
  );
  final pkt = await completer.future.timeout(const Duration(seconds: 2));
  await pair.close();
  return pkt;
}

void main() {
  group('MssqlTvp helpers', () {
    test('splitTypeName schema.name', () {
      expect(MssqlTvp.splitTypeName('dbo.IdList'), ('dbo', 'IdList'));
      expect(MssqlTvp.splitTypeName('[dbo].[IdList]'), ('dbo', 'IdList'));
      expect(MssqlTvp.splitTypeName('IdList'), ('', 'IdList'));
    });

    test('readonlyDecl', () {
      final t = MssqlTvp(
        typeName: 'dbo.IdList',
        columns: [const BulkColumn('Id', BulkColumnType.bigInt)],
      );
      expect(t.readonlyDecl, 'dbo.IdList READONLY');
    });

    test('infer factory', () {
      final t = MssqlTvp.infer(
        typeName: 'dbo.T',
        columnNames: ['Id', 'Name'],
        rows: [
          [1, 'a'],
        ],
      );
      expect(t.columns[0].type, BulkColumnType.bigInt);
      expect(t.columns[1].type, BulkColumnType.nVarChar);
    });
  });

  group('TVP wire encode', () {
    test('RPC packet contains typeTvp and TVP row tokens', () async {
      final tvp = MssqlTvp(
        typeName: 'dbo.IdList',
        columns: [
          const BulkColumn('Id', BulkColumnType.bigInt),
          const BulkColumn('Label', BulkColumnType.nVarChar),
        ],
        rows: [
          [1, 'x'],
          [null, null],
        ],
      );
      final pkt = await _captureRpc({'t': tvp});
      expect(pkt[0], packRPCRequest);
      final body = pkt.sublist(headerSize);
      expect(body.contains(typeTvp), isTrue);
      expect(body.contains(tvpRowToken), isTrue);
      // Two END tokens: after metadata and after rows
      var ends = 0;
      for (final b in body) {
        if (b == tvpEndToken) ends++;
      }
      expect(ends, greaterThanOrEqualTo(2));
    });

    test('empty rows still sends typeTvp metadata', () async {
      final tvp = MssqlTvp(
        typeName: 'dbo.IdList',
        columns: [const BulkColumn('Id', BulkColumnType.bigInt)],
        rows: const [],
      );
      final pkt = await _captureRpc({'t': tvp});
      expect(pkt.sublist(headerSize).contains(typeTvp), isTrue);
      expect(tvp.rows, isEmpty);
    });
  });
}
