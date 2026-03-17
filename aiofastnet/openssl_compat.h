#ifndef AIOFASTNET_OPENSSL_COMPAT_H
#define AIOFASTNET_OPENSSL_COMPAT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Values copied from OpenSSL headers */
//#define SSL_ERROR_NONE 0
//#define SSL_ERROR_SSL 1
//#define SSL_ERROR_WANT_READ 2
//#define SSL_ERROR_WANT_WRITE 3
//#define SSL_ERROR_SYSCALL 5
//#define SSL_ERROR_ZERO_RETURN 6

/* Opaque OpenSSL types */
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;
typedef struct bio_st BIO;
typedef struct bio_method_st BIO_METHOD;
typedef struct ssl_cipher_st SSL_CIPHER;
typedef struct x509_st X509;
typedef struct X509_VERIFY_PARAM_st X509_VERIFY_PARAM;
typedef struct asn1_string_st ASN1_OCTET_STRING;

typedef int (*bio_write_fn)(BIO *, const char *, int);
typedef int (*bio_read_fn)(BIO *, char *, int);
typedef int (*bio_puts_fn)(BIO *, const char *);
typedef int (*bio_gets_fn)(BIO *, char *, int);
typedef long (*bio_ctrl_fn)(BIO *, int, long, void *);
typedef int (*bio_create_fn)(BIO *);
typedef int (*bio_destroy_fn)(BIO *);
typedef int (*err_print_errors_cb_fn)(const char *str, size_t len, void *u);

#define SSL_VERIFY_PEER 0x01
#define SSL_SENT_SHUTDOWN 1
#define SSL_RECEIVED_SHUTDOWN 2

#define SSL_MODE_ENABLE_PARTIAL_WRITE 0x00000001U
#define SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER 0x00000002U
#define SSL_MODE_AUTO_RETRY 0x00000004U
#define SSL_OP_ENABLE_KTLS ((uint64_t)1 << 3)

#define BIO_TYPE_SOURCE_SINK 0x0400
#define BIO_CTRL_RESET 1
#define BIO_CTRL_EOF 2
#define BIO_CTRL_INFO 3
#define BIO_CTRL_PENDING 10
#define BIO_CTRL_FLUSH 11
#define BIO_CTRL_DUP 12
#define BIO_CTRL_WPENDING 13
#define BIO_CTRL_GET_KTLS_SEND 73

#define BIO_C_SET_NBIO 102
#define BIO_C_FILE_SEEK 128
#define BIO_C_SET_BUF_MEM_EOF_RETURN 130
#define BIO_C_FILE_TELL 133

#define BIO_FLAGS_READ 0x01
#define BIO_FLAGS_WRITE 0x02
#define BIO_FLAGS_RWS 0x07
#define BIO_FLAGS_SHOULD_RETRY 0x08

int init_openssl_compat(const char *ssl_lib_path, const char *crypto_lib_path);
const char *openssl_compat_last_error(void);

/* Global function pointers */

extern BIO *(*aiofn_BIO_new)(const BIO_METHOD *type);
extern int (*aiofn_BIO_free)(BIO *a);
extern int (*aiofn_BIO_socket_nbio)(int fd, int mode);
extern long (*aiofn_BIO_ctrl)(BIO *bp, int cmd, long larg, void *parg);
extern void (*aiofn_BIO_set_flags)(BIO *b, int flags);
extern void (*aiofn_BIO_clear_flags)(BIO *b, int flags);
extern void (*aiofn_BIO_set_data)(BIO *a, void *ptr);
extern void *(*aiofn_BIO_get_data)(BIO *a);
extern void (*aiofn_BIO_set_init)(BIO *a, int init);
extern int (*aiofn_BIO_get_init)(BIO *a);
extern void (*aiofn_BIO_set_shutdown)(BIO *a, int shut);

extern BIO_METHOD *(*aiofn_BIO_meth_new)(int type, const char *name);
extern int (*aiofn_BIO_meth_set_write)(BIO_METHOD *biom, bio_write_fn write);
extern int (*aiofn_BIO_meth_set_read)(BIO_METHOD *biom, bio_read_fn read);
extern int (*aiofn_BIO_meth_set_puts)(BIO_METHOD *biom, bio_puts_fn puts);
extern int (*aiofn_BIO_meth_set_gets)(BIO_METHOD *biom, bio_gets_fn gets);
extern int (*aiofn_BIO_meth_set_ctrl)(BIO_METHOD *biom, bio_ctrl_fn ctrl);
extern int (*aiofn_BIO_meth_set_create)(BIO_METHOD *biom, bio_create_fn create);
extern int (*aiofn_BIO_meth_set_destroy)(BIO_METHOD *biom, bio_destroy_fn destroy);
extern void (*aiofn_BIO_meth_free)(BIO_METHOD *biom);

