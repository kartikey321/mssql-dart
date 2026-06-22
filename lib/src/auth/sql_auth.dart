/// SQL Server authentication (username + password in LOGIN7 packet).
///
/// This is the simplest auth mode: credentials are embedded directly in the
/// LOGIN7 packet with the password bytes obfuscated per ms-tds §2.2.6.3.
/// The obfuscation is handled by [Login7]; this class is a marker/config holder.
class SqlAuth {
  final String username;
  final String password;

  const SqlAuth({required this.username, required this.password});
}
