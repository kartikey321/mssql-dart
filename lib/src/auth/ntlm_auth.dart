import 'dart:typed_data';

/// Windows / NTLM authentication — not yet implemented.
///
/// Placeholder: NTLM support will be added in a later phase.
class NtlmAuth {
  final String domain;
  final String username;
  final String password;
  final String? workstation;

  NtlmAuth({
    required this.domain,
    required this.username,
    required this.password,
    this.workstation,
  });

  Uint8List negotiateMessage() =>
      throw UnimplementedError('NTLM auth not yet implemented');
}
