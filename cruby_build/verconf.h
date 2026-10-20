/* Hand-written for Kurenai; normally generated from template/verconf.h.in.
 *
 * Every path is empty on purpose. There is no filesystem layout to install
 * into, and the Ruby files the kernel needs are embedded in the image and
 * resolved through the VFS the PicoRuby side implements, not through these. */
#define RUBY_BASE_NAME          "ruby"
#define RUBY_VERSION_NAME       "ruby"
#define RUBY_LIB_VERSION_STYLE  3
#define RUBY_EXEC_PREFIX        ""
#define RUBY_LIB_PREFIX         ""
#define RUBY_ARCH_PREFIX_FOR(arch) ""
#define RUBY_SITEARCH_PREFIX_FOR(arch) ""
#define RUBY_LIB                ""
#define RUBY_SITE_LIB           ""
#define RUBY_VENDOR_LIB         ""
