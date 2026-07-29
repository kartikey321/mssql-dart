import 'dart:io';

/// Applies LAN-friendly TCP options after dial (go-mssqldb `keepAlive`).
///
/// - Always enables `TCP_NODELAY` (low-latency TDS).
/// - When [keepAlive] is non-zero, enables `SO_KEEPALIVE` so idle pooled
///   sockets survive LAN / firewall silent drops. On Linux also sets
///   `TCP_KEEPIDLE` to [keepAlive] seconds. Windows uses the OS default
///   probe interval once keepalive is on (`Duration.zero` disables).
void applyMssqlTcpOptions(Socket socket, {required Duration keepAlive}) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}

  if (keepAlive <= Duration.zero) return;

  try {
    socket.setRawOption(
      RawSocketOption.fromBool(
        RawSocketOption.levelSocket,
        _soKeepAlive,
        true,
      ),
    );
  } catch (_) {}

  // TCP_KEEPIDLE (Linux / Android / macOS). Windows has no portable set.
  if (!Platform.isWindows) {
    final idleSecs = keepAlive.inSeconds.clamp(1, 7200);
    try {
      socket.setRawOption(
        RawSocketOption.fromInt(
          RawSocketOption.levelTcp,
          _tcpKeepIdle,
          idleSecs,
        ),
      );
    } catch (_) {}
  }
}

/// SO_KEEPALIVE — Windows `0x0008`, POSIX `9`.
int get _soKeepAlive => Platform.isWindows ? 0x0008 : 9;

/// TCP_KEEPIDLE — Linux `4`, macOS / BSD often `0x10`.
int get _tcpKeepIdle {
  if (Platform.isMacOS || Platform.isIOS) return 0x10;
  return 4; // Linux / Android / others
}
