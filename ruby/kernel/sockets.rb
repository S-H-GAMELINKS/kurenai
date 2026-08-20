# The socket syscalls, in Ruby.
#
# CRuby's ext/socket is linked into the image and calls socket, bind, listen,
# accept4, getsockname, getpeername, setsockopt and getsockopt exactly as it
# would on Linux. musl turns each into a call into this kernel, and this decides
# what they mean.
#
# Which is to say: when WEBrick asks for a listening socket, the family it is
# allowed, the port it is given, what a second accept with nothing waiting
# returns, and what address a request appears to come from are all decided here,
# in Ruby, by the other VM.
#
# Payload bytes are not this module's business -- read and write go through
# Kernel::FD, where they cross as addresses. What crosses here is small and
# structured: a sockaddr is sixteen bytes and every field is fixed width.
module Kernel
  module Sockets
    AF_INET  = 2
    AF_INET6 = 10

    SOCK_STREAM = 1
    SOCK_DGRAM  = 2

    # Flags ORed into socket()'s type and accept4()'s flags. CRuby always asks
    # for both, and both are already true of every descriptor here.
    SOCK_NONBLOCK = 0x0800
    SOCK_CLOEXEC  = 0x80000

    SOL_SOCKET = 1
    SO_ERROR   = 4
    SO_TYPE    = 3

    # struct sockaddr_in, sixteen bytes. The family is host order and the port
    # and address are network order, which is why this is written out a byte at
    # a time rather than poked as words.
    SOCKADDR_IN_SIZE = 16

    EAFNOSUPPORT    = -97
    ESOCKTNOSUPPORT = -94
    ENOTCONN        = -107
    ENOPROTOOPT     = -92
    EINVAL          = -22
    EAGAIN          = -11
    EBADF           = -9
    ENOTSOCK        = -88
    EOPNOTSUPP      = -95
    EADDRINUSE      = -98
    EMFILE          = -24
    EFAULT          = -14
    ENETDOWN        = -100

    # ---------------------------------------------------------------- socket

    # domain, type and protocol. Only IPv4 stream sockets exist here, and
    # refusing the others has to be done with the right errno rather than any
    # errno: ext/socket's Socket.tcp_server_sockets asks for an AF_INET6
    # listener first and skips it on a SystemCallError, so EAFNOSUPPORT is what
    # turns "no IPv6" into one IPv4 listener instead of an exception. musl's
    # socket() also retries without the flag bits on EINVAL and
    # EPROTONOSUPPORT, so neither of those may be used to say "wrong family".
    def self.sys_socket(domain, type, protocol)
      return EAFNOSUPPORT unless domain == AF_INET

      kind = type & 0xFF
      flags = type & ~0xFF
      return EINVAL if flags & ~(SOCK_NONBLOCK | SOCK_CLOEXEC) != 0
      return ESOCKTNOSUPPORT unless kind == SOCK_STREAM

      number = FD.open_socket
      number.nil? ? EMFILE : number
    end

    def self.sys_bind(fd, address, length)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if address == 0 || length < SOCKADDR_IN_SIZE

      family = Syscall.peek32(address) & 0xFFFF
      return EAFNOSUPPORT unless family == AF_INET

      bytes = Syscall.read_bytes(address, SOCKADDR_IN_SIZE)
      entry[:port] = (bytes[2] << 8) | bytes[3]
      entry[:ip] = (bytes[4] << 24) | (bytes[5] << 16) |
                   (bytes[6] << 8) | bytes[7]
      0
    end

    # This is where a socket becomes real: lwIP's raw API makes the pcb, binds
    # it and listens in one call from picoruby-socket's port, so the descriptor
    # has been carrying its address around until now.
    #
    # The address bound to is not passed on. The port layer always listens on
    # every interface, and this machine has one; saying so is better than
    # pretending the argument was honoured.
    def self.sys_listen(fd, backlog)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return 0 if entry[:listening]

      backlog = 1 if backlog < 1
      backlog = 255 if backlog > 255

      # Two different failures, and telling them apart matters more than it
      # looks. A machine with no card cannot listen at all, and answering
      # EADDRINUSE there sends the caller looking for the other program holding
      # the port -- of which there are none, on a machine with one process.
      return ENETDOWN unless E1000.up?

      handle = Net.listen(entry[:port], backlog)
      return EADDRINUSE if handle.nil?

      entry[:handle] = handle
      entry[:listening] = true
      entry[:pending] = []
      0
    end

    # Moves connections lwIP has accepted into this descriptor's own queue.
    #
    # picoruby-socket's port keeps exactly one accepted socket at a time and
    # aborts a second connection that arrives before the first is claimed.
    # Draining into a queue here is what makes a backlog larger than one
    # possible, and it is also what lets poll answer "a connection is waiting"
    # without consuming it.
    def self.drain_accepts(entry)
      queue = entry[:pending]
      return 0 if queue.nil?

      loop do
        handle = Net.accept(entry[:handle])
        break if handle.nil?
        queue.push(handle)
      end
      queue.length
    end

    def self.sys_accept4(fd, address, length_address, flags)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket] && entry[:listening]
      return EINVAL if flags & ~(SOCK_NONBLOCK | SOCK_CLOEXEC) != 0

      drain_accepts(entry) if entry[:pending].empty?
      return EAGAIN if entry[:pending].empty?

      handle = entry[:pending].shift
      number = FD.adopt_socket(handle)
      if number.nil?
        Net.close(handle)
        return EMFILE
      end

      write_sockaddr(address, length_address,
                     Net.peer_ip(handle), Net.peer_port(handle))
      number
    end

    # ---------------------------------------------------------------- names

    def self.sys_getsockname(fd, address, length_address)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]

      if entry[:listening] || entry[:handle].nil?
        write_sockaddr(address, length_address, entry[:ip], entry[:port])
      else
        write_sockaddr(address, length_address,
                       Net.local_ip(entry[:handle]),
                       Net.local_port(entry[:handle]))
      end
      0
    end

    def self.sys_getpeername(fd, address, length_address)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return ENOTCONN if entry[:handle].nil? || entry[:listening]

      write_sockaddr(address, length_address,
                     Net.peer_ip(entry[:handle]),
                     Net.peer_port(entry[:handle]))
      0
    end

    # ---------------------------------------------------------------- options

    # Accepting every option is not laziness here, it is what the caller
    # requires. Addrinfo#listen sets SO_REUSEADDR inside a begin/rescue that
    # closes the socket and re-raises, so a refusal aborts listener creation
    # entirely -- and musl's setsockopt retries with a different option number
    # on ENOPROTOOPT, which turns one refusal into two.
    #
    # Nothing is recorded because nothing would read it. lwIP's listen already
    # sets address reuse, and there is no second process to conflict with.
    def self.sys_setsockopt(fd, level, name, value, length)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      0
    end

    # SO_ERROR is the one that has to be right. ext/socket reads it after a
    # non-blocking connect and treats anything non-zero as the failure, so it
    # must be a four-byte zero and the length must be set.
    def self.sys_getsockopt(fd, level, name, value, length_address)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if value == 0

      if level == SOL_SOCKET && name == SO_ERROR
        Syscall.poke32(value, 0)
        Syscall.poke32(length_address, 4) if length_address != 0
        return 0
      end

      if level == SOL_SOCKET && name == SO_TYPE
        Syscall.poke32(value, SOCK_STREAM)
        Syscall.poke32(length_address, 4) if length_address != 0
        return 0
      end

      ENOPROTOOPT
    end

    # Half-closing is not something lwIP's raw API offers through this port, and
    # a listener has nothing to half-close. WEBrick shuts its listeners down
    # this way at exit, so a listener is closed for real and a connection is
    # told yes -- the close that follows sends the FIN either way.
    def self.sys_shutdown(fd, how)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]

      if entry[:listening] && entry[:handle]
        Net.close_server(entry[:handle])
        entry[:handle] = nil
        entry[:listening] = false
      end
      0
    end

    # ---------------------------------------------------------------- sockaddr

    def self.write_sockaddr(address, length_address, ip, port)
      return if address == 0

      Syscall.write_bytes(address, [
        AF_INET, 0,
        (port >> 8) & 0xFF, port & 0xFF,
        (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF,
        0, 0, 0, 0, 0, 0, 0, 0
      ])
      # socklen_t is four bytes, not eight.
      Syscall.poke32(length_address, SOCKADDR_IN_SIZE) if length_address != 0
    end
  end
end