extern SSL *(*aiofn_SSL_new)(SSL_CTX *ctx);
extern void (*aiofn_SSL_free)(SSL *ssl);
extern void (*aiofn_SSL_set_bio)(SSL *ssl, BIO *rbio, BIO *wbio);
extern int (*aiofn_SSL_set_fd)(SSL *ssl, int fd);
extern BIO *(*aiofn_SSL_get_wbio)(const SSL *ssl);
extern void (*aiofn_SSL_set_accept_state)(SSL *ssl);
extern void (*aiofn_SSL_set_connect_state)(SSL *ssl);
extern uint64_t (*aiofn_SSL_set_options)(SSL *ssl, uint64_t options);
extern long (*aiofn_SSL_ctrl)(SSL *ssl, int cmd, long larg, void *parg);
long aiofn_SSL_set_mode(SSL *ssl, long mode);
int aiofn_SSL_set_tlsext_host_name(const SSL *s, const char *name);
extern int (*aiofn_SSL_get_error)(const SSL *ssl, int ret_code);
extern int (*aiofn_SSL_is_init_finished)(const SSL *s);
extern int (*aiofn_SSL_pending)(const SSL *ssl);
extern int (*aiofn_SSL_renegotiate)(SSL *ssl);
extern int (*aiofn_SSL_do_handshake)(SSL *ssl);
extern int (*aiofn_SSL_read_ex)(SSL *ssl, void *buf, size_t num, size_t *readbytes);
extern int (*aiofn_SSL_write_ex)(SSL *ssl, const void *buf, size_t num, size_t *written);
extern void *aiofn_SSL_sendfile;
extern int (*aiofn_SSL_shutdown)(SSL *ssl);
extern int (*aiofn_SSL_get_shutdown)(const SSL *ssl);
extern long (*aiofn_SSL_get_verify_result)(const SSL *ssl);
extern X509 *(*aiofn_SSL_get_peer_certificate)(const SSL *ssl);
extern void (*aiofn_SSL_get0_alpn_selected)(const SSL *ssl, const unsigned char **data,
                                            unsigned int *len);
extern void (*aiofn_SSL_set_read_ahead)(SSL *s, int yes);

extern const SSL_CIPHER *(*aiofn_SSL_get_current_cipher)(const SSL *ssl);
extern const char *(*aiofn_SSL_CIPHER_get_name)(const SSL_CIPHER *cipher);
extern const char *(*aiofn_SSL_CIPHER_get_version)(const SSL_CIPHER *cipher);
extern int (*aiofn_SSL_CIPHER_get_bits)(const SSL_CIPHER *cipher, int *alg_bits);

extern X509_VERIFY_PARAM *(*aiofn_SSL_get0_param)(SSL *ssl);
extern X509_VERIFY_PARAM *(*aiofn_SSL_CTX_get0_param)(SSL_CTX *ctx);
extern unsigned int (*aiofn_X509_VERIFY_PARAM_get_hostflags)(const X509_VERIFY_PARAM *param);
extern void (*aiofn_X509_VERIFY_PARAM_set_hostflags)(X509_VERIFY_PARAM *param, unsigned int flags);
extern int (*aiofn_X509_VERIFY_PARAM_set1_host)(X509_VERIFY_PARAM *param, const char *name, size_t namelen);
extern int (*aiofn_X509_VERIFY_PARAM_set1_ip)(X509_VERIFY_PARAM *param, const unsigned char *ip, size_t iplen);

extern const char *(*aiofn_X509_verify_cert_error_string)(long n);
extern void (*aiofn_X509_free)(X509 *a);
extern int (*aiofn_i2d_X509)(X509 *x, unsigned char **out);

extern unsigned long (*aiofn_ERR_peek_last_error)(void);
extern void (*aiofn_ERR_clear_error)(void);
extern const char *(*aiofn_ERR_lib_error_string)(unsigned long e);
extern const char *(*aiofn_ERR_reason_error_string)(unsigned long e);
extern void (*aiofn_ERR_print_errors_cb)(err_print_errors_cb_fn cb, void *u);

extern void (*aiofn_ASN1_OCTET_STRING_free)(ASN1_OCTET_STRING *a);
extern const unsigned char *(*aiofn_ASN1_STRING_get0_data)(const ASN1_OCTET_STRING *x);
extern int (*aiofn_ASN1_STRING_length)(ASN1_OCTET_STRING *x);
extern ASN1_OCTET_STRING *(*aiofn_a2i_IPADDRESS)(const char *ipasc);

/* Macro-based APIs */
int aiofn_BIO_pending(BIO *b);
long aiofn_BIO_get_mem_data(BIO *b, char **pp);
long aiofn_BIO_set_nbio(BIO *b, long n);
int aiofn_BIO_reset(BIO *b);
int aiofn_BIO_get_ktls_send(BIO *b);
int aiofn_SSL_sendfile_available(void);
int aiofn_ERR_GET_LIB(unsigned long e);

