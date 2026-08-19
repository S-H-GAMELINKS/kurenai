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
    NR_LSEEK     = 8
    NR_PIPE      = 22
    NR_WRITEV    = 20
    NR_PIPE2     = 293
    NR_OPENAT    = 257

    EBADF  = -9
    EAGAIN = -11
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
    S_IFCHR  = 0o020000
    S_IFIFO  = 0o010000

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
      when NR_LSEEK  then sys_lseek(a1, a2, a3)
      when NR_PIPE, NR_PIPE2 then sys_pipe(a1)
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

      written = FD.write_pipe(fd, buffer, count)
      written.nil? ? EBADF : written
    end

    # musl's stdio flushes through writev, not write, so this is the one that
    # actually carries CRuby's output. The iovec array is walked here, in Ruby,
    # reading CRuby's memory a field at a time.
    def self.sys_writev(fd, iov, iovcnt)
      return EBADF unless fd == FD::CONSOLE_OUT || fd == FD::CONSOLE_ERR

      total = 0
      i = 0
      while i < iovcnt
        entry = iov + i * IOVEC_SIZE
        base = peek64(entry)
        len = peek64(entry + 8)
        if len > 0
          serial_write(base, len)
          total += len
        end
        i += 1
      end
      count(total)
    end

    # ---------------------------------------------------------------- files

    def self.sys_read(fd, buffer, count)
      return read_console(buffer, count) if fd == FD::CONSOLE_IN

      length = FD.read(fd, buffer, count)
      return EBADF if length.nil?
      return EAGAIN if length == :empty

      length
    end

    # The beginnings of a line discipline, and the reason it belongs in Ruby.
    #
    # A terminal sends carriage return when Return is pressed, and a program
    # calling gets waits for a line feed, so something has to translate. The
    # terminal is also not echoing -- there is no terminal, only a serial port
    # -- so the kernel has to show the user what they typed. Neither of these
    # is a property of the hardware; both are policy, and this is where policy
    # lives.
    CR = 13
    LF = 10

    def self.read_console(buffer, count)
      length = serial_read(buffer, count)
      return length if length <= 0

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

      # Echo, so typing is visible.
      serial_write(buffer, length)
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

      poke64(address + STAT_MODE, S_IFREG | 0o444)
      poke64(address + STAT_ST_SIZE, file[:size])
      poke64(address + STAT_BLKSIZE, 1024)
      0
    end

    # Describing a file by name. The same decisions as sys_fstat, made from the
    # VFS rather than from a descriptor.
    def self.sys_stat(path_address, address)
      return EFAULT if address == 0

      path = cstring(path_address)
      size = VFS.size(path)
      return ENOENT if size.nil?

      memzero(address, STAT_SIZE)
      poke64(address + STAT_MODE, S_IFREG | 0o444)
      poke64(address + STAT_ST_SIZE, size)
      poke64(address + STAT_BLKSIZE, 1024)
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
    end

    def self.count_open
      @opens = (@opens || 0) + 1
    end
  end
end
