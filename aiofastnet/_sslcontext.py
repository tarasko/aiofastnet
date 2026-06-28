import ssl


class SSLContext(ssl.SSLContext):
    """An ``ssl.SSLContext`` that records configuration which cannot be read back
    from a plain context.

    aiofastnet's *borrow* backend reuses the ``SSL_CTX`` that lives inside a
    Python ``ssl.SSLContext`` directly, so it needs no help. The *bundled*
    backend (a statically linked OpenSSL, used on Python distributions whose
    ``_ssl`` is statically linked -- e.g. uv's python-build-standalone) must
    build its *own* ``SSL_CTX`` and therefore has to reproduce the caller's
    configuration. Most settings are readable from a plain context
    (``verify_mode``, ``minimum_version``, CA certs via ``get_ca_certs`` ...),
    but loaded certificate chains, verify locations, ALPN protocols and cipher
    strings are not -- so they are recorded here for replay.

    Use this exactly like ``ssl.SSLContext``. On the borrow backend it behaves
    identically; only the bundled backend consumes the recorded calls.
    """

    def __init__(self, *args, **kwargs):
        # ssl.SSLContext fully initializes the underlying C object in __new__
        # (which receives the protocol); forwarding args to object.__init__ would
        # raise, so we only set up our own state here.
        # list of (method_name, args_tuple, kwargs_dict)
        self._aiofastnet_config = []

    def load_cert_chain(self, *args, **kwargs):
        result = super().load_cert_chain(*args, **kwargs)
        self._aiofastnet_config.append(("load_cert_chain", args, dict(kwargs)))
        return result

    def load_verify_locations(self, *args, **kwargs):
        result = super().load_verify_locations(*args, **kwargs)
        self._aiofastnet_config.append(
            ("load_verify_locations", args, dict(kwargs)))
        return result

    def set_alpn_protocols(self, protocols):
        result = super().set_alpn_protocols(protocols)
        self._aiofastnet_config.append(
            ("set_alpn_protocols", (list(protocols),), {}))
        return result

    def set_ciphers(self, cipherlist):
        result = super().set_ciphers(cipherlist)
        self._aiofastnet_config.append(("set_ciphers", (cipherlist,), {}))
        return result
