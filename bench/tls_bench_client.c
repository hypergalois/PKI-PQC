// bench/tls_bench_client.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netdb.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/provider.h>
#include <openssl/bio.h>
#include <openssl/x509.h>

static double elapsed_ms(const struct timespec *start,
                         const struct timespec *end) {
    long sec  = end->tv_sec  - start->tv_sec;
    long nsec = end->tv_nsec - start->tv_nsec;
    return (double)sec * 1000.0 + (double)nsec / 1e6;
}

static int connect_tcp(const char *host, const char *port) {
    struct addrinfo hints;
    struct addrinfo *res = NULL, *rp = NULL;
    int fd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int rc = getaddrinfo(host, port, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "getaddrinfo(%s,%s): %s\n",
                host, port, gai_strerror(rc));
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;

        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) {
            break;
        }

        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    return fd;
}

static void measure_chain(SSL *ssl, long *chain_len, long *chain_bytes) {
    *chain_len = 0;
    *chain_bytes = 0;

    /*
     * On the client side, SSL_get_peer_cert_chain() should expose the chain
     * sent by the server. We measure the DER size of each cert in that chain.
     */
    STACK_OF(X509) *chain = SSL_get_peer_cert_chain(ssl);
    if (chain != NULL) {
        int n = sk_X509_num(chain);
        *chain_len = n;

        for (int i = 0; i < n; i++) {
            X509 *cert = sk_X509_value(chain, i);
            if (cert != NULL) {
                int der_len = i2d_X509(cert, NULL);
                if (der_len > 0) {
                    *chain_bytes += der_len;
                }
            }
        }
    }

    /*
     * Defensive fallback: if the chain is unexpectedly unavailable, at least
     * record the peer leaf certificate.
     */
    if (*chain_len == 0) {
        X509 *leaf = SSL_get0_peer_certificate(ssl);
        if (leaf != NULL) {
            int der_len = i2d_X509(leaf, NULL);
            *chain_len = 1;
            if (der_len > 0) {
                *chain_bytes = der_len;
            }
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr,
                "Uso: %s host port groups cafile sni runs\n"
                "Ej:  %s localhost 4433 X25519 certs/ca_classic.crt classic.server 100\n",
                argv[0], argv[0]);
        return 1;
    }

    const char *host   = argv[1];
    const char *port   = argv[2];
    const char *groups = argv[3];
    const char *cafile = argv[4];
    const char *sni    = argv[5];
    int runs           = atoi(argv[6]);

    if (runs <= 0) {
        fprintf(stderr, "runs debe ser > 0\n");
        return 1;
    }

    SSL_load_error_strings();
    OpenSSL_add_ssl_algorithms();

    OSSL_PROVIDER *prov_default = OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER *prov_oqs     = OSSL_PROVIDER_load(NULL, "oqsprovider");
    if (!prov_default || !prov_oqs) {
        fprintf(stderr, "No se pudieron cargar los providers default/oqsprovider\n");
        ERR_print_errors_fp(stderr);
        return 1;
    }

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        fprintf(stderr, "SSL_CTX_new falló\n");
        ERR_print_errors_fp(stderr);
        OSSL_PROVIDER_unload(prov_default);
        OSSL_PROVIDER_unload(prov_oqs);
        return 1;
    }

    if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
        fprintf(stderr, "No se pudo fijar TLS 1.3\n");
        ERR_print_errors_fp(stderr);
        SSL_CTX_free(ctx);
        OSSL_PROVIDER_unload(prov_default);
        OSSL_PROVIDER_unload(prov_oqs);
        return 1;
    }

    if (!SSL_CTX_load_verify_locations(ctx, cafile, NULL)) {
        fprintf(stderr, "No se pudo cargar CAfile %s\n", cafile);
        ERR_print_errors_fp(stderr);
        SSL_CTX_free(ctx);
        OSSL_PROVIDER_unload(prov_default);
        OSSL_PROVIDER_unload(prov_oqs);
        return 1;
    }

    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

    if (!SSL_CTX_set1_groups_list(ctx, groups)) {
        fprintf(stderr, "No se pudo fijar groups=\"%s\"\n", groups);
        ERR_print_errors_fp(stderr);
        SSL_CTX_free(ctx);
        OSSL_PROVIDER_unload(prov_default);
        OSSL_PROVIDER_unload(prov_oqs);
        return 1;
    }

    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);

    printf("run_id,elapsed_ms,success,ssl_error,bytes_read,bytes_written,chain_len,chain_bytes\n");

    for (int i = 1; i <= runs; i++) {
        int fd = connect_tcp(host, port);
        if (fd < 0) {
            fprintf(stderr, "run %d: fallo conectando a %s:%s\n", i, host, port);
            printf("%d,0.0,0,-1,0,0,0,0\n", i);
            continue;
        }

        SSL *ssl = SSL_new(ctx);
        if (!ssl) {
            fprintf(stderr, "run %d: SSL_new falló\n", i);
            printf("%d,0.0,0,-1,0,0,0,0\n", i);
            close(fd);
            continue;
        }

        if (!SSL_set_tlsext_host_name(ssl, sni)) {
            fprintf(stderr, "run %d: no se pudo fijar SNI\n", i);
            ERR_print_errors_fp(stderr);
            printf("%d,0.0,0,-1,0,0,0,0\n", i);
            SSL_free(ssl);
            close(fd);
            continue;
        }

        if (!SSL_set_fd(ssl, fd)) {
            fprintf(stderr, "run %d: SSL_set_fd falló\n", i);
            ERR_print_errors_fp(stderr);
            printf("%d,0.0,0,-1,0,0,0,0\n", i);
            SSL_free(ssl);
            close(fd);
            continue;
        }

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
        int ret = SSL_connect(ssl);
        clock_gettime(CLOCK_MONOTONIC_RAW, &t1);

        double ms = elapsed_ms(&t0, &t1);
        int success = 0;
        int ssl_err = 0;
        long bytes_read = 0;
        long bytes_written = 0;
        long chain_len = 0;
        long chain_bytes = 0;

        if (ret == 1) {
            success = 1;
            measure_chain(ssl, &chain_len, &chain_bytes);
        } else {
            success = 0;
            ssl_err = SSL_get_error(ssl, ret);
        }

        BIO *rbio = SSL_get_rbio(ssl);
        BIO *wbio = SSL_get_wbio(ssl);
        if (rbio)
            bytes_read = BIO_number_read(rbio);
        if (wbio)
            bytes_written = BIO_number_written(wbio);

        printf("%d,%.3f,%d,%d,%ld,%ld,%ld,%ld\n",
               i, ms, success, ssl_err, bytes_read, bytes_written,
               chain_len, chain_bytes);

        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(fd);
    }

    SSL_CTX_free(ctx);
    OSSL_PROVIDER_unload(prov_default);
    OSSL_PROVIDER_unload(prov_oqs);
    EVP_cleanup();
    ERR_free_strings();

    return 0;
}
