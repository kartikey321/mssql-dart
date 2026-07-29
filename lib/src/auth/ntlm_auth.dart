import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'md4.dart';

/// AV_PAIR Ids ([MS-NLMP] §2.2.2.1).
const int _avEol = 0x0000;
const int _avFlags = 0x0006;
const int _avTimestamp = 0x0007;
const int _avChannelBindings = 0x000A;

/// MsvAvFlags bit: client provides a MIC ([MS-NLMP] §2.2.2.1).
const int _avFlagMic = 0x00000002;

/// Parsed NTLMSSP Type 2 CHALLENGE message ([MS-NLMP] CHALLENGE_MESSAGE).
class NtlmChallenge {
  final int flags;
  final Uint8List serverChallenge;
  final String targetName;
  final Uint8List targetInfo;

  /// Raw Type 2 bytes (needed for MIC over NEGOTIATE‖CHALLENGE‖AUTHENTICATE).
  final Uint8List rawMessage;

  const NtlmChallenge({
    required this.flags,
    required this.serverChallenge,
    required this.targetName,
    required this.targetInfo,
    required this.rawMessage,
  });

  static const int negotiateTargetInfo = 0x00800000;

  /// Parses a Type 2 message. Throws [FormatException] if the header is invalid.
  factory NtlmChallenge.parse(Uint8List msg) {
    if (msg.length < 32) {
      throw FormatException('NTLM Type 2 too short (${msg.length})');
    }
    if (!_hasSignature(msg)) {
      throw FormatException('NTLM Type 2 missing NTLMSSP signature');
    }
    final bd = ByteData.sublistView(msg);
    final type = bd.getUint32(8, Endian.little);
    if (type != 2) {
      throw FormatException('Expected NTLM Type 2, got $type');
    }

    final targetLen = bd.getUint16(12, Endian.little);
    final targetOff = bd.getUint32(16, Endian.little);
    final flags = bd.getUint32(20, Endian.little);
    final challenge = Uint8List.fromList(msg.sublist(24, 32));

    var targetName = '';
    if (targetLen > 0) {
      if (targetOff + targetLen > msg.length) {
        throw FormatException('NTLM Type 2 target name exceeds message length');
      }
      final raw = msg.sublist(targetOff, targetOff + targetLen);
      targetName = (flags & NtlmAuth.negotiateUnicode) != 0
          ? _fromUtf16Le(raw)
          : latin1.decode(raw);
    }

    var targetInfo = Uint8List(0);
    if (msg.length >= 48 && (flags & negotiateTargetInfo) != 0) {
      final infoLen = bd.getUint16(40, Endian.little);
      final infoOff = bd.getUint32(44, Endian.little);
      if (infoLen > 0) {
        if (infoOff + infoLen > msg.length) {
          throw FormatException(
            'NTLM Type 2 target info exceeds message length',
          );
        }
        targetInfo =
            Uint8List.fromList(msg.sublist(infoOff, infoOff + infoLen));
      }
    }

    return NtlmChallenge(
      flags: flags,
      serverChallenge: challenge,
      targetName: targetName,
      targetInfo: targetInfo,
      rawMessage: Uint8List.fromList(msg),
    );
  }
}

/// Windows / NTLM authentication helpers for TDS SSPI.
///
/// Supports:
/// - Type 1 NEGOTIATE ([negotiateMessage])
/// - Type 2 parse ([NtlmChallenge.parse])
/// - Type 3 AUTHENTICATE with NTLMv2 ([authenticateMessage]), including:
///   - Version + MIC fields (88-byte header, go-mssqldb layout)
///   - MIC when TargetInfo contains MsvAvTimestamp ([MS-NLMP] §3.1.5.1.2)
///   - KEY_EXCH EncryptedRandomSessionKey (RC4) when negotiated
///   - MsvAvChannelBindings for TLS Extended Protection ([RFC 5929])
///
/// Spec: [MS-NLMP]; vectors from curl/davenport NTLM docs.
class NtlmAuth {
  final String domain;
  final String username;
  final String password;
  final String? workstation;

  /// Last Type 1 message from [negotiateMessage] (used for MIC).
  Uint8List? _lastNegotiate;

  /// 16-byte [MsvAvChannelBindings] hash ([MS-NLMP] §2.2.2.1), typically from
  /// [channelBindingTokenFromCertificate] after TLS. Null = omit AV_PAIR.
  Uint8List? channelBindings;

  NtlmAuth({
    required this.domain,
    required this.username,
    required this.password,
    this.workstation,
    this.channelBindings,
  });

