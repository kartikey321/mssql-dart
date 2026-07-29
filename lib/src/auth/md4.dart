import 'dart:typed_data';

/// MD4 message digest (RFC 1320) — required for NTLM NT hash.
///
/// Not available in `package:crypto`; compact pure-Dart port of the MD4
/// compression function.
Uint8List md4(List<int> message) {
  final bitLen = message.length * 8;
  final padLen = (56 - ((message.length + 1) % 64) + 64) % 64;
  final padded = Uint8List(message.length + 1 + padLen + 8);
  padded.setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final bd = ByteData.sublistView(padded);
  bd.setUint32(padded.length - 8, bitLen & 0xFFFFFFFF, Endian.little);
  bd.setUint32(padded.length - 4, (bitLen >> 32) & 0xFFFFFFFF, Endian.little);

  var a = 0x67452301;
  var b = 0xEFCDAB89;
  var c = 0x98BADCFE;
  var d = 0x10325476;

  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
  int f(int x, int y, int z) => (x & y) | ((~x) & z);
  int g(int x, int y, int z) => (x & y) | (x & z) | (y & z);
  int h(int x, int y, int z) => x ^ y ^ z;

  for (var i = 0; i < padded.length; i += 64) {
    final x = List<int>.generate(
      16,
      (j) => bd.getUint32(i + j * 4, Endian.little),
    );
    final aa = a, bb = b, cc = c, dd = d;

    // Round 1
    a = rotl((a + f(b, c, d) + x[0]) & 0xFFFFFFFF, 3);
    d = rotl((d + f(a, b, c) + x[1]) & 0xFFFFFFFF, 7);
    c = rotl((c + f(d, a, b) + x[2]) & 0xFFFFFFFF, 11);
    b = rotl((b + f(c, d, a) + x[3]) & 0xFFFFFFFF, 19);
    a = rotl((a + f(b, c, d) + x[4]) & 0xFFFFFFFF, 3);
    d = rotl((d + f(a, b, c) + x[5]) & 0xFFFFFFFF, 7);
    c = rotl((c + f(d, a, b) + x[6]) & 0xFFFFFFFF, 11);
    b = rotl((b + f(c, d, a) + x[7]) & 0xFFFFFFFF, 19);
    a = rotl((a + f(b, c, d) + x[8]) & 0xFFFFFFFF, 3);
    d = rotl((d + f(a, b, c) + x[9]) & 0xFFFFFFFF, 7);
    c = rotl((c + f(d, a, b) + x[10]) & 0xFFFFFFFF, 11);
    b = rotl((b + f(c, d, a) + x[11]) & 0xFFFFFFFF, 19);
    a = rotl((a + f(b, c, d) + x[12]) & 0xFFFFFFFF, 3);
    d = rotl((d + f(a, b, c) + x[13]) & 0xFFFFFFFF, 7);
    c = rotl((c + f(d, a, b) + x[14]) & 0xFFFFFFFF, 11);
    b = rotl((b + f(c, d, a) + x[15]) & 0xFFFFFFFF, 19);

    // Round 2
    const r2c = 0x5A827999;
    a = rotl((a + g(b, c, d) + x[0] + r2c) & 0xFFFFFFFF, 3);
    d = rotl((d + g(a, b, c) + x[4] + r2c) & 0xFFFFFFFF, 5);
    c = rotl((c + g(d, a, b) + x[8] + r2c) & 0xFFFFFFFF, 9);
    b = rotl((b + g(c, d, a) + x[12] + r2c) & 0xFFFFFFFF, 13);
    a = rotl((a + g(b, c, d) + x[1] + r2c) & 0xFFFFFFFF, 3);
    d = rotl((d + g(a, b, c) + x[5] + r2c) & 0xFFFFFFFF, 5);
    c = rotl((c + g(d, a, b) + x[9] + r2c) & 0xFFFFFFFF, 9);
    b = rotl((b + g(c, d, a) + x[13] + r2c) & 0xFFFFFFFF, 13);
    a = rotl((a + g(b, c, d) + x[2] + r2c) & 0xFFFFFFFF, 3);
    d = rotl((d + g(a, b, c) + x[6] + r2c) & 0xFFFFFFFF, 5);
    c = rotl((c + g(d, a, b) + x[10] + r2c) & 0xFFFFFFFF, 9);
    b = rotl((b + g(c, d, a) + x[14] + r2c) & 0xFFFFFFFF, 13);
    a = rotl((a + g(b, c, d) + x[3] + r2c) & 0xFFFFFFFF, 3);
    d = rotl((d + g(a, b, c) + x[7] + r2c) & 0xFFFFFFFF, 5);
    c = rotl((c + g(d, a, b) + x[11] + r2c) & 0xFFFFFFFF, 9);
    b = rotl((b + g(c, d, a) + x[15] + r2c) & 0xFFFFFFFF, 13);

    // Round 3
    const r3c = 0x6ED9EBA1;
    a = rotl((a + h(b, c, d) + x[0] + r3c) & 0xFFFFFFFF, 3);
    d = rotl((d + h(a, b, c) + x[8] + r3c) & 0xFFFFFFFF, 9);
    c = rotl((c + h(d, a, b) + x[4] + r3c) & 0xFFFFFFFF, 11);
    b = rotl((b + h(c, d, a) + x[12] + r3c) & 0xFFFFFFFF, 15);
    a = rotl((a + h(b, c, d) + x[2] + r3c) & 0xFFFFFFFF, 3);
    d = rotl((d + h(a, b, c) + x[10] + r3c) & 0xFFFFFFFF, 9);
    c = rotl((c + h(d, a, b) + x[6] + r3c) & 0xFFFFFFFF, 11);
    b = rotl((b + h(c, d, a) + x[14] + r3c) & 0xFFFFFFFF, 15);
    a = rotl((a + h(b, c, d) + x[1] + r3c) & 0xFFFFFFFF, 3);
    d = rotl((d + h(a, b, c) + x[9] + r3c) & 0xFFFFFFFF, 9);
    c = rotl((c + h(d, a, b) + x[5] + r3c) & 0xFFFFFFFF, 11);
    b = rotl((b + h(c, d, a) + x[13] + r3c) & 0xFFFFFFFF, 15);
    a = rotl((a + h(b, c, d) + x[3] + r3c) & 0xFFFFFFFF, 3);
    d = rotl((d + h(a, b, c) + x[11] + r3c) & 0xFFFFFFFF, 9);
    c = rotl((c + h(d, a, b) + x[7] + r3c) & 0xFFFFFFFF, 11);
    b = rotl((b + h(c, d, a) + x[15] + r3c) & 0xFFFFFFFF, 15);

    a = (a + aa) & 0xFFFFFFFF;
    b = (b + bb) & 0xFFFFFFFF;
    c = (c + cc) & 0xFFFFFFFF;
    d = (d + dd) & 0xFFFFFFFF;
  }

  final out = Uint8List(16);
  final ob = ByteData.sublistView(out);
  ob.setUint32(0, a, Endian.little);
  ob.setUint32(4, b, Endian.little);
  ob.setUint32(8, c, Endian.little);
  ob.setUint32(12, d, Endian.little);
  return out;
}
