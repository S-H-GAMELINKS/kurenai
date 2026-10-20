# NOTE:
# Every dependency is pinned by a full 40-hex SHA, never by a tag or branch.
# A tag can be moved; a SHA cannot. cmake/deps/fetch_sha.cmake also rejects
# anything shorter, because "git fetch" cannot resolve an abbreviated SHA
# ("fatal: couldn't find remote ref").

# Set musl libc version
# The upstream repository is https://git.musl-libc.org/git/musl, but a shallow
# clone from it takes ~30s. kraj/musl is a mirror of it and takes ~1.4s; both
# resolve v1.2.5 to the same SHA and produce an identical tree.
set(MUSL_URL     https://github.com/kraj/musl.git)
set(MUSL_REF     0784374d561435f7c787a555aeab8ede699ed298)  # v1.2.5

# Set CRuby version
set(CRUBY_URL    https://github.com/ruby/ruby.git)
set(CRUBY_REF    03b6d3f8898a28604fe6cb00eae3226b821168f4)  # v4.0.6

# Set lwIP version
# The same release PicoRuby's picoruby-socket pins, so the stack underneath the
# socket layer is the one that gem's lwIP glue was written against. Fetched here
# rather than by the gem's rake, which clones by tag at build time; everything
# in this project is pinned by SHA.
set(LWIP_URL     https://github.com/lwip-tcpip/lwip.git)
set(LWIP_REF     009c2256469004009488b3385ba269461e8eb616)  # STABLE-2_2_1_RELEASE

# Set WEBrick version
# Not a bundled gem since Ruby 3.0, so gems/bundled_gems has no line for it and
# it is fetched like any other repository. 1.9.2 is the tag; its SHA is the
# commit the annotated tag points at, not the tag object.
set(WEBRICK_URL  https://github.com/ruby/webrick.git)
set(WEBRICK_REF  b1684cecf9eb87cb2ae20fd52fbb80cf3e859c8a)  # v1.9.2

# Set mui version
# The editor run from irb to change the pages WEBrick serves -- a Vim-like
# editor written in Ruby, by this kernel's author. Pinned at the master that
# merged its ANSI terminal adapter, so it needs no curses to run.
set(MUI_URL      https://github.com/S-H-GAMELINKS/mui.git)
set(MUI_REF      f1168f2d0c49a7a7430ce0e5221a0cb41aba7dc8)  # master

# Set PicoRuby version
# There is no tag at this commit, which is why the SHA appears bare here.
set(PICORUBY_URL https://github.com/picoruby/picoruby.git)
set(PICORUBY_REF 906e37f1e13d32d31e954b8e62f549396d78a562)
