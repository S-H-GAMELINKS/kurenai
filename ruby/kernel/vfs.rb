# The filesystem, such as it is.
#
# Files are compiled into the kernel image; this serves them. There is no
# hierarchy, no writing and no metadata beyond a size, because nothing needs
# any of that yet and inventing it would be pretending to be a filesystem
# rather than being one.
#
# Contents stay where the linker put them, in read-only memory. A file is an
# address and a length, and reading it copies straight from there into the
# caller's buffer. Nothing is loaded into Ruby strings: the bytes belong to
# CRuby's world on one side and the image on the other, and the Ruby kernel
# only decides which range to move.
module Kernel
  module VFS
    # Built once at boot rather than on first use. A syscall handler is the
    # wrong place to discover that a table has to be constructed: the first
    # open would pay for it, and anything that went wrong would surface as an
    # errno rather than as a boot failure.
    TABLE = {}

    def self.build
      Syscall.embedded_files.each do |path, address, size|
        TABLE[path] = [address, size]
      end
      TABLE
    end

    def self.exist?(path)
      !TABLE[path].nil?
    end

    def self.address(path)
      entry = TABLE[path]
      entry && entry[0]
    end

    def self.size(path)
      entry = TABLE[path]
      entry && entry[1]
    end

    def self.paths
      TABLE.keys
    end
  end
end
