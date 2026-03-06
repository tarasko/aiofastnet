#include "openssl_compat.h"

#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

BIO *(*aiofn_BIO_new)(const BIO_METHOD *type) = NULL;
int (*aiofn_BIO_free)(BIO *a) = NULL;
long (*aiofn_BIO_ctrl)(BIO *bp, int cmd, long larg, void *parg) = NULL;
void (*aiofn_BIO_set_flags)(BIO *b, int flags) = NULL;
void (*aiofn_BIO_clear_flags)(BIO *b, int flags) = NULL;
void (*aiofn_BIO_set_data)(BIO *a, void *ptr) = NULL;
void *(*aiofn_BIO_get_data)(BIO *a) = NULL;
void (*aiofn_BIO_set_init)(BIO *a, int init) = NULL;
int (*aiofn_BIO_get_init)(BIO *a) = NULL;
void (*aiofn_BIO_set_shutdown)(BIO *a, int shut) = NULL;

BIO_METHOD *(*aiofn_BIO_meth_new)(int type, const char *name) = NULL;
int (*aiofn_BIO_meth_set_write)(BIO_METHOD *biom, bio_write_fn write) = NULL;
int (*aiofn_BIO_meth_set_read)(BIO_METHOD *biom, bio_read_fn read) = NULL;
int (*aiofn_BIO_meth_set_puts)(BIO_METHOD *biom, bio_puts_fn puts) = NULL;
int (*aiofn_BIO_meth_set_gets)(BIO_METHOD *biom, bio_gets_fn gets) = NULL;
int (*aiofn_BIO_meth_set_ctrl)(BIO_METHOD *biom, bio_ctrl_fn ctrl) = NULL;
int (*aiofn_BIO_meth_set_create)(BIO_METHOD *biom, bio_create_fn create) = NULL;
int (*aiofn_BIO_meth_set_destroy)(BIO_METHOD *biom, bio_destroy_fn destroy) = NULL;
void (*aiofn_BIO_meth_free)(BIO_METHOD *biom) = NULL;

SSL *(*aiofn_SSL_new)(SSL_CTX *ctx) = NULL;
void (*aiofn_SSL_free)(SSL *ssl) = NULL;
void (*aiofn_SSL_set_bio)(SSL *ssl, BIO *rbio, BIO *wbio) = NULL;
void (*aiofn_SSL_set_accept_state)(SSL *ssl) = NULL;
void (*aiofn_SSL_set_connect_state)(SSL *ssl) = NULL;
long (*aiofn_SSL_ctrl)(SSL *ssl, int cmd, long larg, void *parg) = NULL;
uint64_t (*aiofn_SSL_set_options)(SSL *ssl, uint64_t options) = NULL;
int (*aiofn_SSL_get_error)(const SSL *ssl, int ret_code) = NULL;
int (*aiofn_SSL_is_init_finished)(const SSL *s) = NULL;
int (*aiofn_SSL_pending)(const SSL *ssl) = NULL;
int (*aiofn_SSL_renegotiate)(SSL *ssl) = NULL;
int (*aiofn_SSL_do_handshake)(SSL *ssl) = NULL;
int (*aiofn_SSL_read_ex)(SSL *ssl, void *buf, size_t num, size_t *readbytes) = NULL;
int (*aiofn_SSL_write_ex)(SSL *ssl, const void *buf, size_t num, size_t *written) = NULL;
int (*aiofn_SSL_shutdown)(SSL *ssl) = NULL;
int (*aiofn_SSL_get_shutdown)(const SSL *ssl) = NULL;
long (*aiofn_SSL_get_verify_result)(const SSL *ssl) = NULL;
X509 *(*aiofn_SSL_get_peer_certificate)(const SSL *ssl) = NULL;

const SSL_CIPHER *(*aiofn_SSL_get_current_cipher)(const SSL *ssl) = NULL;
const char *(*aiofn_SSL_CIPHER_get_name)(const SSL_CIPHER *cipher) = NULL;
const char *(*aiofn_SSL_CIPHER_get_version)(const SSL_CIPHER *cipher) = NULL;
int (*aiofn_SSL_CIPHER_get_bits)(const SSL_CIPHER *cipher, int *alg_bits) = NULL;

