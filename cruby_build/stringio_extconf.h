/* Hand-written stand-in for the extconf.h that mkmf generates for
 * ext/stringio.
 *
 * CRuby 4 defines rb_io_mode_t in ruby/io.h; without this the extension
 * defines its own as an int and the two collide. */
#define HAVE_TYPE_RB_IO_MODE_T 1
