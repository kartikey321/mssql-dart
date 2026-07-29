import 'dart:ffi';
import 'dart:io';

/// Loads the optional native TLS helper only for encrypted connections.
DynamicLibrary loadMssqlTls() {
  final platform = Platform.operatingSystem;
  final name = nativeTlsLibraryName(platform);
  final override = Platform.environment['MSSQL_TLS_LIBRARY'];
  final candidates = nativeTlsLibraryCandidates(
    operatingSystem: platform,
    currentDirectory: Directory.current.path,
    pathSeparator: Platform.pathSeparator,
    override: override,
  );
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (error) {
      lastError = error;
    }
  }
  {
    throw UnsupportedError(
      'Encrypted SQL Server connections require the optional native TLS helper '
      '($name). Cleartext connections do not require it. ($lastError)',
    );
  }
}

/// Returns the helper filename for a supported native TLS platform.
String nativeTlsLibraryName(String operatingSystem) =>
    switch (operatingSystem) {
      'windows' => 'mssql_tls.dll',
      'linux' || 'android' => 'libmssql_tls.so',
      _ => throw UnsupportedError(
          'Native SQL Server TLS is not supported on $operatingSystem.',
        ),
    };

/// Returns library lookup paths in their preferred order.
///
/// Android's dynamic linker resolves libraries bundled into the APK by name.
/// Desktop development keeps the checked-out helper as a convenient fallback.
List<String> nativeTlsLibraryCandidates({
  required String operatingSystem,
  required String currentDirectory,
  required String pathSeparator,
  String? override,
}) {
  final name = nativeTlsLibraryName(operatingSystem);
  return <String>[
    if (override != null && override.isNotEmpty) override,
    name,
    if (operatingSystem != 'android')
      '$currentDirectory${pathSeparator}native${pathSeparator}bin'
          '$pathSeparator${operatingSystem == 'windows' ? 'windows-x64' : 'linux-x64'}'
          '$pathSeparator$name',
  ];
}
