# After the connection is lost, log warnings after this many write()s.
LOG_THRESHOLD_FOR_CONNLOST_WRITES = 5

# Seconds to wait before retrying accept().
ACCEPT_RETRY_DELAY = 1

SSL_TIMEOUT_DEFAULTS = {
    # Number of seconds to wait for SSL handshake to complete
    # The default timeout matches that of Nginx.
    "ssl_handshake_timeout": 60.0,
    # Number of seconds to wait for SSL shutdown to complete
    # The default timeout mimics lingering_time
    "ssl_shutdown_timeout": 30.0
}

SSL_BIO_SIZE_DEFAULTS = {
    # Static size for the incoming SSL BIO
    # This is the size of the buffer that we pass to the recv syscall
    # The bigger it is the more we can read from kernel RCVBUF with a single syscall
    # But it also increase the memory footprint per client
    "ssl_incoming_bio_size": int(4 * (16 * 1024 + 64)),

    # Static size for the outgoing SSL BIO
    # Indicates how much encrypted data is accumulated before we call syscall send
    # Make sure we can fit 4 full TLS records (including TLS header)
    "ssl_outgoing_bio_size": int(4 * (16 * 1024 + 64))
}

DATA_RECEIVED_MAX_SIZE = 256 * 1024

EXC_INFO_ATTR = '_aiofastnet_extra_info'
