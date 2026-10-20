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
    NR_CONNECT    = 42
    NR_SENDTO     = 44
    NR_RECVFROM   = 45
    NR_SENDMSG    = 46
    NR_RECVMSG    = 47
    NR_PREAD64    = 17
    NR_PWRITE64   = 18
    NR_FTRUNCATE  = 77
    NR_GETDENTS64 = 217
    NR_RENAME     = 82
    NR_RENAMEAT   = 264
    NR_RENAMEAT2  = 316
    NR_MKDIR      = 83
    NR_MKDIRAT    = 258
    NR_RMDIR      = 84
    NR_UNLINK     = 87
    NR_UNLINKAT   = 263
    NR_FCNTL      = 72

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
    EEXIST = -17
    ENOTDIR = -20
    EISDIR = -21
    ENOTEMPTY = -39

    # open(2) flags, x86_64.
    O_ACCMODE   = 0o3
    O_WRONLY    = 0o1
    O_RDWR      = 0o2
    O_CREAT     = 0o100
    O_EXCL      = 0o200
    O_TRUNC     = 0o1000
    O_APPEND    = 0o2000
    O_DIRECTORY = 0o200000
    O_NONBLOCK  = 0o4000

    F_GETFD = 1
    F_SETFD = 2
    F_GETFL = 3
    F_SETFL = 4

    AT_REMOVEDIR = 0x200

    # struct iovec is { void *base; size_t len; } on x86_64.
    IOVEC_SIZE = 16

    # Field offsets in struct stat on x86_64. Only the two fields anyone looks
    # at are filled; the rest stays zero, which is a truthful description of a
    # file that has no owner, no times and no device.
    STAT_SIZE       = 144
    STAT_INO        = 8
    STAT_NLINK      = 16
    STAT_MODE       = 24    # st_mode, 4 bytes, followed by st_uid
    STAT_ST_SIZE    = 48
    STAT_BLKSIZE    = 56
    STAT_MTIME      = 88    # st_mtim: seconds, then nanoseconds

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
      when NR_OPEN   then sys_open(a1, a2)
      when NR_OPENAT then sys_open(a2, a3)  # relative paths are not supported
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
      when NR_CONNECT      then Sockets.sys_connect(a1, a2, a3)
      when NR_SENDTO       then Sockets.sys_sendto(a1, a2, a3, a4, a5, a6)
      when NR_RECVFROM     then Sockets.sys_recvfrom(a1, a2, a3, a4, a5, a6)
      when NR_SENDMSG      then Sockets.sys_sendmsg(a1, a2, a3)
      when NR_RECVMSG      then Sockets.sys_recvmsg(a1, a2, a3)
      when NR_PREAD64      then sys_pread(a1, a2, a3, a4)
      when NR_PWRITE64     then sys_pwrite(a1, a2, a3, a4)
      when NR_FTRUNCATE    then sys_ftruncate(a1, a2)
      when NR_GETDENTS64   then sys_getdents64(a1, a2, a3)
      when NR_RENAME       then sys_rename(a1, a2)
      when NR_RENAMEAT, NR_RENAMEAT2 then sys_rename(a2, a4)
      when NR_MKDIR        then sys_mkdir(a1)
      when NR_MKDIRAT      then sys_mkdir(a2)
      when NR_RMDIR        then sys_rmdir(a1)
      when NR_UNLINK       then sys_unlink(a1)
      when NR_UNLINKAT
        (a3 & AT_REMOVEDIR) != 0 ? sys_rmdir(a2) : sys_unlink(a2)
      when NR_FCNTL        then sys_fcntl(a1, a2, a3)
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

      if FD.file?(fd)
        written = FD.write_file(fd, buffer, count)
        return written.nil? ? EBADF : written
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
      return EISDIR if length == :directory

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
      return nothing_to_read unless serial_ready?

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
        return nothing_to_read
      end

      length = serial_read_ready(buffer, count)
      serial_write(buffer, length) if TTY.echo? && length > 0
      length
    end

    # An empty console: wait for a byte, unless the caller set O_NONBLOCK, in
    # which case say so. CRuby's read_nonblock reads until it is told EAGAIN,
    # so a console that waited anyway held mui's input loop on its second
    # read for as long as nobody typed.
    def self.nothing_to_read
      FD.nonblocking?(FD::CONSOLE_IN) ? EAGAIN : WAIT_AGAIN
    end

    # Descriptor flags. FD_CLOEXEC means nothing where nothing is exec'd, and
    # is accepted and forgotten. The status flags are real: the access mode a
    # descriptor was opened with, O_APPEND, and O_NONBLOCK, which is kept per
    # descriptor because it changes what a read of an empty console does.
    #
    # This used to be C's, answering F_GETFL with O_RDWR|O_NONBLOCK for every
    # descriptor and ignoring F_SETFL. CRuby believed it, never set O_NONBLOCK
    # itself, and read the console expecting EAGAIN that never came.
    def self.sys_fcntl(fd, command, argument)
      return EBADF unless FD.console?(fd) || FD.entry(fd)

      case command
      when F_GETFD, F_SETFD then 0
      when F_GETFL then FD.status_flags(fd)
      when F_SETFL
        FD.set_status_flags(fd, argument)
        0
      else EINVAL
      end
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

    # What a descriptor may do is decided here, once, from the flags; FD only
    # enforces it. A file from the image becomes writable when something opens
    # it for writing -- see VFS.make_writable -- not when it is first written,
    # so O_TRUNC can take effect at once.
    def self.sys_open(path_address, flags)
      path = cstring(path_address)
      return ENOENT if path.empty?

      if VFS.directory?(path)
        return EISDIR if (flags & O_ACCMODE) != 0
        number = FD.open_directory(path)
        return number.nil? ? EMFILE : number
      end
      return ENOTDIR if (flags & O_DIRECTORY) != 0 && VFS.exist?(path)

      node = VFS.lookup(path)
      if node.nil?
        return ENOENT if (flags & O_CREAT) == 0
        node = VFS.create(path)
        return ENOENT if node.nil?
      elsif (flags & O_CREAT) != 0 && (flags & O_EXCL) != 0
        return EEXIST
      end

      mode = flags & O_ACCMODE
      readable = mode != O_WRONLY
      writable = mode != 0
      if writable
        return ENOMEM unless VFS.make_writable(node)
        VFS.truncate(node, 0) if (flags & O_TRUNC) != 0
      end

      number = FD.open_file(path, node, readable, writable, (flags & O_APPEND) != 0)
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

      if file[:directory]
        describe_directory(address, VFS.directory_ino(file[:path]) || 0)
        return 0
      end

      describe_file(address, file[:node])
      0
    end

    # A file's struct stat. mtime matters more than it looks: WEBrick answers a
    # browser's If-Modified-Since by comparing it, and with every mtime at zero
    # an edited page was "not modified" for ever. It is time since boot -- the
    # only clock there is -- which is enough for it to move forward when a file
    # is written.
    def self.describe_file(address, node)
      memzero(address, STAT_SIZE)
      poke64(address + STAT_INO, node[:ino])
      poke64(address + STAT_NLINK, 1)
      poke64(address + STAT_MODE, S_IFREG | 0o644)
      poke64(address + STAT_ST_SIZE, node[:size])
      poke64(address + STAT_BLKSIZE, 1024)
      poke64(address + STAT_MTIME, node[:mtime] / 1000)
      poke64(address + STAT_MTIME + 8, (node[:mtime] % 1000) * 1_000_000)
    end

    def self.describe_directory(address, ino)
      memzero(address, STAT_SIZE)
      poke64(address + STAT_INO, ino)
      poke64(address + STAT_NLINK, 2)
      poke64(address + STAT_MODE, S_IFDIR | 0o755)
      poke64(address + STAT_BLKSIZE, 1024)
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

    # Does this path exist? Everything is readable and writable -- a file from
    # the image is copied the first time it is opened for writing -- and
    # nothing is executable, which no caller has asked about yet. So the mode
    # does not change the answer.
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
        describe_directory(address, VFS.directory_ino(path))
        return 0
      end

      node = VFS.lookup(path)
      return ENOENT if node.nil?

      describe_file(address, node)
      0
    end

    # ---------------------------------------------------------------- files

    def self.sys_pread(fd, buffer, count, offset)
      file = FD.entry(fd)
      return EBADF unless file && file[:node] && file[:readable]

      FD.read_at(file, buffer, count, offset)
    end

    def self.sys_pwrite(fd, buffer, count, offset)
      file = FD.entry(fd)
      return EBADF unless file && file[:node] && file[:writable]

      written = VFS.write(file[:node], offset, buffer, count)
      written.nil? ? ENOMEM : written
    end

    def self.sys_ftruncate(fd, length)
      file = FD.entry(fd)
      return EBADF unless file && file[:node] && file[:writable]

      VFS.truncate(file[:node], length).nil? ? ENOMEM : 0
    end

    def self.sys_unlink(path_address)
      path = cstring(path_address)
      return EISDIR if VFS.directory?(path)

      VFS.unlink(path) ? 0 : ENOENT
    end

    def self.sys_rename(from_address, to_address)
      from = cstring(from_address)
      to = cstring(to_address)
      return EINVAL if VFS.directory?(from)       # files only, for now
      return EISDIR if VFS.directory?(to)
      return ENOENT unless VFS.exist?(from)
      return ENOENT unless VFS.directory?(VFS.parent(to))

      VFS.rename(from, to)
      0
    end

    def self.sys_mkdir(path_address)
      path = cstring(path_address)
      return EEXIST if VFS.directory?(path) || VFS.exist?(path)
      return ENOENT unless VFS.directory?(VFS.parent(path))

      VFS.mkdir(path)
      0
    end

    def self.sys_rmdir(path_address)
      path = cstring(path_address)
      return ENOTDIR unless VFS.directory?(path)
      return EINVAL if VFS.normalize(path) == "/"
      return ENOTEMPTY unless VFS.empty_directory?(path)

      VFS.rmdir(path)
      0
    end

    # struct linux_dirent64: u64 d_ino, s64 d_off, u16 d_reclen, u8 d_type,
    # then the NUL-terminated name, the whole record padded to eight bytes.
    # "." and ".." come first, as readdir's callers expect; d_off is just the
    # index of the next record, which is all anything uses it for.
    DT_DIR = 4
    DT_REG = 8

    def self.sys_getdents64(fd, buffer, size)
      file = FD.entry(fd)
      return EBADF if file.nil?
      return ENOTDIR unless file[:directory]

      entries = file[:entries]
      written = 0
      while file[:position] < entries.length + 2
        index = file[:position]
        name, ino, directory =
          if index == 0 then [".", 0, true]
          elsif index == 1 then ["..", 0, true]
          else entries[index - 2]
          end

        length = (19 + name.length + 1 + 7) & ~7
        if written + length > size
          return EINVAL if written == 0
          break
        end

        record = buffer + written
        memzero(record, length)
        poke64(record, ino)
        poke64(record + 8, index + 1)
        poke16(record + 16, length)
        write_bytes(record + 18, [directory ? DT_DIR : DT_REG])
        write_bytes(record + 19, name.bytes)
        written += length
        file[:position] += 1
      end
      written
    end

    # ---------------------------------------------------------------- memory

    ENOMEM = -12
    EINVAL = -22

    # Anonymous mappings get fresh pages. A file still in the image is answered
    # with the address it already occupies: it is read-only memory, so a
    # read-only private mapping of it is exactly that memory, and nothing is
    # copied. A writable file is copied into fresh pages -- a private mapping,
    # as MAP_PRIVATE promises -- because handing out its own pages would let
    # munmap give them back while the file still lives in them. Prism maps and
    # then unmaps every file it parses, so this is the path require of a file
    # written at run time takes.
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
      return ENOMEM if file.nil? || file[:node].nil?
      node = file[:node]
      return ENOMEM if offset + length > node[:size] + 4096

      return node[:address] + offset unless node[:writable]

      copy = Memory.allocate(length)
      return ENOMEM if copy.nil?
      available = node[:size] - offset
      available = length if available > length
      copy_out(copy, node[:address] + offset, available) if available > 0
      copy
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