X509_VERIFY_PARAM *(*aiofn_SSL_get0_param)(SSL *ssl) = NULL;
X509_VERIFY_PARAM *(*aiofn_SSL_CTX_get0_param)(SSL_CTX *ctx) = NULL;
unsigned int (*aiofn_X509_VERIFY_PARAM_get_hostflags)(const X509_VERIFY_PARAM *param) = NULL;
void (*aiofn_X509_VERIFY_PARAM_set_hostflags)(X509_VERIFY_PARAM *param, unsigned int flags) = NULL;
int (*aiofn_X509_VERIFY_PARAM_set1_host)(X509_VERIFY_PARAM *param, const char *name, size_t namelen) = NULL;
int (*aiofn_X509_VERIFY_PARAM_set1_ip)(X509_VERIFY_PARAM *param, const unsigned char *ip, size_t iplen) = NULL;

const char *(*aiofn_X509_verify_cert_error_string)(long n) = NULL;
void (*aiofn_X509_free)(X509 *a) = NULL;
int (*aiofn_i2d_X509)(X509 *x, unsigned char **out) = NULL;

unsigned long (*aiofn_ERR_peek_last_error)(void) = NULL;
void (*aiofn_ERR_clear_error)(void) = NULL;
const char *(*aiofn_ERR_lib_error_string)(unsigned long e) = NULL;
const char *(*aiofn_ERR_reason_error_string)(unsigned long e) = NULL;
void (*aiofn_ERR_print_errors_cb)(err_print_errors_cb_fn cb, void *u) = NULL;

void (*aiofn_ASN1_OCTET_STRING_free)(ASN1_OCTET_STRING *a) = NULL;
const unsigned char *(*aiofn_ASN1_STRING_get0_data)(const ASN1_OCTET_STRING *x) = NULL;
int (*aiofn_ASN1_STRING_length)(ASN1_OCTET_STRING *x) = NULL;
ASN1_OCTET_STRING *(*aiofn_a2i_IPADDRESS)(const char *ipasc) = NULL;

static int g_initialized = 0;
static const char *g_last_error = NULL;
static char g_last_error_buf[1024];

static void set_last_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_last_error_buf, sizeof(g_last_error_buf), fmt, ap);
    va_end(ap);
    g_last_error = g_last_error_buf;
    fprintf(stderr, "aiofastnet openssl_compat error: %s\n", g_last_error_buf);
}

#ifdef _WIN32
static HMODULE g_ssl_lib = NULL;
static HMODULE g_crypto_lib = NULL;

static void *resolve_symbol(const char *name) {
    void *p = NULL;
    if (g_ssl_lib != NULL) {
        p = (void *)GetProcAddress(g_ssl_lib, name);
        if (p != NULL) {
            return p;
        }
    }
    if (g_crypto_lib != NULL) {
        p = (void *)GetProcAddress(g_crypto_lib, name);
        if (p != NULL) {
            return p;
        }
    }
    return NULL;
}

static HMODULE open_library(const char *path) {
    HMODULE h = NULL;
    if (path == NULL || path[0] == '\0') {
        return NULL;
    }
    h = GetModuleHandleA(path);
    if (h != NULL) {
        return h;
    }
    return LoadLibraryA(path);
}

#else
static void *g_ssl_lib = NULL;
static void *g_crypto_lib = NULL;

static void *resolve_symbol(const char *name) {
    void *p = NULL;
    if (g_ssl_lib != NULL) {
        p = dlsym(g_ssl_lib, name);
        if (p != NULL) {
            return p;
        }
    }
    if (g_crypto_lib != NULL) {
        p = dlsym(g_crypto_lib, name);
        if (p != NULL) {
            return p;
        }
    }
    return NULL;
}
#endif

static void *resolve_required(const char *name) {
    void *p = resolve_symbol(name);
    return p;
}

#define LOAD_REQUIRED(fn, sym)                                                 \
    do {                                                                       \
        fn = resolve_required(sym);                                            \
        if (fn == NULL) {                                                      \
            set_last_error("missing symbol: %s", sym);                         \
            return 0;                                                          \
        }                                                                      \
    } while (0)