  // Common negotiate flags (MS-NLMP §2.2.2.5).
  static const int negotiateUnicode = 0x00000001;
  static const int negotiateOem = 0x00000002;
  static const int requestTarget = 0x00000004;
  static const int negotiateSign = 0x00000010;
  static const int negotiateSeal = 0x00000020;
  static const int negotiateNtlm = 0x00000200;
  static const int negotiateAlwaysSign = 0x00008000;
  static const int negotiateOemDomainSupplied = 0x00001000;
  static const int negotiateOemWorkstationSupplied = 0x00002000;
  static const int negotiateExtendedSessionSecurity = 0x00080000;
  static const int negotiateTargetInfo = 0x00800000;
  static const int negotiateVersion = 0x02000000;
  static const int negotiate128 = 0x20000000;
  static const int negotiateKeyExch = 0x40000000;
  static const int negotiate56 = 0x80000000;

  /// Builds an NTLMSSP Type 1 NEGOTIATE message (OEM domain + workstation).
  Uint8List negotiateMessage() {
    final domainBytes = latin1.encode(domain.toUpperCase());
    final wsName = (workstation ?? 'WORKSTATION').toUpperCase();
    final wsBytes = latin1.encode(wsName);

    var flags = negotiateUnicode |
        negotiateOem |
        requestTarget |
        negotiateNtlm |
        negotiateAlwaysSign |
        negotiateExtendedSessionSecurity |
        negotiateVersion;
    if (domainBytes.isNotEmpty) flags |= negotiateOemDomainSupplied;
    if (wsBytes.isNotEmpty) flags |= negotiateOemWorkstationSupplied;

    // 40-byte header with Version (go-mssqldb InitialBytes layout).
    const headerLen = 40;
    final total = headerLen + domainBytes.length + wsBytes.length;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out.setRange(0, 8, _signature);
    bd.setUint32(8, 1, Endian.little);
    bd.setUint32(12, flags, Endian.little);

    var payloadOff = headerLen;
    bd.setUint16(16, domainBytes.length, Endian.little);
    bd.setUint16(18, domainBytes.length, Endian.little);
    bd.setUint32(20, domainBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (domainBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + domainBytes.length, domainBytes);
      payloadOff += domainBytes.length;
    }

    bd.setUint16(24, wsBytes.length, Endian.little);
    bd.setUint16(26, wsBytes.length, Endian.little);
    bd.setUint32(28, wsBytes.isEmpty ? 0 : payloadOff, Endian.little);
    if (wsBytes.isNotEmpty) {
      out.setRange(payloadOff, payloadOff + wsBytes.length, wsBytes);
    }

    // Version zeros (ProductMajor/Minor/Build/Reserved/NTLMRevision).
    // offsets 32..39 already zero-filled.

    _lastNegotiate = out;
    return out;
  }

