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

    # Directories are not stored, they are implied: a file at /ripper/core.rb
    # means /ripper exists. CRuby resolves a path component at a time and asks
    # about each one, so the directories have to answer even though nothing
    # ever lists them.
    DIRECTORIES = { "/" => true }

    def self.build
      Syscall.embedded_files.each do |path, address, size|
        TABLE[path] = [address, size]

        parts = path.split("/")
        parts.pop                       # drop the file itself
        prefix = ""
        parts.each do |part|
          next if part.empty?
          prefix = prefix + "/" + part
          DIRECTORIES[prefix] = true
        end
      end
      TABLE
    end

    def self.directory?(path)
      DIRECTORIES[normalize(path)] == true
    end

    # CRuby builds paths by joining a load path entry with a file name, which
    # produces things like "//ripper.rb" when the entry is "/". Collapsing
    # repeated separators and resolving "." and ".." is the filesystem's job,
    # not the caller's.
    def self.normalize(path)
      parts = []
      path.split("/").each do |part|
        next if part.empty? || part == "."
        if part == ".."
          parts.pop
        else
          parts.push(part)
        end
      end
      "/" + parts.join("/")
    end

    def self.exist?(path)
      !TABLE[normalize(path)].nil?
    end

    def self.address(path)
      entry = TABLE[normalize(path)]
      entry && entry[0]
    end

    def self.size(path)
      entry = TABLE[normalize(path)]
      entry && entry[1]
    end

    def self.paths
      TABLE.keys
    end
  end
end
