import 'package:http/http.dart' as http;
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline Azure AD token response parsing (no network).
///
/// Complements Login7 FedAuth encode tests — token acquisition HTTP is mocked
/// by feeding synthetic [http.Response] bodies into [AzureAdAuth.extractAccessToken].
void main() {
  group('AzureAdAuth.extractAccessToken', () {
    test('reads access_token from 200 JSON body', () {
      final token = AzureAdAuth.extractAccessToken(
        http.Response(
            '{"access_token":"abc.def.ghi","token_type":"Bearer"}', 200),
      );
      expect(token, equals('abc.def.ghi'));
    });

    test('fromToken stores bearer for FedAuth path', () {
      final auth = AzureAdAuth.fromToken('preacquired');
      expect(auth.bearerToken, equals('preacquired'));
    });

    test('non-200 throws structured OAuth error without raw response body', () {
      expect(
        () => AzureAdAuth.extractAccessToken(
          http.Response(
            '{"error":"invalid_client","error_description":"bad secret",'
            '"internal":"do-not-log"}',
            401,
          ),
        ),
        throwsA(isA<AzureAdTokenException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.error, 'error', 'invalid_client')
            .having((e) => e.toString(), 'message', contains('bad secret'))
            .having(
                (e) => e.toString(), 'message', isNot(contains('internal')))),
      );
    });

    test('missing access_token throws structured response error', () {
      expect(
        () => AzureAdAuth.extractAccessToken(
          http.Response('{"token_type":"Bearer"}', 200),
        ),
        throwsA(isA<AzureAdTokenException>()
            .having((e) => e.error, 'error', 'invalid_token_response')),
      );
    });

    test('malformed success response throws structured response error', () {
      expect(
        () => AzureAdAuth.extractAccessToken(http.Response('not JSON', 200)),
        throwsA(isA<AzureAdTokenException>()),
      );
    });

    test('fromToken rejects blank bearer token', () {
      expect(() => AzureAdAuth.fromToken('  '), throwsArgumentError);
    });
  });
}
