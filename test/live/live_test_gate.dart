import 'dart:io';

import 'package:test/test.dart';

/// Opt-in gate for `test/live`. Set `MSSQL_LIVE_TESTS=1` to enable.
bool get liveTestsEnabled => Platform.environment['MSSQL_LIVE_TESTS'] == '1';

void registerLiveTestsDisabled() {
  test(
    'live SQL Server tests are disabled',
    () {},
    skip: 'Set MSSQL_LIVE_TESTS=1 to run test/live.',
  );
}

/// Call at the start of each live suite `main()`.
/// Returns `false` when the caller should `return` without registering tests.
bool beginLiveSuite() {
  if (!liveTestsEnabled) {
    registerLiveTestsDisabled();
    return false;
  }
  return true;
}
