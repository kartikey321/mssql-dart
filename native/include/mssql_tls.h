#ifndef MSSQL_TLS_H
#define MSSQL_TLS_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define MSSQL_TLS_EXPORT __declspec(dllexport)
#else
#define MSSQL_TLS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mssql_tls mssql_tls;

typedef enum mssql_tls_result {
  MSSQL_TLS_OK = 0,
  MSSQL_TLS_WANT_INPUT = 1,
  MSSQL_TLS_WANT_OUTPUT = 2,
  MSSQL_TLS_HANDSHAKE_COMPLETE = 3,
  MSSQL_TLS_PEER_CLOSED = 4,
  MSSQL_TLS_ERROR = -1,
  MSSQL_TLS_INVALID_ARGUMENT = -2,
  MSSQL_TLS_PACKET_TOO_LARGE = -3,
  MSSQL_TLS_INVALID_STATE = -4
} mssql_tls_result;

typedef struct mssql_tls_config {
  const char* server_name;
  const char* ca_file;
  const char* ca_path;
  int trust_server_certificate;
  int verify_hostname;
  size_t maximum_plaintext_packet;
} mssql_tls_config;

MSSQL_TLS_EXPORT mssql_tls* mssql_tls_create(const mssql_tls_config* config);
MSSQL_TLS_EXPORT void mssql_tls_destroy(mssql_tls* tls);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_handshake(mssql_tls* tls);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_feed_encrypted(
    mssql_tls* tls, const uint8_t* data, size_t length, size_t* consumed);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_drain_encrypted(
    mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_write_packet(
    mssql_tls* tls, const uint8_t* packet, size_t length);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_retry_write(mssql_tls* tls);
MSSQL_TLS_EXPORT int mssql_tls_has_pending_write(const mssql_tls* tls);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_read_plaintext(
    mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written);
MSSQL_TLS_EXPORT mssql_tls_result mssql_tls_peer_certificate_der(
    mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written);
MSSQL_TLS_EXPORT int mssql_tls_is_handshake_complete(const mssql_tls* tls);
MSSQL_TLS_EXPORT const char* mssql_tls_last_error(const mssql_tls* tls);
MSSQL_TLS_EXPORT const char* mssql_tls_openssl_version(void);

#ifdef __cplusplus
}
#endif
#endif
