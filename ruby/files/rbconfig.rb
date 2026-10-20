# RbConfig for Kurenai.
#
# configure normally generates this by inspecting the machine it builds on.
# That is the wrong machine: what matters is the one the code runs on, which is
# this kernel. So the answers are written out directly, and they describe a
# system with one directory, no executables to find and no extensions to build.
#
# reline and irb read host_os to decide whether they are on Windows. Everything
# else here exists because something asked for it.
module RbConfig
  TOPDIR = "/"

  CONFIG = {
    "host_os"            => "linux-musl",
    "target_os"          => "linux-musl",
    "arch"               => "x86_64-linux-musl",
    "host_cpu"           => "x86_64",
    "ruby_version"       => "4.0.0",
    "MAJOR"              => "4",
    "MINOR"              => "0",
    "TEENY"              => "0",
    "RUBY_INSTALL_NAME"  => "ruby",
    "ruby_install_name"  => "ruby",
    "RUBY_BASE_NAME"     => "ruby",
    "EXEEXT"             => "",
    "DLEXT"              => "so",
    "LIBRUBY_SO"         => "",
    "prefix"             => "/",
    "exec_prefix"        => "/",
    "bindir"             => "/",
    "libdir"             => "/",
    "rubylibdir"         => "/",
    "rubyarchdir"        => "/",
    "sitedir"            => "/",
    "sitelibdir"         => "/",
    "sitearchdir"        => "/",
    "vendordir"          => "/",
    "vendorlibdir"       => "/",
    "vendorarchdir"      => "/",
    "libdirname"         => "libdir",
    "PATH_SEPARATOR"     => ":",
    "ENABLE_SHARED"      => "no",
  }.freeze

  MAKEFILE_CONFIG = CONFIG.dup

  def self.ruby
    "/ruby"
  end

  def self.expand(value, config = CONFIG)
    value
  end
end
