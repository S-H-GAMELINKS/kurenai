/* Hand-written stand-in for the extconf.h that mkmf generates for ext/openssl.
 *
 * ossl.h opens with #include RUBY_EXTCONF_H, so like ext/socket and ext/date
 * this is named by the macro rather than passed with -include.
 *
 * Each line is a have_func in extconf.rb, answered for CRuby 4.0 and the
 * OpenSSL pinned in cmake/versions.cmake (3.5). Two are left out because the
 * answer is no: RAND_egd went in OpenSSL 1.1.0, and ASN1_BIT_STRING_set1 is
 * newer than 3.5 -- ossl_asn1.c has a fallback for it. The library checks
 * (have_library crypto, ssl) are answered by the kernel's link line. */

/* CRuby */
#define HAVE_RB_CALL_SUPER_KW 1
#define HAVE_RB_IO_DESCRIPTOR 1
#define HAVE_RB_IO_MAYBE_WAIT 1
#define HAVE_RB_IO_TIMEOUT 1

/* OpenSSL */
#define HAVE_OPENSSL_SSL_H 1
#define HAVE_SSL_CTX_SET1_SIGALGS_LIST 1
#define HAVE_SSL_CTX_SET1_CLIENT_SIGALGS_LIST 1
#define HAVE_EVP_PBE_SCRYPT 1
#define HAVE_EVP_PKEY_CHECK 1
#define HAVE_SSL_CTX_SET0_TMP_DH_PKEY 1
#define HAVE_ERR_GET_ERROR_ALL 1
#define HAVE_SSL_CTX_LOAD_VERIFY_FILE 1
#define HAVE_BN_CHECK_PRIME 1
#define HAVE_EVP_MD_CTX_GET0_MD 1
#define HAVE_EVP_MD_CTX_GET_PKEY_CTX 1
#define HAVE_EVP_PKEY_EQ 1
#define HAVE_EVP_PKEY_DUP 1
#define HAVE_SSL_GET0_GROUP_NAME 1
#define HAVE_TS_VERIFY_CTX_SET0_CERTS 1
#define HAVE_SSL_GET0_PEER_SIGNATURE_NAME 1
