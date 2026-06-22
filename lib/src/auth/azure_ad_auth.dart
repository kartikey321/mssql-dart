import 'dart:convert';

import 'package:http/http.dart' as http;

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
  factory AzureAdAuth.fromToken(String token) => AzureAdAuth._(token);

  /// Acquire a token using username + password (ROPC flow).
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
    return AzureAdAuth._(_extractToken(response));
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
    return AzureAdAuth._(_extractToken(response));
  }

  static String _extractToken(http.Response response) {
    if (response.statusCode != 200) {
      throw StateError(
        'Azure AD token request failed (${response.statusCode}): ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = body['access_token'] as String?;
    if (token == null) throw StateError('No access_token in Azure AD response');
    return token;
  }
}
