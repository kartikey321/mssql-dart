import 'dart:io';

Future<void> main() async {
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      14330,
      timeout: const Duration(seconds: 2),
    );
    await s.close();
    stdout.writeln('UP');
  } catch (_) {
    stdout.writeln('DOWN');
  }
}