int init_openssl_compat(const char *ssl_lib_path, const char *crypto_lib_path) {
    if (g_initialized) {
        return 1;
    }
    g_last_error = NULL;
    g_last_error_buf[0] = '\0';

#ifdef _WIN32
    g_ssl_lib = open_library(ssl_lib_path);
    g_crypto_lib = open_library(crypto_lib_path);
    if (g_ssl_lib == NULL) {
        set_last_error("LoadLibrary failed for ssl: %s", ssl_lib_path ? ssl_lib_path : "(null)");
        return 0;
    }
    if (g_crypto_lib == NULL) {
        set_last_error("LoadLibrary failed for crypto: %s", crypto_lib_path ? crypto_lib_path : "(null)");
        return 0;
    }
#else
    const char *err;
    dlerror();
    g_ssl_lib = dlopen(ssl_lib_path, RTLD_NOLOAD | RTLD_NOW | RTLD_LOCAL);
    err = dlerror();
    if (g_ssl_lib == NULL) {
        set_last_error("dlopen ssl failed for '%s': %s",
                       ssl_lib_path ? ssl_lib_path : "(null)",
                       err ? err : "unknown");
        return 0;
    }
    dlerror();
    g_crypto_lib = dlopen(crypto_lib_path, RTLD_NOLOAD | RTLD_NOW | RTLD_LOCAL);
    err = dlerror();
    if (g_crypto_lib == NULL) {
        set_last_error("dlopen crypto failed for '%s': %s",
                       crypto_lib_path ? crypto_lib_path : "(null)",
                       err ? err : "unknown");
        return 0;
    }
#endif

    LOAD_REQUIRED(aiofn_BIO_new, "BIO_new");
    LOAD_REQUIRED(aiofn_BIO_free, "BIO_free");
    LOAD_REQUIRED(aiofn_BIO_ctrl, "BIO_ctrl");
    LOAD_REQUIRED(aiofn_BIO_set_flags, "BIO_set_flags");
    LOAD_REQUIRED(aiofn_BIO_clear_flags, "BIO_clear_flags");
    LOAD_REQUIRED(aiofn_BIO_set_data, "BIO_set_data");
    LOAD_REQUIRED(aiofn_BIO_get_data, "BIO_get_data");
    LOAD_REQUIRED(aiofn_BIO_set_init, "BIO_set_init");
    LOAD_REQUIRED(aiofn_BIO_get_init, "BIO_get_init");
    LOAD_REQUIRED(aiofn_BIO_set_shutdown, "BIO_set_shutdown");

    LOAD_REQUIRED(aiofn_BIO_meth_new, "BIO_meth_new");
    LOAD_REQUIRED(aiofn_BIO_meth_set_write, "BIO_meth_set_write");
    LOAD_REQUIRED(aiofn_BIO_meth_set_read, "BIO_meth_set_read");
    LOAD_REQUIRED(aiofn_BIO_meth_set_puts, "BIO_meth_set_puts");
    LOAD_REQUIRED(aiofn_BIO_meth_set_gets, "BIO_meth_set_gets");
    LOAD_REQUIRED(aiofn_BIO_meth_set_ctrl, "BIO_meth_set_ctrl");
    LOAD_REQUIRED(aiofn_BIO_meth_set_create, "BIO_meth_set_create");
    LOAD_REQUIRED(aiofn_BIO_meth_set_destroy, "BIO_meth_set_destroy");
    LOAD_REQUIRED(aiofn_BIO_meth_free, "BIO_meth_free");

    LOAD_REQUIRED(aiofn_SSL_new, "SSL_new");
    LOAD_REQUIRED(aiofn_SSL_free, "SSL_free");
    LOAD_REQUIRED(aiofn_SSL_set_bio, "SSL_set_bio");
    LOAD_REQUIRED(aiofn_SSL_set_accept_state, "SSL_set_accept_state");
    LOAD_REQUIRED(aiofn_SSL_set_connect_state, "SSL_set_connect_state");
    LOAD_REQUIRED(aiofn_SSL_ctrl, "SSL_ctrl");
    LOAD_REQUIRED(aiofn_SSL_set_options, "SSL_set_options");
    LOAD_REQUIRED(aiofn_SSL_get_error, "SSL_get_error");
    LOAD_REQUIRED(aiofn_SSL_is_init_finished, "SSL_is_init_finished");
    LOAD_REQUIRED(aiofn_SSL_pending, "SSL_pending");
    LOAD_REQUIRED(aiofn_SSL_renegotiate, "SSL_renegotiate");
    LOAD_REQUIRED(aiofn_SSL_do_handshake, "SSL_do_handshake");
    LOAD_REQUIRED(aiofn_SSL_read_ex, "SSL_read_ex");
    LOAD_REQUIRED(aiofn_SSL_write_ex, "SSL_write_ex");
    LOAD_REQUIRED(aiofn_SSL_shutdown, "SSL_shutdown");
    LOAD_REQUIRED(aiofn_SSL_get_shutdown, "SSL_get_shutdown");
    LOAD_REQUIRED(aiofn_SSL_get_verify_result, "SSL_get_verify_result");
    LOAD_REQUIRED(aiofn_SSL_get_current_cipher, "SSL_get_current_cipher");
    LOAD_REQUIRED(aiofn_SSL_CIPHER_get_name, "SSL_CIPHER_get_name");
    LOAD_REQUIRED(aiofn_SSL_CIPHER_get_version, "SSL_CIPHER_get_version");
    LOAD_REQUIRED(aiofn_SSL_CIPHER_get_bits, "SSL_CIPHER_get_bits");
    LOAD_REQUIRED(aiofn_SSL_get0_param, "SSL_get0_param");
    LOAD_REQUIRED(aiofn_SSL_CTX_get0_param, "SSL_CTX_get0_param");
    LOAD_REQUIRED(aiofn_X509_VERIFY_PARAM_get_hostflags, "X509_VERIFY_PARAM_get_hostflags");
    LOAD_REQUIRED(aiofn_X509_VERIFY_PARAM_set_hostflags, "X509_VERIFY_PARAM_set_hostflags");
    LOAD_REQUIRED(aiofn_X509_VERIFY_PARAM_set1_host, "X509_VERIFY_PARAM_set1_host");
    LOAD_REQUIRED(aiofn_X509_VERIFY_PARAM_set1_ip, "X509_VERIFY_PARAM_set1_ip");
    LOAD_REQUIRED(aiofn_X509_verify_cert_error_string, "X509_verify_cert_error_string");
    LOAD_REQUIRED(aiofn_X509_free, "X509_free");
    LOAD_REQUIRED(aiofn_i2d_X509, "i2d_X509");

    aiofn_SSL_get_peer_certificate = resolve_symbol("SSL_get1_peer_certificate");
    if (aiofn_SSL_get_peer_certificate == NULL) {
        aiofn_SSL_get_peer_certificate = resolve_symbol("SSL_get_peer_certificate");
    }
    if (aiofn_SSL_get_peer_certificate == NULL) {
        set_last_error("missing symbol: SSL_get1_peer_certificate/SSL_get_peer_certificate");
        return 0;
    }

    LOAD_REQUIRED(aiofn_ERR_peek_last_error, "ERR_peek_last_error");
    LOAD_REQUIRED(aiofn_ERR_clear_error, "ERR_clear_error");
    LOAD_REQUIRED(aiofn_ERR_lib_error_string, "ERR_lib_error_string");
    LOAD_REQUIRED(aiofn_ERR_reason_error_string, "ERR_reason_error_string");
    LOAD_REQUIRED(aiofn_ERR_print_errors_cb, "ERR_print_errors_cb");

    LOAD_REQUIRED(aiofn_ASN1_OCTET_STRING_free, "ASN1_OCTET_STRING_free");
    LOAD_REQUIRED(aiofn_ASN1_STRING_get0_data, "ASN1_STRING_get0_data");
    LOAD_REQUIRED(aiofn_ASN1_STRING_length, "ASN1_STRING_length");
    LOAD_REQUIRED(aiofn_a2i_IPADDRESS, "a2i_IPADDRESS");

    g_initialized = 1;
    return 1;
}

