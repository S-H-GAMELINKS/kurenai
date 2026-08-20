/* Hand-written stand-in for the extconf.h that mkmf generates for
 * ext/io/nonblock.
 *
 * WEBrick reaches for this in webrick/utils.rb, so it has to be linked in
 * alongside io/console and io/wait. It is a small extension -- IO#nonblock,
 * IO#nonblock=, IO#nonblock? -- and all three are fcntl F_GETFL/F_SETFL on
 * O_NONBLOCK, which is why the kernel's fcntl has to mean what it says.
 *
 * HAVE_RB_IO_DESCRIPTOR matters: without it nonblock.c defines its own
 * rb_io_descriptor as a static that reaches into the internals of struct
 * rb_io, which CRuby 4.0 has moved. */
#define HAVE_UNISTD_H 1
#define HAVE_RB_IO_DESCRIPTOR 1
