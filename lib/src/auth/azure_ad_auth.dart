import 'dart:convert';

import 'package:http/http.dart' as http;

/// STS URL + SPN from a TDS [tokenFedAuthInfo] (ADAL / interactive FedAuth).
///
/// Parsed per ms-tds §2.2.7.12 / go-mssqldb `parseFedAuthInfo`.
class FedAuthInfo {
  final String stsUrl;
  final String serverSpn;

  const FedAuthInfo({this.stsUrl = '', this.serverSpn = ''});
}

/// Azure AD authentication for Azure SQL Database.
///
/// Acquires a bearer token from the Azure AD token endpoint and passes it
/// to LOGIN7 via the FedAuth feature extension (ms-tds §2.2.6.3 FeatureExt).
///
/// Supported flows:
///   - [fromUsernamePassword] – Resource Owner Password Credentials (ROPC)
///   - [fromClientSecret]     – Client Credentials (service-to-service)
///   - [fromToken]            – Pre-acquired bearer token (bring your own)
class AzureAdAuth {
  final String bearerToken;

  const AzureAdAuth._(this.bearerToken);

  /// Use a pre-acquired bearer token.
  factory AzureAdAuth.fromToken(String token) {
    if (token.trim().isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    return AzureAdAuth._(token);
  }

  /// Acquire a token using username + password (legacy ROPC flow).
  ///
  /// This flow exposes the user's password to the application and cannot
  /// satisfy MFA. Use a pre-acquired token from a modern interactive flow.
  @Deprecated(
    'ROPC is insecure and incompatible with MFA. Use fromToken with a '
    'token acquired through a modern interactive flow instead.',
  )
  static Future<AzureAdAuth> fromUsernamePassword({
    required String tenantId,
    required String clientId,
    required String username,
    required String password,
    String resource = 'https://database.windows.net/',
  }) async {
    final url = Uri.parse(
      'https://login.microsoftonline.com/$tenantId/oauth2/token',
    );
    final response = await http.post(url, body: {
      'grant_type': 'password',
      'client_id': clientId,
      'username': username,
      'password': password,
      'resource': resource,
    });
    return AzureAdAuth._(extractAccessToken(response));
  }

  /// Acquire a token using client credentials (service principal).
  static Future<AzureAdAuth> fromClientSecret({
    required String tenantId,
    required String clientId,
    required String clientSecret,
    String resource = 'https://database.windows.net/',
  }) async {
    final url = Uri.parse(
      'https://login.microsoftonline.com/$tenantId/oauth2/token',
    );
    final response = await http.post(url, body: {
      'grant_type': 'client_credentials',
      'client_id': clientId,
      'client_secret': clientSecret,
      'resource': resource,
    });
    return AzureAdAuth._(extractAccessToken(response));
  }

  /// Parses `access_token` from an Azure AD token endpoint [response].
  ///
  /// Exposed for offline unit tests (no network).
  static String extractAccessToken(http.Response response) {
    final body = _decodeResponse(response.body);
    if (response.statusCode != 200) {
      throw AzureAdTokenException(
        statusCode: response.statusCode,
        error: _stringField(body, 'error') ?? 'token_request_failed',
        description: _stringField(body, 'error_description'),
      );
    }
    final token = _stringField(body, 'access_token');
    if (token == null) {
      throw const AzureAdTokenException(
        statusCode: 200,
        error: 'invalid_token_response',
        description: 'Response did not contain a non-empty access_token.',
      );
    }
    return token;
  }

  static Map<String, dynamic>? _decodeResponse(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      return null;
    }
  }

  static String? _stringField(Map<String, dynamic>? body, String name) {
    final value = body?[name];
    return value is String && value.trim().isNotEmpty ? value : null;
  }
}

/// A structured failure returned by the Microsoft Entra token endpoint.
///
/// The exception intentionally excludes the raw response body, which may be
/// logged by callers and can contain unrelated gateway diagnostics.
class AzureAdTokenException implements Exception {
  final int statusCode;
  final String error;
  final String? description;

  const AzureAdTokenException({
    required this.statusCode,
    required this.error,
    this.description,
  });

  @override
  String toString() {
    final detail = description == null ? '' : ': ${_sanitize(description!)}';
    return 'AzureAdTokenException(HTTP $statusCode, $error)$detail';
  }

  static String _sanitize(String value) {
    final singleLine = value.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return singleLine.length <= 512
        ? singleLine
        : '${singleLine.substring(0, 512)}...';
  }
}
