# File descriptors.
#
# The table a process sees when it calls open and read. Descriptors 0, 1 and 2
# are the console and always exist; everything above them is a window onto a
# file in the VFS, with the offset kept here. A file descriptor holds the VFS
# node itself rather than its path, so it follows the file if it moves to new
# pages or loses its name.
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

    # O_NONBLOCK for the three console descriptors, which have no entry.
    CONSOLE_NONBLOCK = { CONSOLE_IN => false, CONSOLE_OUT => false, CONSOLE_ERR => false }

    O_WRONLY   = 0o1
    O_RDWR     = 0o2
    O_APPEND   = 0o2000
    O_NONBLOCK = 0o4000
    O_DIRECTORY = 0o200000

    def self.open_file(path, node, readable, writable, append)
      number = next_number
      return nil unless number

      node[:opens] += 1
      TABLE[number] = {
        path: VFS.normalize(path),
        node: node,
        offset: 0,
        readable: readable,
        writable: writable,
        append: append
      }
      number
    end

    # A directory, opened so its entries can be listed with getdents64. The
    # entries are taken when it is opened, as [name, ino, directory?], and
    # position counts how many have been handed out.
    def self.open_directory(path)
      number = next_number
      return nil unless number

      TABLE[number] = {
        path: VFS.normalize(path),
        directory: true,
        entries: VFS.children(path),
        position: 0
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

    # A socket, before it has anything to talk to. socket(2) creates the
    # descriptor; bind, listen and connect are separate calls that arrive
    # later, and lwIP's raw API separates them the same way -- a pcb is made,
    # then bound, then listened on or connected. So the handle stays nil until
    # there is one.
    #
    # A datagram socket's handle is kernel/net.c's own datagram queue rather
    # than picoruby-socket's, and peer is where a connected one sends.
    def self.open_socket(datagram = false)
      number = next_number
      return nil unless number

      TABLE[number] = {
        socket: true,
        datagram: datagram,
        handle: nil,      # picoruby-socket's pointer, once there is one
        listening: false,
        connecting: false, # a handshake has been started and not yet seen to end
        ip: 0,            # what bind was told
        port: 0,
        peer: nil,
        eof: false        # a read has already seen the connection end
      }
      number
    end

    # An accepted connection. It arrives already connected, which is why this
    # takes a handle where open_socket does not.
    def self.adopt_socket(handle)
      number = next_number
      return nil unless number

      TABLE[number] = {
        socket: true,
        datagram: false,
        handle: handle,
        listening: false,
        connecting: false,
        ip: 0,
        port: 0,
        eof: false
      }
      number
    end

    def self.socket?(number)
      entry = TABLE[number]
      !entry.nil? && entry[:socket] == true
    end

    def self.entry(number)
      TABLE[number]
    end

    def self.close(number)
      entry = TABLE[number]
      return false if entry.nil?

      if entry[:socket] && entry[:handle]
        if entry[:datagram]
          Net.udp_close(entry[:handle])
        elsif entry[:listening]
          Net.close_server(entry[:handle])
        else
          Net.close(entry[:handle])
        end
      end
      VFS.closed(entry[:node]) if entry[:node]
      !TABLE.delete(number).nil?
    end

    def self.console?(number)
      number >= CONSOLE_IN && number <= CONSOLE_ERR
    end

    def self.nonblocking?(number)
      return CONSOLE_NONBLOCK[number] if console?(number)

      entry = TABLE[number]
      !entry.nil? && entry[:nonblock] == true
    end

    # What F_GETFL reports.
    def self.status_flags(number)
      flags = nonblocking?(number) ? O_NONBLOCK : 0
      return flags | O_RDWR if console?(number)

      entry = TABLE[number]
      return flags | O_DIRECTORY if entry[:directory]
      return flags | O_RDWR unless entry[:node]

      flags |= O_APPEND if entry[:append]
      if entry[:readable] && entry[:writable] then flags | O_RDWR
      elsif entry[:writable] then flags | O_WRONLY
      else flags
      end
    end

    # F_SETFL: O_NONBLOCK and O_APPEND are the flags it may change.
    def self.set_status_flags(number, flags)
      nonblock = (flags & O_NONBLOCK) != 0
      if console?(number)
        CONSOLE_NONBLOCK[number] = nonblock
        return
      end

      entry = TABLE[number]
      entry[:nonblock] = nonblock
      entry[:append] = (flags & O_APPEND) != 0 if entry[:node]
    end

    # Copies from the file into the caller's buffer and advances the offset.
    # Returns the number of bytes moved; 0 means end of file. A pipe with
    # nothing in it reports :empty rather than 0, because 0 would mean the
    # writing end had closed.
    def self.read(number, buffer, count)
      file = TABLE[number]
      return nil unless file
      return read_socket(file, buffer, count) if file[:socket]
      return read_pipe(file, buffer, count) if file[:pipe]
      return :directory if file[:directory]
      return nil unless file[:readable]

      length = read_at(file, buffer, count, file[:offset])
      file[:offset] += length
      length
    end

    # pread: the same, at a given offset, leaving the descriptor's alone.
    def self.read_at(file, buffer, count, offset)
      node = file[:node]
      remaining = node[:size] - offset
      remaining = 0 if remaining < 0
      length = count < remaining ? count : remaining
      Syscall.copy_out(buffer, node[:address] + offset, length) if length > 0
      length
    end

    # Into the file, at the descriptor's offset or at the end for O_APPEND.
    # nil when the descriptor was not opened for writing, or memory ran out.
    def self.write_file(number, buffer, count)
      file = TABLE[number]
      return nil unless file && file[:node] && file[:writable]

      file[:offset] = file[:node][:size] if file[:append]
      written = VFS.write(file[:node], file[:offset], buffer, count)
      file[:offset] += written if written
      written
    end

    def self.file?(number)
      file = TABLE[number]
      !file.nil? && !file[:node].nil?
    end

    # Straight from lwIP's buffer into the caller's, in C. The bytes do not
    # become an mruby object on the way, which is the same rule the filesystem
    # follows and matters more here: a response body is larger than a path, and
    # the VM's pool is 8MB.
    #
    # :empty rather than 0 for "nothing yet", because 0 is end of file and a
    # connection that is merely quiet has not ended. Once it has, the entry
    # remembers -- lwIP forgets a closed pcb, and a second read has to give the
    # same answer as the first.
    #
    # A negative length is the port layer saying lwIP reported an error on the
    # connection, which in practice is the peer resetting it. That is :reset,
    # ECONNRESET, and not the nil a missing descriptor gets: EBADF told CRuby
    # its own descriptor was bad, and WEBrick logged a browser closing a tab as
    # an error in itself. As on Linux, the reset is reported once and every
    # read after it is end of file.
    def self.read_socket(file, buffer, count)
      return read_datagram(file, buffer, count) if file[:datagram]
      return 0 if file[:eof]
      return :empty if file[:handle].nil?

      Net.pump
      length = Net.recv(file[:handle], buffer, count)
      return :empty if length == Net::WOULD_BLOCK
      if length < 0
        file[:eof] = true
        return :reset
      end

      file[:eof] = true if length == 0
      length
    end

    # A partial write is allowed and is what happens with a large body: lwIP
    # takes what fits in its send buffer and the caller comes back for the rest,
    # which is exactly what write(2) promises and what CRuby's write loop
    # expects. Sending nothing is :full rather than 0, for the same reason a
    # quiet read is :empty.
    def self.write_socket(number, buffer, count)
      file = TABLE[number]
      return nil unless file && file[:socket]
      return write_datagram(file, buffer, count) if file[:datagram]
      return :full if file[:handle].nil?
      # A connection that failed or was reset cannot be written, ever; EAGAIN
      # would have the caller wait for room that is never coming. One the peer
      # has only finished sending on is still writable, as TCP allows.
      return :broken if Net.state(file[:handle]) == Sockets::STATE_ERROR

      room = Net.sendable(file[:handle])
      return :full if room == 0

      length = count < room ? count : room
      # Refused by lwIP, which means the connection is gone: EPIPE, for the
      # same reason a failed read is not EBADF.
      written = Net.send(file[:handle], buffer, length)
      return :broken if written < 0
      return :full if written == 0

      # Push it out now rather than at the next syscall. Waiting would leave a
      # complete response sitting in a queue until something else happened to
      # need the network.
      Net.pump
      written
    end

    # read and write on a connected datagram socket: one datagram each way,
    # to and from the peer connect named.
    def self.read_datagram(file, buffer, count)
      return :empty if file[:handle].nil?

      Net.pump
      length = Net.udp_recv(file[:handle], buffer, count)
      length == Net::WOULD_BLOCK ? :empty : length
    end

    def self.write_datagram(file, buffer, count)
      return nil unless file[:peer] && file[:handle]

      sent = Net.udp_sendto(file[:handle], buffer, count, file[:peer][0], file[:peer][1])
      return :broken if sent < 0

      Net.pump
      sent
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
      return nil if file.nil?

      # rewinddir is lseek to 0 on the directory's descriptor.
      if file[:directory] && whence == 0 && offset == 0
        file[:position] = 0
        return 0
      end
      return nil if file[:node].nil?

      position = case whence
                 when 0 then offset                 # SEEK_SET
                 when 1 then file[:offset] + offset # SEEK_CUR
                 when 2 then file[:node][:size] + offset   # SEEK_END
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
