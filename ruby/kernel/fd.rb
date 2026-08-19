# File descriptors.
#
# The table a process sees when it calls open and read. Descriptors 0, 1 and 2
# are the console and always exist; everything above them is a window onto a
# file in the VFS, with the read offset kept here.
#
# This is the part that makes "the kernel is written in Ruby" a statement about
# behaviour rather than about which language the boot messages were printed
# from: when CRuby reads a file, the descriptor it holds is an entry in this
# Hash.
module Kernel
  module FD
    CONSOLE_IN  = 0
    CONSOLE_OUT = 1
    CONSOLE_ERR = 2
    FIRST_FILE  = 3
    LIMIT       = 64

    # Held in a constant rather than an instance variable on the module. The
    # table has to survive across syscalls, and a constant is unambiguously
    # rooted for the life of the VM.
    TABLE = {}

    def self.open_file(path)
      address = VFS.address(path)
      return nil unless address

      number = next_number
      return nil unless number

      TABLE[number] = {
        path: VFS.normalize(path),
        address: address,
        size: VFS.size(path),
        offset: 0
      }
      number
    end

    # CRuby will not finish starting without a pipe: it builds one so a signal
    # handler can wake the main loop, and treats failure to create it as fatal
    # even though no signal will ever arrive here. Both ends share one buffer.
    def self.open_pipe
      read_end = next_number
      return nil unless read_end
      TABLE[read_end] = { pipe: true, writable: false, buffer: nil }

      write_end = next_number
      unless write_end
        TABLE.delete(read_end)
        return nil
      end
      TABLE[write_end] = { pipe: true, writable: true, buffer: nil }

      shared = []
      TABLE[read_end][:buffer] = shared
      TABLE[write_end][:buffer] = shared
      [read_end, write_end]
    end

    def self.entry(number)
      TABLE[number]
    end

    def self.close(number)
      !TABLE.delete(number).nil?
    end

    def self.console?(number)
      number >= CONSOLE_IN && number <= CONSOLE_ERR
    end

    # Copies from the file into the caller's buffer and advances the offset.
    # Returns the number of bytes moved; 0 means end of file. A pipe with
    # nothing in it reports :empty rather than 0, because 0 would mean the
    # writing end had closed.
    def self.read(number, buffer, count)
      file = TABLE[number]
      return nil unless file
      return read_pipe(file, buffer, count) if file[:pipe]

      remaining = file[:size] - file[:offset]
      remaining = 0 if remaining < 0
      length = count < remaining ? count : remaining
      Syscall.copy_out(buffer, file[:address] + file[:offset], length) if length > 0
      file[:offset] += length
      length
    end

    def self.read_pipe(file, buffer, count)
      return :empty if file[:buffer].empty?

      taken = file[:buffer].shift(count)
      Syscall.write_bytes(buffer, taken)
      taken.length
    end

    # Writing to a pipe keeps the bytes so a reader could find them. Nothing
    # writes to the one CRuby creates, but a pipe that discards is not a pipe.
    def self.write_pipe(number, buffer, count)
      file = TABLE[number]
      return nil unless file && file[:pipe] && file[:writable]

      file[:buffer].concat(Syscall.read_bytes(buffer, count))
      count
    end

    def self.pipe?(number)
      file = TABLE[number]
      !file.nil? && file[:pipe] == true
    end

    def self.seek(number, offset, whence)
      file = TABLE[number]
      return nil if file.nil? || file[:pipe]

      position = case whence
                 when 0 then offset                 # SEEK_SET
                 when 1 then file[:offset] + offset # SEEK_CUR
                 when 2 then file[:size] + offset   # SEEK_END
                 else return nil
                 end
      return nil if position < 0

      file[:offset] = position
      position
    end

    def self.next_number
      number = FIRST_FILE
      while number < LIMIT
        return number unless TABLE.key?(number)
        number += 1
      end
      nil
    end
  end
end
