#include "mssql_tls.h"

#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

SSL_CTX* make_server_context() {
  SSL_CTX* context = SSL_CTX_new(TLS_server_method());
  assert(context != nullptr);
  EVP_PKEY_CTX* key_context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
  assert(key_context != nullptr);
  assert(EVP_PKEY_keygen_init(key_context) == 1);
  assert(EVP_PKEY_CTX_set_rsa_keygen_bits(key_context, 2048) == 1);
  EVP_PKEY* key = nullptr;
  assert(EVP_PKEY_keygen(key_context, &key) == 1);
  EVP_PKEY_CTX_free(key_context);

  X509* certificate = X509_new();
  assert(certificate != nullptr);
  assert(X509_set_version(certificate, 2) == 1);
  assert(ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) == 1);
  assert(X509_gmtime_adj(X509_get_notBefore(certificate), 0) != nullptr);
  assert(X509_gmtime_adj(X509_get_notAfter(certificate), 86400) != nullptr);
  assert(X509_set_pubkey(certificate, key) == 1);
  X509_NAME* name = X509_get_subject_name(certificate);
  assert(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
      reinterpret_cast<const unsigned char*>("localhost"), -1, -1, 0) == 1);
  assert(X509_set_issuer_name(certificate, name) == 1);
  assert(X509_sign(certificate, key, EVP_sha256()) > 0);
  assert(SSL_CTX_use_certificate(context, certificate) == 1);
  assert(SSL_CTX_use_PrivateKey(context, key) == 1);
  X509_free(certificate);
  EVP_PKEY_free(key);
  return context;
}

void transfer_client_output(mssql_tls* client, SSL* server) {
  uint8_t bytes[16384];
  size_t written = 0;
  do {
    assert(mssql_tls_drain_encrypted(client, bytes, sizeof(bytes), &written) ==
           MSSQL_TLS_OK);
    if (written != 0) assert(BIO_write(SSL_get_rbio(server), bytes, static_cast<int>(written)) > 0);
  } while (written != 0);
}

void transfer_server_output(SSL* server, mssql_tls* client) {
  uint8_t bytes[16384];
  int read = 0;
  while ((read = BIO_read(SSL_get_wbio(server), bytes, sizeof(bytes))) > 0) {
    size_t consumed = 0;
    assert(mssql_tls_feed_encrypted(client, bytes, static_cast<size_t>(read), &consumed) ==
           MSSQL_TLS_OK);
    assert(consumed == static_cast<size_t>(read));
  }
}

}  // namespace

int main() {
  const mssql_tls_config config = {"localhost", nullptr, nullptr, 1, 0, 16383};
  mssql_tls* client = mssql_tls_create(&config);
  assert(client != nullptr);
  const std::vector<uint8_t> packet(8, 0);
  assert(mssql_tls_write_packet(client, packet.data(), packet.size()) == MSSQL_TLS_INVALID_STATE);
  assert(mssql_tls_retry_write(client) == MSSQL_TLS_INVALID_STATE);
  assert(mssql_tls_has_pending_write(client) == 0);

  SSL_CTX* server_context = make_server_context();
  SSL* server = SSL_new(server_context);
  assert(server != nullptr);
  SSL_set_bio(server, BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem()));
  SSL_set_accept_state(server);

  // Complete a full in-memory TLS handshake, exercising the same BIO pumping
  // used by the Dart TDS PRELOGIN bridge.
  for (int i = 0; i < 100 && !mssql_tls_is_handshake_complete(client); ++i) {
    const mssql_tls_result result = mssql_tls_handshake(client);
    assert(result == MSSQL_TLS_WANT_INPUT || result == MSSQL_TLS_WANT_OUTPUT ||
           result == MSSQL_TLS_HANDSHAKE_COMPLETE);
    transfer_client_output(client, server);
    const int server_result = SSL_do_handshake(server);
    assert(server_result == 1 || SSL_get_error(server, server_result) == SSL_ERROR_WANT_READ);
    transfer_server_output(server, client);
  }
  assert(mssql_tls_is_handshake_complete(client) != 0);
  assert(SSL_is_init_finished(server));

  size_t certificate_size = 0;
  assert(mssql_tls_peer_certificate_der(client, nullptr, 0, &certificate_size) ==
         MSSQL_TLS_PACKET_TOO_LARGE);
  std::vector<uint8_t> certificate(certificate_size);
  assert(mssql_tls_peer_certificate_der(client, certificate.data(), certificate.size(), &certificate_size) ==
         MSSQL_TLS_OK);
  assert(certificate_size == certificate.size());

  const uint8_t request[] = {0x12, 0x34, 0x56};
  assert(mssql_tls_write_packet(client, request, sizeof(request)) == MSSQL_TLS_OK);
  assert(mssql_tls_has_pending_write(client) == 0);
  transfer_client_output(client, server);
  uint8_t received[sizeof(request)] = {};
  size_t received_size = 0;
  assert(SSL_read_ex(server, received, sizeof(received), &received_size) == 1);
  assert(received_size == sizeof(request));
  assert(std::memcmp(received, request, sizeof(request)) == 0);

  const uint8_t response[] = {0xaa, 0xbb};
  size_t response_size = 0;
  assert(SSL_write_ex(server, response, sizeof(response), &response_size) == 1);
  transfer_server_output(server, client);
  uint8_t plaintext[sizeof(response)] = {};
  size_t plaintext_size = 0;
  assert(mssql_tls_read_plaintext(client, plaintext, sizeof(plaintext), &plaintext_size) == MSSQL_TLS_OK);
  assert(plaintext_size == sizeof(response));
  assert(std::memcmp(plaintext, response, sizeof(response)) == 0);

  mssql_tls_destroy(client);
  SSL_free(server);
  SSL_CTX_free(server_context);
  return 0;
}
