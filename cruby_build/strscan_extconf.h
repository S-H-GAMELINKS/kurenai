/* Hand-written stand-in for the extconf.h that mkmf generates for
 * ext/strscan.
 *
 * mui -- the editor this kernel runs from irb -- parses key notation like
 * "<C-w>" with StringScanner, so strscan is linked in for it.
 *
 * rb_reg_onig_match is how strscan matches without reaching into Onigmo's
 * internals, and CRuby 4 has it. onig_region_memsize is not defined anywhere
 * in this CRuby, so strscan reports its memory without it. */
#define HAVE_RB_REG_ONIG_MATCH 1
#define HAVE_RB_DEPRECATE_CONSTANT 1
