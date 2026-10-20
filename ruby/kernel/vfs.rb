# The filesystem.
#
# Files start out compiled into the kernel image, and this serves them. A file
# is a node: an address, a size, and since files can now be written, a
# capacity, a modification time and an inode number. Reading copies straight
# from the address into the caller's buffer. Nothing is loaded into Ruby
# strings: the bytes belong to CRuby's world on one side and memory on the
# other, and the Ruby kernel only decides which range to move.
#
# A file from the image lives in read-only memory where the linker put it. The
# first time anything opens it for writing, it is copied into pages from
# Memory -- copy on write -- and from then on it is an ordinary writable file:
# it grows by moving to a larger run of pages, and its old pages go back on
# the free list. Files created at run time are like that from the start. All
# of it lives as long as the machine does; there is no disk behind it.
#
# Descriptors hold the node, not the path, so a file that moves to bigger pages
# moves for every descriptor open on it at once, and one that is unlinked while
# open stays readable until it is closed -- which is what Linux does, and what
# Tempfile relies on.
module Kernel
  module VFS
    PAGE = 4096

    # Built once at boot rather than on first use. A syscall handler is the
    # wrong place to discover that a table has to be constructed: the first
    # open would pay for it, and anything that went wrong would surface as an
    # errno rather than as a boot failure.
    TABLE = {}

    # Directories map to their inode number. Most are implied: a file at
    # /ripper/core.rb means /ripper exists. CRuby resolves a path component at a
    # time and asks about each one, so the directories have to answer. mkdir
    # adds the rest.
    DIRECTORIES = { "/" => 1 }

    def self.build
      Syscall.embedded_files.each do |path, address, size|
        TABLE[path] = node(address, size, 0, false)

        parts = path.split("/")
        parts.pop                       # drop the file itself
        prefix = ""
        parts.each do |part|
          next if part.empty?
          prefix = prefix + "/" + part
          DIRECTORIES[prefix] = next_ino unless DIRECTORIES[prefix]
        end
      end
      TABLE
    end

    # capacity is 0 for a file still in the image: it has no pages of its own.
    def self.node(address, size, capacity, writable)
      {
        address: address, size: size, capacity: capacity,
        writable: writable, mtime: writable ? Syscall.clock_millis : 0,
        ino: next_ino, opens: 0, unlinked: false
      }
    end

    def self.next_ino
      @ino = (@ino || 1) + 1
    end

    def self.directory?(path)
      return false if path.empty?

      !DIRECTORIES[normalize(path)].nil?
    end

    def self.directory_ino(path)
      DIRECTORIES[normalize(path)]
    end

    # CRuby builds paths by joining a load path entry with a file name, which
    # produces things like "//ripper.rb" when the entry is "/". Collapsing
    # repeated separators and resolving "." and ".." is the filesystem's job,
    # not the caller's.
    #
    # An empty path is not the root. It normalizes to "/" like everything else
    # made only of separators, so it has to be refused before it gets here:
    # File.exist?("") answering true sent irb looking for a history file it had
    # no name for.
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

    def self.parent(path)
      normalized = normalize(path)
      index = normalized.rindex("/")
      index == 0 ? "/" : normalized[0, index]
    end

    def self.exist?(path)
      return false if path.empty?

      !TABLE[normalize(path)].nil?
    end

    def self.lookup(path)
      return nil if path.empty?

      TABLE[normalize(path)]
    end

    def self.address(path)
      entry = lookup(path)
      entry && entry[:address]
    end

    def self.size(path)
      entry = lookup(path)
      entry && entry[:size]
    end

    def self.paths
      TABLE.keys
    end

    # ---------------------------------------------------------------- writing

    # A new, empty file. Only inside a directory that exists, as on any other
    # filesystem; nil otherwise.
    def self.create(path)
      return nil unless directory?(parent(path))

      TABLE[normalize(path)] = node(0, 0, 0, true)
    end

    # Gives a file from the image pages of its own, so it can be written. A
    # file already writable is left alone.
    def self.make_writable(file)
      return true if file[:writable]

      return false unless ensure_capacity(file, file[:size], true)
      file[:writable] = true
      true
    end

    # Makes room for size bytes, moving the contents to a larger run of pages
    # if they do not fit. Doubling keeps a file written a line at a time from
    # being copied once per line.
    def self.ensure_capacity(file, size, copying_image = false)
      return true if !copying_image && size <= file[:capacity]

      wanted = file[:capacity] * 2
      wanted = size if wanted < size
      wanted = PAGE if wanted < PAGE
      pages = Memory.allocate(wanted)
      return false if pages.nil?

      Syscall.copy_out(pages, file[:address], file[:size]) if file[:size] > 0
      release_pages(file)
      file[:address] = pages
      file[:capacity] = Memory.align(wanted)
      true
    end

    def self.release_pages(file)
      return if file[:capacity] == 0

      Memory.release(file[:address], file[:capacity])
      file[:capacity] = 0
    end

    # Copies count bytes from the caller's buffer into the file at offset.
    # Writing past the end leaves a hole that reads as zeros.
    def self.write(file, offset, buffer, count)
      finish = offset + count
      return nil unless make_writable(file)
      return nil unless ensure_capacity(file, finish)

      if offset > file[:size]
        Syscall.memzero(file[:address] + file[:size], offset - file[:size])
      end
      Syscall.copy_out(file[:address] + offset, buffer, count) if count > 0
      file[:size] = finish if finish > file[:size]
      touch(file)
      count
    end

    def self.truncate(file, size)
      return nil unless make_writable(file)
      return nil unless ensure_capacity(file, size)

      if size > file[:size]
        Syscall.memzero(file[:address] + file[:size], size - file[:size])
      end
      file[:size] = size
      touch(file)
      0
    end

    def self.touch(file)
      file[:mtime] = Syscall.clock_millis
    end

    # Removes the name. The contents go when the last descriptor on them
    # closes, which may be now.
    def self.unlink(path)
      file = TABLE.delete(normalize(path))
      return false if file.nil?

      file[:unlinked] = true
      release_pages(file) if file[:opens] == 0
      true
    end

    def self.closed(file)
      file[:opens] -= 1
      release_pages(file) if file[:unlinked] && file[:opens] == 0
    end

    def self.rename(from, to)
      file = TABLE.delete(normalize(from))
      return false if file.nil?

      unlink(to)
      TABLE[normalize(to)] = file
      true
    end

    def self.mkdir(path)
      DIRECTORIES[normalize(path)] = next_ino
    end

    def self.rmdir(path)
      DIRECTORIES.delete(normalize(path))
    end

    # The names directly inside a directory, as [name, ino, directory?],
    # sorted, without "." and "..". Worked out from the full paths each time a
    # directory is opened: there are a few hundred, and opening a directory is
    # rare.
    def self.children(path)
      prefix = normalize(path)
      prefix = "" if prefix == "/"
      found = {}

      TABLE.each do |name, file|
        rest = child_name(name, prefix)
        found[rest] = [rest, file[:ino], false] if rest
      end
      DIRECTORIES.each do |name, ino|
        rest = child_name(name, prefix)
        found[rest] = [rest, ino, true] if rest
      end
      found.values.sort { |a, b| a[0] <=> b[0] }
    end

    # "index.html" for "/www/index.html" under "/www"; nil if the path is not
    # directly inside it.
    def self.child_name(name, prefix)
      # Not start_with?: that is mruby-string-ext, which this VM leaves out.
      head = prefix + "/"
      return nil unless name[0, head.length] == head

      rest = name[head.length, name.length]
      return nil if rest.nil? || rest.empty? || rest.include?("/")
      rest
    end

    def self.empty_directory?(path)
      children(path).empty?
    end
  end
end
