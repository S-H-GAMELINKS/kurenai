# The kernel's syscall policy, written in Ruby.
#
# CRuby runs as userland. Its libc is patched so that every syscall becomes a
# call into the kernel, and the kernel forwards the ones listed in the routing
# table to this method. So Kernel::Syscall.dispatch is not a model of a syscall
# handler; while CRuby writes to the console or reads a file, this is what runs.
#
# Buffers arrive as plain integers: addresses in CRuby's part of the one flat
# address space this system has. They are never copied into Ruby strings. Two
# garbage collectors are running here, and neither may see the other's objects;
# passing an address and letting a C primitive move the bytes is what keeps
# that boundary intact.
module Kernel
  module Syscall
    # Linux x86_64 syscall numbers.
    NR_READ      = 0
    NR_WRITE     = 1
    NR_OPEN      = 2
    NR_CLOSE     = 3
    NR_STAT      = 4
    NR_FSTAT     = 5
    NR_LSTAT     = 6
    NR_NEWFSTATAT = 262
    NR_IOCTL      = 16
    NR_POLL       = 7
    NR_PPOLL      = 271
    NR_GETCWD     = 79
    NR_ACCESS     = 21
    NR_FACCESSAT  = 269
    NR_FACCESSAT2 = 439
    NR_LSEEK     = 8
    NR_MMAP      = 9
    NR_MUNMAP    = 11
    NR_PIPE      = 22
    NR_WRITEV    = 20
    NR_PIPE2     = 293
    NR_OPENAT    = 257
    NR_SELECT     = 23
    NR_PSELECT6   = 270
    NR_SOCKET     = 41
    NR_SHUTDOWN   = 48
    NR_BIND       = 49
    NR_LISTEN     = 50
    NR_GETSOCKNAME = 51
    NR_GETPEERNAME = 52
    NR_SETSOCKOPT = 54
    NR_GETSOCKOPT = 55
    NR_ACCEPT4    = 288

    # Not an errno: never returned to CRuby. kernel/bridge.c sees it, waits for
    # the next tick outside the VM, and makes the same call again. The value is
    # Linux's ERESTARTSYS, which is kernel-internal there for the same reason.
    WAIT_AGAIN = -512

    EBADF  = -9
    EAGAIN = -11
    EPIPE  = -32
    ECONNRESET = -104
    ENFILE = -23
    ENOENT = -2
    EFAULT = -14
    ENOSYS = -38
    EMFILE = -24

    # struct iovec is { void *base; size_t len; } on x86_64.
    IOVEC_SIZE = 16

    # Field offsets in struct stat on x86_64. Only the two fields anyone looks
    # at are filled; the rest stays zero, which is a truthful description of a
    # file that has no owner, no times and no device.
    STAT_SIZE       = 144
    STAT_MODE       = 24    # st_mode, 4 bytes, followed by st_uid
    STAT_ST_SIZE    = 48
    STAT_BLKSIZE    = 56

    S_IFREG  = 0o100000
    S_IFDIR  = 0o040000
    S_IFCHR  = 0o020000
    S_IFIFO  = 0o010000
    S_IFSOCK = 0o140000

    # Always returns an Integer: negative is -errno, as the caller expects.
    # Never nil, and never an exception -- there is nobody above to catch one.
    def self.dispatch(number, a1, a2, a3, a4, a5, a6)
      case number
      when NR_WRITE  then sys_write(a1, a2, a3)
      when NR_WRITEV then sys_writev(a1, a2, a3)
      when NR_READ   then sys_read(a1, a2, a3)
      when NR_OPEN   then sys_open(a1)
      when NR_OPENAT then sys_open(a2)      # relative paths are not supported
      when NR_CLOSE  then sys_close(a1)
      when NR_FSTAT  then sys_fstat(a1, a2)
      when NR_STAT, NR_LSTAT then sys_stat(a1, a2)
      when NR_NEWFSTATAT     then sys_stat(a2, a3)
      when NR_IOCTL          then sys_ioctl(a1, a2, a3)
      when NR_POLL           then sys_poll(a1, a2, a3)
      when NR_PPOLL          then sys_ppoll(a1, a2, a3)
      when NR_GETCWD         then sys_getcwd(a1, a2)
      when NR_ACCESS         then sys_access(a1)
      when NR_FACCESSAT, NR_FACCESSAT2 then sys_access(a2)
      when NR_LSEEK  then sys_lseek(a1, a2, a3)
      when NR_PIPE, NR_PIPE2 then sys_pipe(a1)
      when NR_MMAP   then sys_mmap(a2, a5, a6)
      when NR_MUNMAP then sys_munmap(a1, a2)
      when NR_SELECT   then sys_select(a1, a2, a3, a4, a5)
      when NR_PSELECT6 then sys_pselect6(a1, a2, a3, a4, a5)
      when NR_SOCKET       then Sockets.sys_socket(a1, a2, a3)
      when NR_BIND         then Sockets.sys_bind(a1, a2, a3)
      when NR_LISTEN       then Sockets.sys_listen(a1, a2)
      when NR_ACCEPT4      then Sockets.sys_accept4(a1, a2, a3, a4)
      when NR_GETSOCKNAME  then Sockets.sys_getsockname(a1, a2, a3)
      when NR_GETPEERNAME  then Sockets.sys_getpeername(a1, a2, a3)
      when NR_SETSOCKOPT   then Sockets.sys_setsockopt(a1, a2, a3, a4, a5)
      when NR_GETSOCKOPT   then Sockets.sys_getsockopt(a1, a2, a3, a4, a5)
      when NR_SHUTDOWN     then Sockets.sys_shutdown(a1, a2)
      else ENOSYS
      end
    end

    # ---------------------------------------------------------------- console

    # fd 1 and 2 are the console. The buffer stays where it is; serial_write is
    # a C primitive registered on this module and reads it in place.
    def self.sys_write(fd, buffer, count)
      if fd == FD::CONSOLE_OUT || fd == FD::CONSOLE_ERR
        serial_write(buffer, count)
        return count(count)
      end

      if FD.socket?(fd)
        written = FD.write_socket(fd, buffer, count)
        return EBADF if written.nil?
        return EAGAIN if written == :full
        return EPIPE if written == :broken
        return written
      end

      written = FD.write_pipe(fd, buffer, count)
      written.nil? ? EBADF : written
    end

    # musl's stdio flushes through writev, not write, so this is the one that
    # actually carries CRuby's output. The iovec array is walked here, in Ruby,
    # reading CRuby's memory a field at a time.
    # The iovec array is walked here, in Ruby, reading CRuby's memory a field at
    # a time.
    #
    # Every entry goes through sys_write, which is what lets a socket be written
    # this way -- and it has to be, because CRuby has HAVE_WRITEV and buffered
    # writes come through here rather than through write. Walking stops at the
    # first short or refused entry and reports what did go, which is what
    # writev(2) promises; carrying on would put the tail of a response ahead of
    # the part that has not been sent.
    def self.sys_writev(fd, iov, iovcnt)
      total = 0
      i = 0
      while i < iovcnt
        entry = iov + i * IOVEC_SIZE
        base = peek64(entry)
        len = peek64(entry + 8)
        if len > 0
          written = sys_write(fd, base, len)
          return written if written < 0 && total == 0
          break if written < 0
          total += written
          break if written < len
        end
        i += 1
      end
      total
    end

    # ---------------------------------------------------------------- files

    def self.sys_read(fd, buffer, count)
      return read_console(buffer, count) if fd == FD::CONSOLE_IN

      length = FD.read(fd, buffer, count)
      return EBADF if length.nil?
      return EAGAIN if length == :empty
      return ECONNRESET if length == :reset

      length
    end

    # The line discipline, and the reason it belongs in Ruby.
    #
    # In canonical mode a read waits for a line, Return arrives as carriage
    # return and has to become line feed, and the kernel echoes so that typing
    # is visible. In raw mode a line editor has taken over: it draws the line
    # itself, so nothing is echoed and nothing is translated, and a read
    # returns as soon as VMIN bytes are there or VTIME expires.
    #
    # Reline switches between the two several times per keystroke. None of it
    # is a property of the serial port.
    CR = 13
    LF = 10

    def self.read_console(buffer, count)
      return read_raw(buffer, count) unless TTY.canonical?

      # serial_read waits in C for its first byte, which would hold the VM for
      # as long as nobody types. So it is only called once a byte is there.
      return WAIT_AGAIN unless serial_ready?

      length = serial_read(buffer, count)
      return length if length <= 0

      if TTY.translate_cr?
        bytes = read_bytes(buffer, length)
        translated = false
        i = 0
        while i < bytes.length
          if bytes[i] == CR
            bytes[i] = LF
            translated = true
          end
          i += 1
        end
        write_bytes(buffer, bytes) if translated
      end

      serial_write(buffer, length) if TTY.echo?
      length
    end

    # VMIN 0 with VTIME 0 means "whatever is there, do not wait", which is how
    # Reline asks whether a byte has arrived without committing to waiting for
    # one. Returning 0 there is a real answer, not end of file, and the caller
    # reads it as nil.
    #
    # Otherwise this waits the way Poll.wait does: one look per dispatch, and
    # WAIT_AGAIN to be asked again after the next tick, with the VTIME deadline
    # held by the bridge across the retries.
    def self.read_raw(buffer, count)
      minimum = TTY.min_bytes
      deadline = TTY.time_tenths > 0 ? clock_millis + TTY.time_tenths * 100 : nil

      if minimum == 0 && deadline.nil?
        return serial_ready? ? serial_read_ready(buffer, count) : 0
      end

      unless serial_ready?
        held = held_deadline(deadline || -1)
        return 0 if held != -1 && clock_millis >= held
        return WAIT_AGAIN
      end

      length = serial_read_ready(buffer, count)
      serial_write(buffer, length) if TTY.echo? && length > 0
      length
    end

    # Two descriptors sharing a buffer, written back into the caller's array
    # of two ints.
    def self.sys_pipe(address)
      ends = FD.open_pipe
      return ENFILE if ends.nil?

      poke32(address, ends[0])
      poke32(address + 4, ends[1])
      0
    end

    def self.sys_open(path_address)
      path = cstring(path_address)
      return ENOENT unless VFS.exist?(path)

      number = FD.open_file(path)
      return EMFILE if number.nil?

      count_open
      number
    end

    def self.sys_close(fd)
      return 0 if FD.console?(fd)
      FD.close(fd) ? 0 : EBADF
    end

    def self.sys_lseek(fd, offset, whence)
      position = FD.seek(fd, offset, whence)
      position.nil? ? EBADF : position
    end

    # Fills the caller's struct stat. Which fields matter, and what a file
    # without a filesystem should claim, is policy, so it is decided here; the
    # kernel only supplies the means to write the bytes.
    def self.sys_fstat(fd, address)
      return EFAULT if address == 0

      memzero(address, STAT_SIZE)

      if FD.console?(fd)
        poke64(address + STAT_MODE, S_IFCHR | 0o620)
        poke64(address + STAT_BLKSIZE, 1024)
        return 0
      end

      file = FD.entry(fd)
      return EBADF unless file

      if file[:pipe]
        poke64(address + STAT_MODE, S_IFIFO | 0o600)
        poke64(address + STAT_BLKSIZE, 1024)
        return 0
      end

      # CRuby decides whether IO#close_read and IO#close_write should shut a
      # descriptor down by asking fstat and testing S_ISSOCK, and treats a
      # failed fstat as fatal. So this answer is load-bearing rather than
      # decorative.
      if file[:socket]
        poke64(address + STAT_MODE, S_IFSOCK | 0o600)
        poke64(address + STAT_BLKSIZE, 4096)
        return 0
      end

      poke64(address + STAT_MODE, S_IFREG | 0o444)
      poke64(address + STAT_ST_SIZE, file[:size])
      poke64(address + STAT_BLKSIZE, 1024)
      0
    end

    ERANGE = -34
    ENOTTY = -25

    # ---------------------------------------------------------------- terminal

    TCGETS     = 0x5401
    TCSETS     = 0x5402
    TCSETSW    = 0x5403
    TCSETSF    = 0x5404
    TIOCGWINSZ = 0x5413
    TIOCSWINSZ = 0x5414

    # Only the console is a terminal. Answering TCGETS is also what makes it
    # one: isatty is a successful TCGETS and nothing else, so this decides
    # whether CRuby and Reline believe they are talking to a person.
    def self.sys_ioctl(fd, request, address)
      return ENOTTY unless FD.console?(fd)
      return EFAULT if address == 0

      case request
      when TCGETS                     then TTY.get_termios(address)
      when TCSETS, TCSETSW, TCSETSF   then TTY.set_termios(address)
      when TIOCGWINSZ                 then TTY.get_winsize(address)
      when TIOCSWINSZ                 then TTY.set_winsize(address)
      else ENOTTY
      end
    end

    # ---------------------------------------------------------------- waiting

    POLLIN = 0x0001

    # struct pollfd is { int fd; short events; short revents; }.
    POLLFD_SIZE = 8

    # Readiness is decided in Kernel::Poll, for every kind of descriptor at
    # once. These four only differ in how the request arrives and how the answer
    # is reported.
    def self.sys_poll(fds, nfds, timeout_ms)
      Poll.poll(fds, nfds, timeout_ms)
    end

    # ppoll's timeout is a struct timespec rather than milliseconds. The signal
    # mask is ignored, which is truthful: nothing here delivers signals.
    def self.sys_ppoll(fds, nfds, timespec)
      if timespec == 0
        Poll.poll(fds, nfds, -1)
      else
        seconds = peek64(timespec)
        nanos = peek64(timespec + 8)
        Poll.poll(fds, nfds, seconds * 1000 + nanos / 1_000_000)
      end
    end

    # select's timeout is a struct timeval, in microseconds. A null pointer
    # means wait indefinitely; a zeroed one means look once and return.
    def self.sys_select(nfds, readfds, writefds, exceptfds, timeout)
      deadline =
        if timeout == 0
          nil
        else
          clock_millis + peek64(timeout) * 1000 + peek64(timeout + 8) / 1000
        end
      Poll.select(nfds, readfds, writefds, exceptfds, deadline)
    end

    # pselect6's is a struct timespec, in nanoseconds. Nothing in CRuby reaches
    # this -- musl's select() uses the select syscall on x86_64 -- but it is
    # four lines sharing the same implementation, and cheap insurance against
    # that changing.
    def self.sys_pselect6(nfds, readfds, writefds, exceptfds, timespec)
      deadline =
        if timespec == 0
          nil
        else
          clock_millis + peek64(timespec) * 1000 + peek64(timespec + 8) / 1_000_000
        end
      Poll.select(nfds, readfds, writefds, exceptfds, deadline)
    end

    # There is one directory and everything is in it. Linux returns the length
    # including the terminating NUL.
    def self.sys_getcwd(buffer, size)
      return ERANGE if size < 2

      write_bytes(buffer, [47, 0])   # "/"
      2
    end

    # Does this path exist? Everything served is readable and nothing is
    # writable or executable, so the mode the caller asks about does not change
    # the answer.
    def self.sys_access(path_address)
      path = cstring(path_address)
      return 0 if VFS.exist?(path) || VFS.directory?(path)

      ENOENT
    end

    # Describing a file by name. The same decisions as sys_fstat, made from the
    # VFS rather than from a descriptor.
    def self.sys_stat(path_address, address)
      return EFAULT if address == 0

      path = cstring(path_address)

      if VFS.directory?(path)
        memzero(address, STAT_SIZE)
        poke64(address + STAT_MODE, S_IFDIR | 0o555)
        poke64(address + STAT_BLKSIZE, 1024)
        return 0
      end

      size = VFS.size(path)
      return ENOENT if size.nil?

      memzero(address, STAT_SIZE)
      poke64(address + STAT_MODE, S_IFREG | 0o444)
      poke64(address + STAT_ST_SIZE, size)
      poke64(address + STAT_BLKSIZE, 1024)
      0
    end

    # ---------------------------------------------------------------- memory

    ENOMEM = -12
    EINVAL = -22

    # Anonymous mappings get fresh pages. File mappings are answered with the
    # address the file already occupies: the filesystem lives in the image, in
    # read-only memory, so a read-only private mapping of it is exactly that
    # memory. Nothing is copied.
    #
    # This path matters more than it looks. Prism reads source files by mapping
    # them, not by reading them, so require goes through here rather than
    # through sys_read -- which is why a mmap that ignored the descriptor made
    # every required file look empty while still appearing to load.
    def self.sys_mmap(length, fd, offset)
      if fd < 0
        page = Memory.allocate(length)
        return page.nil? ? ENOMEM : page
      end

      file = FD.entry(fd)
      return ENOMEM if file.nil? || file[:pipe]
      return ENOMEM if offset + length > file[:size] + 4096

      file[:address] + offset
    end

    # Gives pages back. What counts as the kernel's to take back is decided in
    # Memory.release; here only the arguments Linux itself would refuse.
    def self.sys_munmap(address, length)
      return EINVAL if length <= 0 || address % Memory::PAGE != 0

      Memory.release(address, length)
      0
    end

    # ---------------------------------------------------------------- support

    # Counted so the routing can be shown to be real. Identical output would
    # appear whether or not this file ran at all, which is not evidence of
    # anything; a count kept on the Ruby side is.
    def self.count(bytes)
      @calls = (@calls || 0) + 1
      @bytes = (@bytes || 0) + bytes
      bytes
    end

    def self.report
      puts "ruby serviced #{@calls || 0} writes, #{@bytes || 0} bytes, " \
           "#{@opens || 0} opens"
      Memory.report
    end

    def self.count_open
      @opens = (@opens || 0) + 1
    end
  end
end