#define BIO_new aiofn_BIO_new
#define BIO_free aiofn_BIO_free
#define BIO_socket_nbio aiofn_BIO_socket_nbio
#define BIO_ctrl aiofn_BIO_ctrl
#define BIO_set_flags aiofn_BIO_set_flags
#define BIO_clear_flags aiofn_BIO_clear_flags
#define BIO_set_data aiofn_BIO_set_data
#define BIO_get_data aiofn_BIO_get_data
#define BIO_set_init aiofn_BIO_set_init
#define BIO_get_init aiofn_BIO_get_init
#define BIO_set_shutdown aiofn_BIO_set_shutdown
#define BIO_meth_new aiofn_BIO_meth_new
#define BIO_meth_set_write aiofn_BIO_meth_set_write
#define BIO_meth_set_read aiofn_BIO_meth_set_read
#define BIO_meth_set_puts aiofn_BIO_meth_set_puts
#define BIO_meth_set_gets aiofn_BIO_meth_set_gets
#define BIO_meth_set_ctrl aiofn_BIO_meth_set_ctrl
#define BIO_meth_set_create aiofn_BIO_meth_set_create
#define BIO_meth_set_destroy aiofn_BIO_meth_set_destroy
#define BIO_meth_free aiofn_BIO_meth_free
#define BIO_pending aiofn_BIO_pending
#define BIO_get_mem_data aiofn_BIO_get_mem_data
#define BIO_set_nbio aiofn_BIO_set_nbio
#define BIO_reset aiofn_BIO_reset
#define BIO_get_ktls_send aiofn_BIO_get_ktls_send
#define SSL_sendfile_available aiofn_SSL_sendfile_available

#define SSL_new aiofn_SSL_new
#define SSL_free aiofn_SSL_free
#define SSL_set_bio aiofn_SSL_set_bio
#define SSL_set_fd aiofn_SSL_set_fd
#define SSL_get_wbio aiofn_SSL_get_wbio
#define SSL_set_accept_state aiofn_SSL_set_accept_state
#define SSL_set_connect_state aiofn_SSL_set_connect_state
#define SSL_set_mode aiofn_SSL_set_mode
#define SSL_set_options aiofn_SSL_set_options
#define SSL_set_tlsext_host_name aiofn_SSL_set_tlsext_host_name
#define SSL_get_error aiofn_SSL_get_error
#define SSL_is_init_finished aiofn_SSL_is_init_finished
#define SSL_pending aiofn_SSL_pending
#define SSL_renegotiate aiofn_SSL_renegotiate
#define SSL_do_handshake aiofn_SSL_do_handshake
#define SSL_read_ex aiofn_SSL_read_ex
#define SSL_write_ex aiofn_SSL_write_ex
#define SSL_shutdown aiofn_SSL_shutdown
#define SSL_get_shutdown aiofn_SSL_get_shutdown
#define SSL_get_verify_result aiofn_SSL_get_verify_result
#define SSL_get_peer_certificate aiofn_SSL_get_peer_certificate
#define SSL_get0_alpn_selected aiofn_SSL_get0_alpn_selected
#define SSL_get_current_cipher aiofn_SSL_get_current_cipher
#define SSL_CIPHER_get_name aiofn_SSL_CIPHER_get_name
#define SSL_CIPHER_get_version aiofn_SSL_CIPHER_get_version
#define SSL_CIPHER_get_bits aiofn_SSL_CIPHER_get_bits
#define SSL_get0_param aiofn_SSL_get0_param
#define SSL_CTX_get0_param aiofn_SSL_CTX_get0_param
#define SSL_set_read_ahead aiofn_SSL_set_read_ahead

#define X509_VERIFY_PARAM_get_hostflags aiofn_X509_VERIFY_PARAM_get_hostflags
#define X509_VERIFY_PARAM_set_hostflags aiofn_X509_VERIFY_PARAM_set_hostflags
#define X509_VERIFY_PARAM_set1_host aiofn_X509_VERIFY_PARAM_set1_host
#define X509_VERIFY_PARAM_set1_ip aiofn_X509_VERIFY_PARAM_set1_ip
#define X509_verify_cert_error_string aiofn_X509_verify_cert_error_string
#define X509_free aiofn_X509_free
#define i2d_X509 aiofn_i2d_X509

#define ERR_peek_last_error aiofn_ERR_peek_last_error
#define ERR_clear_error aiofn_ERR_clear_error
#define ERR_lib_error_string aiofn_ERR_lib_error_string
#define ERR_reason_error_string aiofn_ERR_reason_error_string
#define ERR_print_errors_cb aiofn_ERR_print_errors_cb
#define ERR_GET_LIB aiofn_ERR_GET_LIB

#define ASN1_OCTET_STRING_free aiofn_ASN1_OCTET_STRING_free
#define ASN1_STRING_get0_data aiofn_ASN1_STRING_get0_data
#define ASN1_STRING_length aiofn_ASN1_STRING_length
#define a2i_IPADDRESS aiofn_a2i_IPADDRESS

#ifdef __cplusplus
}
#endif

#endif
