/* Encoding registration.
 *
 * CRuby normally loads enc/encdb.so at startup to find out which encodings
 * exist. There is no dynamic loading here, so the built-in ones are declared
 * directly. They are the same four the cross build compiles in; declaring an
 * encoding whose implementation is absent would fail later, at first use. */

void rb_encdb_declare(const char *name);
int  rb_encdb_alias(const char *alias, const char *orig);

void
Init_enc(void)
{
    rb_encdb_declare("ASCII-8BIT");
    rb_encdb_declare("US-ASCII");
    rb_encdb_declare("UTF-8");
    rb_encdb_alias("BINARY", "ASCII-8BIT");
    rb_encdb_alias("ASCII", "US-ASCII");
}