int aiofn_BIO_pending(BIO *b) {
    long n = aiofn_BIO_ctrl(b, BIO_CTRL_PENDING, 0, NULL);
    if (n < 0) {
        return -1;
    }
    return (int)n;
}

int aiofn_SSL_set_tlsext_host_name(const SSL *s, const char *name) {
    SSL *ssl = (SSL *)s;
    return (int)aiofn_SSL_ctrl(ssl, 55, 0, (void *)name);
}

long aiofn_SSL_set_mode(SSL *ssl, long mode) {
    return aiofn_SSL_ctrl(ssl, 33, mode, NULL);
}

long aiofn_BIO_get_mem_data(BIO *b, char **pp) {
    return aiofn_BIO_ctrl(b, BIO_CTRL_INFO, 0, pp);
}

long aiofn_BIO_set_nbio(BIO *b, long n) {
    return aiofn_BIO_ctrl(b, BIO_C_SET_NBIO, n, NULL);
}

int aiofn_BIO_reset(BIO *b) {
    return (int)aiofn_BIO_ctrl(b, BIO_CTRL_RESET, 0, NULL);
}

int aiofn_ERR_GET_LIB(unsigned long e) {
    return (int)((e >> 23) & 0xFFUL);
}

const char *openssl_compat_last_error(void) {
    return g_last_error;
}
