# The kernel's syscall policy, written in Ruby.
#
# CRuby runs as userland. Its libc is patched so that every syscall becomes a
# call into the kernel, and the kernel forwards the ones listed in the routing
# table to this method. So Kernel::Syscall.dispatch is not a model of a syscall
# handler; while CRuby is writing to standard output, this is what runs.
#
# Buffers arrive as plain integers: addresses in CRuby's part of the one flat
# address space this system has. They are never copied into Ruby strings. Two
# garbage collectors are running here, and neither may see the other's objects;
# passing an address and letting a C primitive move the bytes is what keeps
# that boundary intact.
module Kernel
  module Syscall
    # Linux x86_64 syscall numbers.
    NR_WRITE  = 1
    NR_WRITEV = 20

    EBADF  = -9
    ENOSYS = -38

    # struct iovec is { void *base; size_t len; } on x86_64.
    IOVEC_SIZE = 16

    # Always returns an Integer: negative is -errno, as the caller expects.
    # Never nil, and never an exception -- there is nobody above to catch one.
    def self.dispatch(number, a1, a2, a3, a4, a5, a6)
      case number
      when NR_WRITE  then sys_write(a1, a2, a3)
      when NR_WRITEV then sys_writev(a1, a2, a3)
      else ENOSYS
      end
    end

    # fd 1 and 2 are the console. The buffer stays where it is; serial_write is
    # a C primitive registered on this module and reads it in place.
    def self.sys_write(fd, buffer, count)
      return EBADF unless fd == 1 || fd == 2

      serial_write(buffer, count)
      count(count)
    end

    # musl's stdio flushes through writev, not write, so this is the one that
    # actually carries CRuby's output. The iovec array is walked here, in Ruby,
    # reading CRuby's memory a field at a time.
    def self.sys_writev(fd, iov, iovcnt)
      return EBADF unless fd == 1 || fd == 2

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

    # Counted so the routing can be shown to be real. Identical output would
    # appear whether or not this file ran at all, which is not evidence of
    # anything; a count kept on the Ruby side is.
    def self.count(bytes)
      @calls = (@calls || 0) + 1
      @bytes = (@bytes || 0) + bytes
      bytes
    end

    def self.report
      puts "ruby serviced #{@calls || 0} writes, #{@bytes || 0} bytes"
    end
  end
end
