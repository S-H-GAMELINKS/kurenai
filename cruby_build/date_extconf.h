/* Hand-written stand-in for the extconf.h that mkmf generates for ext/date.
 *
 * WEBrick needs date only because webrick/cookie.rb requires "time", and
 * lib/time.rb requires "date" before anything else. date_core.c opens with
 * #include RUBY_EXTCONF_H, so like ext/socket this has to be named by the
 * macro rather than passed with -include.
 *
 * rb_category_warn exists in CRuby 4; without this date_core.c defines a
 * fallback of its own. The timezone/altzone probes are left unanswered:
 * there is no zone database here, so local time is UTC and the code path
 * that reads those variables has nothing to read. */
#define HAVE_RB_CATEGORY_WARN 1
