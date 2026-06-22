// TDS version identifiers (ms-tds §2.2.6.4)
const int verTDS74 = 0x74000004;

// Packet type bytes (ms-tds §2.2.3.1.1)
const int packSQLBatch = 1;
const int packRPCRequest = 3;
const int packReply = 4;
const int packAttention = 6;
const int packBulkLoadBCP = 7;
const int packFedAuthToken = 8;
const int packTransMgrReq = 14;
const int packLogin7 = 16;
const int packSSPIMessage = 17;
const int packPrelogin = 18;

// Packet status flags
const int statusNormal = 0x00;
const int statusEOM = 0x01; // end of message (last packet)
const int statusResetConn = 0x08;

// PRELOGIN option tokens (ms-tds §2.2.6.4)
const int preloginVersion = 0x00;
const int preloginEncryption = 0x01;
const int preloginInstopt = 0x02;
const int preloginThreadId = 0x03;
const int preloginMars = 0x04;
const int preloginTraceId = 0x05;
const int preloginFedAuthRequired = 0x06;
const int preloginNonceOpt = 0x07;
const int preloginTerminator = 0xFF;

// Encryption negotiation values
const int encryptOff = 0;
const int encryptOn = 1;
const int encryptNotSupported = 2;
const int encryptRequired = 3;

// LOGIN7 OptionFlags1
const int fUseDB = 0x20;
const int fSetLang = 0x80;

// LOGIN7 OptionFlags2
const int fODBC = 0x02;
const int fIntSecurity = 0x80;

// LOGIN7 OptionFlags3
const int fExtension = 0x10;

// Feature extension IDs
const int featExtFedAuth = 0x02;
const int featExtUtf8Support = 0x0A;
const int featExtTerminator = 0xFF;

// FedAuth library identifiers
const int fedAuthLibSecurityToken = 0x01; // ADAL / Azure AD with token
const int fedAuthLibADAL = 0x02;

// Response token IDs (ms-tds §2.2.7)
const int tokenReturnStatus = 0x79;
const int tokenColMetadata = 0x81;
const int tokenOrder = 0xA9;
const int tokenError = 0xAA;
const int tokenInfo = 0xAB;
const int tokenReturnValue = 0xAC;
const int tokenLoginAck = 0xAD;
const int tokenFeatureExtAck = 0xAE;
const int tokenRow = 0xD1;
const int tokenNbcRow = 0xD2;
const int tokenEnvChange = 0xE3;
const int tokenSSPI = 0xED;
const int tokenFedAuthInfo = 0xEE;
const int tokenDone = 0xFD;
const int tokenDoneProc = 0xFE;
const int tokenDoneInProc = 0xFF;

// DONE token flags
const int doneFlagFinal = 0x0000;
const int doneFlagMore = 0x0001;
const int doneFlagError = 0x0002;
const int doneFlagCount = 0x0010;
const int doneFlagAttn = 0x0020;
const int doneFlagSrvError = 0x0100;

// ENVCHANGE types
const int envDatabase = 1;
const int envLanguage = 2;
const int envCharset = 3;
const int envPacketSize = 4;
const int envSqlCollation = 7; // 5-byte binary, not a string
const int envBeginTran = 8;
const int envCommitTran = 9;
const int envRollbackTran = 10;
const int envRouting = 20;

// Fixed-length SQL type IDs (ms-tds §2.2.5.4.1)
const int typeNull = 0x1F;
const int typeInt1 = 0x30;
const int typeBit = 0x32;
const int typeInt2 = 0x34;
const int typeInt4 = 0x38;
const int typeDateTim4 = 0x3A;
const int typeFlt4 = 0x3B;
const int typeMoney = 0x3C;
const int typeDateTime = 0x3D;
const int typeFlt8 = 0x3E;
const int typeMoney4 = 0x7A;
const int typeInt8 = 0x7F;

// Variable-length SQL type IDs
const int typeGuid = 0x24;
const int typeIntN = 0x26;
const int typeDateN = 0x28;
const int typeTimeN = 0x29;
const int typeDateTime2N = 0x2A;
const int typeDateTimeOffsetN = 0x2B;
const int typeBitN = 0x68;
const int typeDecimalN = 0x6A;
const int typeNumericN = 0x6C;
const int typeFltN = 0x6D;
const int typeMoneyN = 0x6E;
const int typeDateTimeN = 0x6F;
const int typeBigVarBin = 0xA5;
const int typeBigVarChar = 0xA7;
const int typeBigBinary = 0xAD;
const int typeBigChar = 0xAF;
const int typeNVarChar = 0xE7;
const int typeNChar = 0xEF;
const int typeXml = 0xF1;
const int typeUdt = 0xF0;
const int typeTvp = 0xF3;
const int typeText = 0x23;
const int typeImage = 0x22;
const int typeNText = 0x63;
const int typeVariant = 0x62;

// PLP (Partially Length-Prefixed) sentinels
const int plpNull = 0xFFFFFFFFFFFFFFFF;
const int unknownPlpLen = 0xFFFFFFFFFFFFFFFE;
const int plpTerminator = 0x00000000;

// Default values
const int defaultPacketSize = 4096;
const int defaultPort = 1433;
const int headerSize = 8;
