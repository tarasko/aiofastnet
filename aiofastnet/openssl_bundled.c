/*
 * Bundled OpenSSL backend.
 *
 * This translation unit is compiled into aiofastnet ONLY when it is built with a
 * statically linked OpenSSL (setup.py with AIOFASTNET_BUNDLED_OPENSSL=1). Unlike
 * the borrow backend -- which dlopen()s the interpreter's libssl and resolves the
 * aiofn_* pointers at runtime (openssl_compat.c) -- here we bind every aiofn_*
 * pointer directly to the statically linked OpenSSL symbol.
 *
 * It is the only place that includes the real OpenSSL headers, so it defines
 * AIOFASTNET_USE_REAL_OPENSSL_HEADERS before including openssl_compat.h. That
 * suppresses the opaque-type shims and the function-rename macros, leaving the
 * real OpenSSL declarations and the extern aiofn_* pointer declarations visible.
 */

#define AIOFASTNET_USE_REAL_OPENSSL_HEADERS 1
#include "openssl_compat.h"

#include <string.h>

/* Assign a typed aiofn_* function pointer to a real OpenSSL symbol without
 * tripping function-pointer type-compatibility warnings (const-ness, STACK_OF
 * specializations, ossl_ssize_t, etc.). The ABIs are identical by construction. */
#define BIND(ptr, sym) do { *(void **)(&(ptr)) = (void *)(sym); } while (0)

/* Server-side ALPN: OpenSSL only stores a selection callback, so we keep a copy
 * of the wire-format protocol list and let SSL_select_next_proto do the matching.
 * One small allocation per server SSL_CTX; freed for the process lifetime only
 * (contexts are few and long-lived). */
typedef struct {
    unsigned char *protos;
    unsigned int protos_len;
} aiofn_alpn_list;

/* The server ALPN list is owned by the SSL_CTX via ex_data, so it is freed
 * automatically when the SSL_CTX is freed (including on cache rebuild). The
 * index is allocated once during init_openssl_compat_bundled(). */
static int g_alpn_ex_idx = -1;

static void aiofn_alpn_free(aiofn_alpn_list *list) {
    if (list == NULL) {
        return;
    }
    OPENSSL_free(list->protos);
    OPENSSL_free(list);
}

static void aiofn_alpn_ex_free_cb(void *parent, void *ptr, CRYPTO_EX_DATA *ad,
                                  int idx, long argl, void *argp) {
    (void)parent;
    (void)ad;
    (void)idx;
    (void)argl;
    (void)argp;
    aiofn_alpn_free((aiofn_alpn_list *)ptr);
}

static int aiofn_alpn_select_cb(SSL *ssl,
                                const unsigned char **out, unsigned char *outlen,
                                const unsigned char *in, unsigned int inlen,
                                void *arg) {
    aiofn_alpn_list *list = (aiofn_alpn_list *)arg;
    (void)ssl;

    if (list == NULL || list->protos == NULL) {
        return SSL_TLSEXT_ERR_NOACK;
    }

    if (SSL_select_next_proto((unsigned char **)out, outlen,
                              list->protos, list->protos_len,
                              in, inlen) != OPENSSL_NPN_NEGOTIATED) {
        return SSL_TLSEXT_ERR_NOACK;
    }
    return SSL_TLSEXT_ERR_OK;
}

int aiofn_bundled_set_server_alpn(SSL_CTX *ctx, const unsigned char *protos,
                                  unsigned int protos_len) {
    aiofn_alpn_list *list;

    if (g_alpn_ex_idx < 0) {
        return 0;
    }

    list = (aiofn_alpn_list *)OPENSSL_malloc(sizeof(*list));
    if (list == NULL) {
        return 0;
    }
    list->protos = (unsigned char *)OPENSSL_malloc(protos_len);
    if (list->protos == NULL) {
        OPENSSL_free(list);
        return 0;
    }
    memcpy(list->protos, protos, protos_len);
    list->protos_len = protos_len;

    /* Free any list previously attached to this ctx, then hand ownership to the
     * ctx so it is released by SSL_CTX_free via aiofn_alpn_ex_free_cb. */
    aiofn_alpn_free((aiofn_alpn_list *)SSL_CTX_get_ex_data(ctx, g_alpn_ex_idx));
    if (SSL_CTX_set_ex_data(ctx, g_alpn_ex_idx, list) != 1) {
        aiofn_alpn_free(list);
        return 0;
    }
    SSL_CTX_set_alpn_select_cb(ctx, aiofn_alpn_select_cb, list);
    return 1;
}