  /// Builds an NTLMSSP Type 3 AUTHENTICATE (NTLMv2) in response to [challenge].
  ///
  /// [clientChallenge], [timestamp], and [exportedSessionKey] may be supplied
  /// for deterministic tests; otherwise random / current FILETIME are used.
  ///
  /// Uses the Type 1 from the last [negotiateMessage] call (and [challenge]'s
  /// raw Type 2) when computing the MIC. When [channelBindings] is set, embeds
  /// MsvAvChannelBindings in the NTLMv2 blob TargetInfo.
  Uint8List authenticateMessage(
    NtlmChallenge challenge, {
    Uint8List? clientChallenge,
    Uint8List? timestamp,
    Uint8List? exportedSessionKey,
    Uint8List? negotiateMessage,
  }) {
    final cc = clientChallenge ?? _randomBytes(8);
    if (cc.length != 8) {
      throw ArgumentError('clientChallenge must be 8 bytes');
    }
    final ts = timestamp ?? _windowsFiletimeNow();
    if (ts.length != 8) {
      throw ArgumentError('timestamp must be 8 bytes');
    }

    final wantMic = _targetInfoHasTimestamp(challenge.targetInfo);
    final cbind = channelBindings;
    if (cbind != null && cbind.length != 16) {
      throw ArgumentError('channelBindings must be 16 bytes (MD5 CBT)');
    }
    final targetInfo = _clientTargetInfo(
      challenge.targetInfo,
      mic: wantMic,
      channelBindingHash: cbind,
    );

    final targetForHash =
        challenge.targetName.isNotEmpty ? challenge.targetName : domain;
    final ntHash = ntPasswordHash(password);
    final ntlmv2Hash = ntowfV2(ntHash, username, targetForHash);

    final blob = _ntlmv2Blob(ts, cc, targetInfo);
    final ntProof =
        _hmacMd5(ntlmv2Hash, [...challenge.serverChallenge, ...blob]);
    final ntResponse = Uint8List.fromList([...ntProof, ...blob]);

    final lmProof = _hmacMd5(ntlmv2Hash, [...challenge.serverChallenge, ...cc]);
    final lmResponse = Uint8List.fromList([...lmProof, ...cc]);

    // SessionBaseKey = HMAC_MD5(ResponseKeyNT, NTProofStr) ([MS-NLMP] §3.3.2).
    final sessionBaseKey = _hmacMd5(ntlmv2Hash, ntProof);
    final keyExchangeKey = sessionBaseKey;

    final doKeyExch = (challenge.flags & negotiateKeyExch) != 0;
    late final Uint8List exportedKey;
    late final Uint8List encryptedSessionKey;
    if (doKeyExch) {
      exportedKey = exportedSessionKey ?? _randomBytes(16);
      if (exportedKey.length != 16) {
        throw ArgumentError('exportedSessionKey must be 16 bytes');
      }
      encryptedSessionKey = rc4(keyExchangeKey, exportedKey);
    } else {
      exportedKey = keyExchangeKey;
      encryptedSessionKey = Uint8List(0);
    }

    final domainU = _utf16Le(domain);
    final userU = _utf16Le(username);
    final wsU = _utf16Le(workstation ?? 'WORKSTATION');

    // 88-byte header: fields + Version(8) + MIC(16) — go-mssqldb layout.
    const headerLen = 88;
    final total = headerLen +
        lmResponse.length +
        ntResponse.length +
        domainU.length +
        userU.length +
        wsU.length +
        encryptedSessionKey.length;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out.setRange(0, 8, _signature);
    bd.setUint32(8, 3, Endian.little);

    var off = headerLen;
    void writeBuf(int fieldOff, Uint8List data) {
      bd.setUint16(fieldOff, data.length, Endian.little);
      bd.setUint16(fieldOff + 2, data.length, Endian.little);
      bd.setUint32(fieldOff + 4, off, Endian.little);
      out.setRange(off, off + data.length, data);
      off += data.length;
    }

    writeBuf(12, lmResponse);
    writeBuf(20, ntResponse);
    writeBuf(28, domainU);
    writeBuf(36, userU);
    writeBuf(44, wsU);
    writeBuf(52, encryptedSessionKey);

    var flags =
        challenge.flags | negotiateUnicode | negotiateNtlm | negotiateVersion;
    flags &= ~negotiateOem;
    if (doKeyExch) flags |= negotiateKeyExch;
    bd.setUint32(60, flags, Endian.little);

    // Version (zeros) at 64..71; MIC placeholder zeros at 72..87.

    if (wantMic) {
      final type1 = negotiateMessage ?? _lastNegotiate;
      if (type1 == null) {
        throw StateError(
          'NTLM MIC required (MsvAvTimestamp present) but negotiateMessage '
          'was not provided — call negotiateMessage() first',
        );
      }
      final mic = _hmacMd5(exportedKey, [
        ...type1,
        ...challenge.rawMessage,
        ...out, // MIC field still zero
      ]);
      out.setRange(72, 88, mic);
    }

    return out;
  }

  /// NT hash = MD4(UTF-16LE(password)).
  static Uint8List ntPasswordHash(String password) => md4(_utf16Le(password));

  /// NTOWFv2 = HMAC_MD5(NT hash, UTF-16LE(Upper(User) + Domain)).
  static Uint8List ntowfV2(Uint8List ntHash, String user, String domain) {
    final identity = _utf16Le('${user.toUpperCase()}$domain');
    return _hmacMd5(ntHash, identity);
  }

  /// Builds the 16-byte MsvAvChannelBindings value for `tls-server-end-point`
  /// from a peer certificate DER encoding ([RFC 5929] + [MS-NLMP] §2.2.2.1).
  ///
  /// Steps: SHA-256(cert DER) → `tls-server-end-point:` + hash → wrap in a
  /// zero-address gss_channel_bindings_struct → MD5.
  static Uint8List channelBindingTokenFromCertificate(Uint8List certDer) {
    final certHash = Uint8List.fromList(sha256.convert(certDer).bytes);
    final appData = utf8.encode('tls-server-end-point:') + certHash;
    return channelBindingTokenFromApplicationData(Uint8List.fromList(appData));
  }

  /// MD5 of a Windows-style gss_channel_bindings_struct with zero addresses
  /// and the given [applicationData] (already including any type prefix).
  static Uint8List channelBindingTokenFromApplicationData(
    Uint8List applicationData,
  ) {
    final struct = BytesBuilder(copy: false);
    struct.add(Uint8List(8)); // initiator_addtype + initiator_addr_len
    struct.add(Uint8List(8)); // acceptor_addtype + acceptor_addr_len
    final len = Uint8List(4);
    ByteData.sublistView(len)
        .setUint32(0, applicationData.length, Endian.little);
    struct.add(len);
    struct.add(applicationData);
    return Uint8List.fromList(md5.convert(struct.toBytes()).bytes);
  }

