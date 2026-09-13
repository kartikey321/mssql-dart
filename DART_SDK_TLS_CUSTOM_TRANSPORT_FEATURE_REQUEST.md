# Comment draft for dart-lang/sdk#62174

Target: https://github.com/dart-lang/sdk/issues/62174
("Feature Request: Make `SecureSocket` TLS APIs More Flexible for Protocols
with Encapsulated Handshakes (e.g., SQL Server TDS)")

Already filed by someone else (independently hit the same wall building a
different pure-Dart TDS driver), triaged P3, maintainer said "large
backlog... welcome community contributions." Post as a comment there, not
a new issue.

To post: `gh issue comment 62174 --repo dart-lang/sdk --body-file <this
file, minus this header>`

---

We maintain [`package:mssql`](https://pub.dev/packages/mssql), a pure Dart SQL Server TDS driver, and are running into this exact same issue.

## Confirming the `RawSecureSocket.secure()` limitation, one level deeper

The original report notes `SecureSocket.secure()` casts to the concrete `_Socket` and detaches the underlying `RawSocket`, so a `Socket`-implementing adapter doesn't work. It's the same story one layer down: `RawSecureSocket.secure(RawSocket socket, ...)` ([secure_socket.dart:402](https://github.com/dart-lang/sdk/blob/main/sdk/lib/io/secure_socket.dart)) mutates the socket it's given directly —

```dart
static Future<RawSecureSocket> secure(
  RawSocket socket, {
  ...
}) {
  socket.readEventsEnabled = false;
  socket.writeEventsEnabled = false;
  return _RawSecureSocket.connect(
    host != null ? host : socket.address.host,
    socket.port,
    ...
```

— reading `socket.address.host` / `socket.port` and toggling event flags on the instance it's handed. So implementing `RawSocket` yourself to intercept bytes doesn't work either; there's no level of the public API where a custom transport can be substituted.

## Our workaround, and the bug class it invites

Like the original report, we work around this with a loopback socket pair: `SecureSocket.secure()` runs over one side, and our own code on the other side wraps/unwraps TDS PRELOGIN framing during the handshake and passes through raw TLS records afterward. It works for the handshake, but this shape of workaround invites real correctness bugs in steady-state operation, not just fragility in the abstract — we hit one ourselves. Forwarding writes from the loopback side back onto the real socket needs a chained future so record order is preserved, and it's easy to write that chain so a single write failure permanently wedges it, silently dropping every subsequent write with no error surfaced anywhere. We're pushing a fix for that on our end now. But it's a bug in *our* workaround, not in Dart — the underlying problem is that the public API forces this socket-pair/manual-bridge shape in the first place instead of offering a direct BIO-style interface, so every implementation of this pattern has to get the same bidirectional-forwarding logic right from scratch.

## Additional API surface that would be needed for full parity

Beyond what's already listed, to match what Node's `tls.connect()` over a `Duplex`, Go's `crypto/tls.Client` over `net.Conn`, or .NET's `SslStream(Stream, ...)` already provide:

- hostname/certificate validation equivalent to today's `SecureSocket` (`onBadCertificate`, `SecurityContext`)
- ALPN via `supportedProtocols`, with the selected protocol readable afterward
- `keyLog` support (useful for Wireshark-based debugging of exactly this kind of protocol)
- backpressure-safe async writes on the plaintext side
- clean close/shutdown semantics distinct from the underlying transport's

None of this needs to be SQL-Server-specific — any protocol that frames a TLS handshake inside its own messages (which is more common than it might seem: this exact "TLS-inside-application-framing during negotiation, then raw TLS after" shape is also how SMTP STARTTLS-adjacent and some legacy proxy protocols work) hits the identical wall.

## Workaround in the meantime, and its real limits

SQL Server 2022+ (and Azure SQL Database/Managed Instance) added TDS 8.0 "strict" encryption, which does TLS *before* any TDS framing — full parity with a normal TLS-first protocol like HTTPS, negotiated via ALPN (`tds/8.0`). That path works today with the existing public API — plain `SecureSocket.connect(host, port, supportedProtocols: ['tds/8.0'], ...)`, no custom transport needed at all.

It's a real escape hatch, but narrower than it first looks:

- SQL Server 2012–2019, and Azure SQL Edge, only support the older TDS 7.x encrypted-PRELOGIN handshake this issue is about — no TDS 8.0 there at all.
- SQL Server 2022 on Linux/Docker does not reliably support TDS 8.0 strict either, independent of certificate configuration (see [microsoft/mssql-docker#878](https://github.com/microsoft/mssql-docker/issues/878) — TDS 8.0 support on Linux only arrived with SQL Server 2025, and even then only negotiates TLS 1.2, not 1.3).
- So validating a TDS 8.0 client implementation currently means testing against native Windows SQL Server 2022+, Azure SQL, or SQL Server 2025 on Linux — not the commonly-used `mssql/server:2022-latest` Docker image.

So TDS 8.0 unblocks *new* SQL Server 2022+/Azure SQL deployments, but does nothing for anyone who still needs encrypted connections to SQL Server 2012–2019 or Azure SQL Edge — which is exactly the gap a custom-transport TLS API would close.