int aiofn_bundled_openssl_available(void) {
    return 1;
}

int init_openssl_compat_bundled(void) {
    if (OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS |
                         OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL) != 1) {
        return 0;
    }

    if (g_alpn_ex_idx < 0) {
        g_alpn_ex_idx = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL,
                                                 aiofn_alpn_ex_free_cb);
        if (g_alpn_ex_idx < 0) {
            return 0;
        }
    }

    BIND(aiofn_BIO_new, BIO_new);
    BIND(aiofn_BIO_free, BIO_free);
    BIND(aiofn_BIO_ctrl, BIO_ctrl);
    BIND(aiofn_BIO_set_flags, BIO_set_flags);
    BIND(aiofn_BIO_clear_flags, BIO_clear_flags);
    BIND(aiofn_BIO_set_data, BIO_set_data);
    BIND(aiofn_BIO_get_data, BIO_get_data);
    BIND(aiofn_BIO_set_init, BIO_set_init);
    BIND(aiofn_BIO_set_shutdown, BIO_set_shutdown);

    BIND(aiofn_BIO_meth_new, BIO_meth_new);
    BIND(aiofn_BIO_meth_set_write, BIO_meth_set_write);
    BIND(aiofn_BIO_meth_set_read, BIO_meth_set_read);
    BIND(aiofn_BIO_meth_set_puts, BIO_meth_set_puts);
    BIND(aiofn_BIO_meth_set_gets, BIO_meth_set_gets);
    BIND(aiofn_BIO_meth_set_ctrl, BIO_meth_set_ctrl);
    BIND(aiofn_BIO_meth_set_create, BIO_meth_set_create);
    BIND(aiofn_BIO_meth_set_destroy, BIO_meth_set_destroy);
    BIND(aiofn_BIO_meth_free, BIO_meth_free);

    BIND(aiofn_SSL_new, SSL_new);
    BIND(aiofn_SSL_free, SSL_free);
    BIND(aiofn_SSL_set_bio, SSL_set_bio);
    BIND(aiofn_SSL_set_fd, SSL_set_fd);
    BIND(aiofn_SSL_get_rbio, SSL_get_rbio);
    BIND(aiofn_SSL_get_wbio, SSL_get_wbio);
    BIND(aiofn_SSL_set_accept_state, SSL_set_accept_state);
    BIND(aiofn_SSL_set_connect_state, SSL_set_connect_state);
    BIND(aiofn_SSL_ctrl, SSL_ctrl);
    BIND(aiofn_SSL_clear_options, SSL_clear_options);
    BIND(aiofn_SSL_set_options_sym, SSL_set_options);
    BIND(aiofn_SSL_get_error, SSL_get_error);
    BIND(aiofn_SSL_pending, SSL_pending);
    BIND(aiofn_SSL_renegotiate, SSL_renegotiate);
    BIND(aiofn_SSL_do_handshake, SSL_do_handshake);
    BIND(aiofn_SSL_read, SSL_read);
    BIND(aiofn_SSL_write, SSL_write);
    BIND(aiofn_SSL_sendfile, SSL_sendfile);
    BIND(aiofn_SSL_shutdown, SSL_shutdown);
    BIND(aiofn_SSL_get_verify_result, SSL_get_verify_result);
    BIND(aiofn_SSL_get_version, SSL_get_version);
    BIND(aiofn_SSL_get_finished, SSL_get_finished);
    BIND(aiofn_SSL_get_peer_finished, SSL_get_peer_finished);
    BIND(aiofn_SSL_session_reused, SSL_session_reused);
    BIND(aiofn_SSL_get_peer_cert_chain, SSL_get_peer_cert_chain);
    BIND(aiofn_SSL_get0_verified_chain, SSL_get0_verified_chain);
    BIND(aiofn_SSL_get_ciphers, SSL_get_ciphers);
    BIND(aiofn_SSL_get_client_ciphers, SSL_get_client_ciphers);
    BIND(aiofn_SSL_get_peer_certificate, SSL_get1_peer_certificate);
    BIND(aiofn_SSL_get0_alpn_selected, SSL_get0_alpn_selected);
    BIND(aiofn_SSL_set_read_ahead, SSL_set_read_ahead);

    BIND(aiofn_SSL_get_current_cipher, SSL_get_current_cipher);
    BIND(aiofn_SSL_CIPHER_get_name, SSL_CIPHER_get_name);
    BIND(aiofn_SSL_CIPHER_get_version, SSL_CIPHER_get_version);
    BIND(aiofn_SSL_CIPHER_get_bits, SSL_CIPHER_get_bits);

    BIND(aiofn_SSL_get0_param, SSL_get0_param);
    BIND(aiofn_SSL_CTX_get0_param, SSL_CTX_get0_param);
    BIND(aiofn_X509_VERIFY_PARAM_get_hostflags, X509_VERIFY_PARAM_get_hostflags);
    BIND(aiofn_X509_VERIFY_PARAM_set_hostflags, X509_VERIFY_PARAM_set_hostflags);
    BIND(aiofn_X509_VERIFY_PARAM_set1_host, X509_VERIFY_PARAM_set1_host);
    BIND(aiofn_X509_VERIFY_PARAM_set1_ip, X509_VERIFY_PARAM_set1_ip);

    BIND(aiofn_X509_verify_cert_error_string, X509_verify_cert_error_string);
    BIND(aiofn_X509_free, X509_free);
    BIND(aiofn_i2d_X509, i2d_X509);
    BIND(aiofn_OPENSSL_sk_num, OPENSSL_sk_num);
    BIND(aiofn_OPENSSL_sk_value, OPENSSL_sk_value);

    BIND(aiofn_ERR_peek_last_error, ERR_peek_last_error);
    BIND(aiofn_ERR_clear_error, ERR_clear_error);
    BIND(aiofn_ERR_lib_error_string, ERR_lib_error_string);
    BIND(aiofn_ERR_reason_error_string, ERR_reason_error_string);
    BIND(aiofn_ERR_print_errors_cb, ERR_print_errors_cb);

    BIND(aiofn_ASN1_OCTET_STRING_free, ASN1_OCTET_STRING_free);
    BIND(aiofn_ASN1_STRING_get0_data, ASN1_STRING_get0_data);
    BIND(aiofn_ASN1_STRING_length, ASN1_STRING_length);
    BIND(aiofn_a2i_IPADDRESS, a2i_IPADDRESS);

    /* SSL_CTX builder symbols (used only by the bundled backend). */
    BIND(aiofn_SSL_CTX_new, SSL_CTX_new);
    BIND(aiofn_TLS_method, TLS_method);
    BIND(aiofn_SSL_CTX_free, SSL_CTX_free);
    BIND(aiofn_SSL_CTX_ctrl, SSL_CTX_ctrl);
    BIND(aiofn_SSL_CTX_set_verify, SSL_CTX_set_verify);
    BIND(aiofn_SSL_CTX_set_options, SSL_CTX_set_options);
    BIND(aiofn_SSL_CTX_get_cert_store, SSL_CTX_get_cert_store);
    BIND(aiofn_X509_STORE_add_cert, X509_STORE_add_cert);
    BIND(aiofn_d2i_X509, d2i_X509);
    BIND(aiofn_SSL_CTX_use_certificate_chain_file, SSL_CTX_use_certificate_chain_file);
    BIND(aiofn_SSL_CTX_use_PrivateKey_file, SSL_CTX_use_PrivateKey_file);
    BIND(aiofn_SSL_CTX_check_private_key, SSL_CTX_check_private_key);
    BIND(aiofn_SSL_CTX_set_cipher_list, SSL_CTX_set_cipher_list);
    BIND(aiofn_SSL_CTX_set_alpn_protos, SSL_CTX_set_alpn_protos);
    BIND(aiofn_SSL_CTX_load_verify_locations, SSL_CTX_load_verify_locations);
    BIND(aiofn_X509_VERIFY_PARAM_set_flags, X509_VERIFY_PARAM_set_flags);
    BIND(aiofn_SSL_CTX_get0_certificate, SSL_CTX_get0_certificate);

    return 1;
}