  /// RC4 encrypt/decrypt (same transform). Used for KEY_EXCH session key.
  static Uint8List rc4(Uint8List key, Uint8List data) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    final out = Uint8List(data.length);
    var i = 0;
    j = 0;
    for (var n = 0; n < data.length; n++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[n] = data[n] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  static Uint8List _ntlmv2Blob(
    Uint8List timestamp,
    Uint8List clientChallenge,
    Uint8List targetInfo,
  ) {
    final out = BytesBuilder(copy: false);
    out.add([0x01, 0x01, 0x00, 0x00]); // blob signature
    out.add([0x00, 0x00, 0x00, 0x00]); // reserved
    out.add(timestamp);
    out.add(clientChallenge);
    out.add([0x00, 0x00, 0x00, 0x00]); // unknown
    out.add(targetInfo);
    out.add([0x00, 0x00, 0x00, 0x00]); // unknown
    return out.toBytes();
  }

  static bool _targetInfoHasTimestamp(Uint8List info) {
    var i = 0;
    while (i + 4 <= info.length) {
      final id = info[i] | (info[i + 1] << 8);
      final len = info[i + 2] | (info[i + 3] << 8);
      i += 4;
      if (id == _avEol) return false;
      if (i + len > info.length) {
        throw FormatException('NTLM TargetInfo AV_PAIR exceeds message length');
      }
      if (id == _avTimestamp) return true;
      i += len;
    }
    if (i != info.length) {
      throw FormatException('NTLM TargetInfo has truncated AV_PAIR header');
    }
    return false;
  }

  /// Rebuilds TargetInfo for the client response: optional MIC flag and
  /// optional MsvAvChannelBindings, always terminated with EOL.
  static Uint8List _clientTargetInfo(
    Uint8List info, {
    required bool mic,
    Uint8List? channelBindingHash,
  }) {
    if (!mic && channelBindingHash == null) return info;

    final out = BytesBuilder(copy: false);
    var sawFlags = false;
    var i = 0;
    while (i + 4 <= info.length) {
      final id = info[i] | (info[i + 1] << 8);
      final len = info[i + 2] | (info[i + 3] << 8);
      final valueStart = i + 4;
      if (id == _avEol) break;
      if (valueStart + len > info.length) {
        throw FormatException('NTLM TargetInfo AV_PAIR exceeds message length');
      }
      // Drop any server ChannelBindings; we supply our own.
      if (id == _avChannelBindings) {
        i = valueStart + len;
        continue;
      }
      if (mic && id == _avFlags && len >= 4 && valueStart + 4 <= info.length) {
        sawFlags = true;
        final flags = ByteData.sublistView(info, valueStart, valueStart + 4)
                .getUint32(0, Endian.little) |
            _avFlagMic;
        out.add([_avFlags & 0xFF, (_avFlags >> 8) & 0xFF, 4, 0]);
        final fb = Uint8List(4);
        ByteData.sublistView(fb).setUint32(0, flags, Endian.little);
        out.add(fb);
      } else {
        out.add(info.sublist(i, valueStart + len));
      }
      i = valueStart + len;
    }
    if (i != info.length && (i + 4 > info.length)) {
      throw FormatException('NTLM TargetInfo has truncated AV_PAIR header');
    }
    if (mic && !sawFlags) {
      out.add([_avFlags & 0xFF, (_avFlags >> 8) & 0xFF, 4, 0]);
      final fb = Uint8List(4);
      ByteData.sublistView(fb).setUint32(0, _avFlagMic, Endian.little);
      out.add(fb);
    }
    if (channelBindingHash != null) {
      out.add([
        _avChannelBindings & 0xFF,
        (_avChannelBindings >> 8) & 0xFF,
        16,
        0,
      ]);
      out.add(channelBindingHash);
    }
    out.add([0, 0, 0, 0]); // EOL
    return out.toBytes();
  }

  static Uint8List _hmacMd5(List<int> key, List<int> data) {
    final hmac = Hmac(md5, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  static Uint8List _utf16Le(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      out[i * 2] = c & 0xFF;
      out[i * 2 + 1] = (c >> 8) & 0xFF;
    }
    return out;
  }

  static Uint8List _windowsFiletimeNow() {
    // 100-ns intervals since 1601-01-01.
    final unixNs = DateTime.now().toUtc().microsecondsSinceEpoch * 10;
    final ft = unixNs + 116444736000000000;
    final out = Uint8List(8);
    ByteData.sublistView(out).setUint64(0, ft, Endian.little);
    return out;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

const _signature = [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00];

bool _hasSignature(Uint8List msg) {
  for (var i = 0; i < 8; i++) {
    if (msg[i] != _signature[i]) return false;
  }
  return true;
}

String _fromUtf16Le(List<int> bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(codes);
}
