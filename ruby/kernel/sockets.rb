# The socket syscalls, in Ruby.
#
# CRuby's ext/socket is linked into the image and calls socket, bind, listen,
# accept4, connect, getsockname, getpeername, setsockopt and getsockopt exactly
# as it would on Linux, and musl's resolver adds sendto and recvfrom. musl turns
# each into a call into this kernel, and this decides what they mean.
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
    ENETUNREACH     = -101
    ENOBUFS         = -105
    EISCONN         = -106
    ETIMEDOUT       = -110
    ECONNREFUSED    = -111
    EALREADY        = -114
    EINPROGRESS     = -115
    EDESTADDRREQ    = -89

    AF_UNSPEC = 0

    # lwIP's err_t values a failed connection is reported with, and what each
    # means to the caller. A reset in answer to the SYN is a refusal; the SYN
    # retransmissions running out ends in an abort, which is a timeout from
    # outside; no route is no route. Anything else is called a refusal, since
    # whatever it was, nothing was connected to.
    LWIP_ERR_RTE  = -4
    LWIP_ERR_ABRT = -13
    LWIP_ERR_RST  = -14

    # picoruby-socket's SOCKET_STATE_* values, as Net.state reports them.
    STATE_CONNECTING = 1
    STATE_CONNECTED  = 2
    STATE_ERROR      = 99

    # ---------------------------------------------------------------- socket

    # domain, type and protocol. IPv4 stream and datagram sockets exist here,
    # and refusing the rest has to be done with the right errno rather than any
    # errno: ext/socket's Socket.tcp_server_sockets asks for an AF_INET6
    # listener first and skips it on a SystemCallError, so EAFNOSUPPORT is what
    # turns "no IPv6" into one IPv4 listener instead of an exception -- and the
    # same answer is what makes musl's resolver fall back to an IPv4 socket for
    # its queries. musl's socket() also retries without the flag bits on EINVAL
    # and EPROTONOSUPPORT, so neither of those may be used to say "wrong
    # family".
    #
    # SOCK_NONBLOCK is kept, because it decides whether a connect waits.
    def self.sys_socket(domain, type, protocol)
      return EAFNOSUPPORT unless domain == AF_INET

      kind = type & 0xFF
      flags = type & ~0xFF
      return EINVAL if flags & ~(SOCK_NONBLOCK | SOCK_CLOEXEC) != 0
      return ESOCKTNOSUPPORT unless kind == SOCK_STREAM || kind == SOCK_DGRAM

      number = FD.open_socket(kind == SOCK_DGRAM)
      return EMFILE if number.nil?

      FD.entry(number)[:nonblock] = true if flags & SOCK_NONBLOCK != 0
      number
    end

    def self.sys_bind(fd, address, length)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if address == 0 || length < SOCKADDR_IN_SIZE

      family = Syscall.peek32(address) & 0xFFFF
      return EAFNOSUPPORT unless family == AF_INET

      ip, port = read_sockaddr(address)
      entry[:port] = port
      entry[:ip] = ip

      # A stream socket's bind is only remembered, because lwIP binds and
      # listens in one call later on. A datagram socket is bound now: the
      # next thing it does is send, from the port it was given.
      if entry[:datagram]
        return ENETDOWN unless datagram_handle(entry)
        return EADDRINUSE unless Net.udp_bind(entry[:handle], port)
      end
      0
    end

    # The datagram socket underneath a descriptor, made on first use. socket()
    # succeeds on a machine with no card, as it does on Linux; it is binding
    # or sending that needs a network.
    def self.datagram_handle(entry)
      return entry[:handle] if entry[:handle]
      return nil unless E1000.up?

      entry[:handle] = Net.udp_open
    end

    # ---------------------------------------------------------------- connect

    # A stream socket starts a TCP handshake here; a datagram socket only
    # remembers where its sends go.
    #
    # A handshake takes a round trip, and this does not wait for it in the
    # dispatch: the SYN goes out and the descriptor is marked as connecting.
    # A non-blocking caller gets EINPROGRESS and finds out from poll and
    # SO_ERROR, which is what CRuby's TCPSocket.new does. A blocking one gets
    # WAIT_AGAIN until the handshake ends, and the bridge calls this again
    # with the same arguments after each tick -- so a second call on a socket
    # already connecting is either that retry, or a non-blocking caller asking
    # again, and the two are told apart by how the first call was made.
    def self.sys_connect(fd, address, length)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if address == 0 || length < 2

      family = Syscall.peek32(address) & 0xFFFF
      if entry[:datagram]
        if family == AF_UNSPEC
          entry[:peer] = nil
          return 0
        end
        return EAFNOSUPPORT unless family == AF_INET
        return EINVAL if length < SOCKADDR_IN_SIZE
        return ENETDOWN unless datagram_handle(entry)

        entry[:peer] = read_sockaddr(address)
        return 0
      end

      return connect_progress(entry) if entry[:handle]
      return EAFNOSUPPORT unless family == AF_INET
      return EINVAL if length < SOCKADDR_IN_SIZE
      return ENETDOWN unless E1000.up?

      ip, port = read_sockaddr(address)
      handle = Net.connect(ip, port)
      return ENOBUFS if handle.nil?

      entry[:handle] = handle
      entry[:connecting] = true
      entry[:waits] = !entry[:nonblock]
      Net.pump
      return EINPROGRESS if entry[:nonblock]

      connect_progress(entry)
    end

    # Where a connection that has been started has got to, as connect(2)
    # reports it the second time round.
    def self.connect_progress(entry)
      Net.pump
      state = Net.state(entry[:handle])

      if state == STATE_CONNECTING
        return entry[:waits] ? Syscall::WAIT_AGAIN : EALREADY
      end

      waited = entry[:waits]
      entry[:waits] = false
      if state == STATE_ERROR && entry[:connecting]
        entry[:connecting] = false
        return connect_errno(entry[:handle])
      end

      entry[:connecting] = false
      waited ? 0 : EISCONN
    end

    def self.connect_errno(handle)
      case Net.error(handle)
      when LWIP_ERR_RST  then ECONNREFUSED
      when LWIP_ERR_ABRT then ETIMEDOUT
      when LWIP_ERR_RTE  then ENETUNREACH
      else ECONNREFUSED
      end
    end

    # A connection still being made is neither readable nor writable. One that
    # failed is writable with an error, as Linux reports it: that is what wakes
    # a caller waiting to find out, and SO_ERROR then says why. Once someone
    # has looked, it is an ordinary dead connection.
    def self.connect_revents(entry)
      state = Net.state(entry[:handle])
      return 0 if state == STATE_CONNECTING

      if state == STATE_ERROR
        return Poll::POLLOUT | Poll::POLLERR | Poll::POLLHUP
      end

      entry[:connecting] = false
      nil
    end

    # ---------------------------------------------------------------- datagrams

    # sendto(2). On a stream socket the address is ignored, as Linux ignores
    # it on a connected one, and it is a write.
    def self.sys_sendto(fd, buffer, count, flags, address, length)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return Syscall.sys_write(fd, buffer, count) unless entry[:datagram]

      if address != 0
        return EINVAL if length < SOCKADDR_IN_SIZE
        return EAFNOSUPPORT unless (Syscall.peek32(address) & 0xFFFF) == AF_INET
        ip, port = read_sockaddr(address)
      elsif entry[:peer]
        ip, port = entry[:peer]
      else
        return EDESTADDRREQ
      end

      return ENETDOWN unless datagram_handle(entry)

      sent = Net.udp_sendto(entry[:handle], buffer, count, ip, port)
      return ENETUNREACH if sent < 0

      # Out now rather than at the next syscall: the reply cannot come back
      # until the query has left.
      Net.pump
      sent
    end

    # recvfrom(2). One datagram, and who sent it.
    def self.sys_recvfrom(fd, buffer, count, flags, address, length_address)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]

      unless entry[:datagram]
        length = Syscall.sys_read(fd, buffer, count)
        if length >= 0 && entry[:handle]
          write_sockaddr(address, length_address,
                         Net.peer_ip(entry[:handle]),
                         Net.peer_port(entry[:handle]))
        end
        return length
      end

      handle = entry[:handle]
      Net.pump
      length = handle ? Net.udp_recv(handle, buffer, count) : Net::WOULD_BLOCK
      if length == Net::WOULD_BLOCK
        return entry[:nonblock] ? EAGAIN : Syscall::WAIT_AGAIN
      end

      write_sockaddr(address, length_address,
                     Net.udp_sender_ip(handle), Net.udp_sender_port(handle))
      length
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

      if entry[:datagram]
        port = entry[:handle] ? Net.udp_local_port(entry[:handle]) : entry[:port]
        ip = entry[:peer] ? Syscall.net_address : entry[:ip]
        write_sockaddr(address, length_address, ip, port)
      elsif entry[:listening] || entry[:handle].nil?
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

      if entry[:datagram]
        return ENOTCONN unless entry[:peer]
        write_sockaddr(address, length_address, entry[:peer][0], entry[:peer][1])
        return 0
      end

      return ENOTCONN if entry[:handle].nil? || entry[:listening]

      write_sockaddr(address, length_address,
                     Net.peer_ip(entry[:handle]),
                     Net.peer_port(entry[:handle]))
      0
    end

    # ---------------------------------------------------------------- msghdr
    #
    # sendmsg and recvmsg are sendto and recvfrom with the buffer given as an
    # iovec array and the address inside a struct msghdr. musl's resolver
    # receives every answer this way, and sends this way when an answer was
    # too long for UDP and the query is repeated over TCP.
    #
    # struct msghdr on x86_64: name at 0, namelen at 8, iov at 16, iovlen at
    # 24, control at 32, controllen at 40, flags at 48.
    MSG_NAME       = 0
    MSG_NAMELEN    = 8
    MSG_IOV        = 16
    MSG_IOVLEN     = 24
    MSG_CONTROLLEN = 40
    MSG_FLAGS      = 48

    def self.sys_sendmsg(fd, message, flags)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if message == 0

      name = Syscall.peek64(message + MSG_NAME)
      name_length = Syscall.peek32(message + MSG_NAMELEN)
      iov = Syscall.peek64(message + MSG_IOV)
      count = Syscall.peek64(message + MSG_IOVLEN)

      if entry[:datagram]
        # One datagram is one buffer here. musl never sends a datagram in
        # pieces, and gathering them would mean copying through the VM.
        return EINVAL if count != 1
        return sys_sendto(fd, Syscall.peek64(iov), Syscall.peek64(iov + 8),
                          flags, name, name_length)
      end

      # A stream socket with an address and no connection is TCP Fast Open:
      # connect and send in one call. The connect is started and nothing is
      # sent yet, which is EINPROGRESS -- the answer Linux gives when the
      # data could not go with the SYN -- and the caller sends again once
      # the socket is writable.
      if entry[:handle].nil? && name != 0
        started = sys_connect(fd, name, name_length)
        return started if started < 0 && started != EINPROGRESS
        return EINPROGRESS
      end

      Syscall.sys_writev(fd, iov, count)
    end

    def self.sys_recvmsg(fd, message, flags)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if message == 0

      name = Syscall.peek64(message + MSG_NAME)
      iov = Syscall.peek64(message + MSG_IOV)
      count = Syscall.peek64(message + MSG_IOVLEN)
      return EINVAL if count < 1

      # No ancillary data is ever delivered, and nothing is truncated that the
      # caller is told about.
      Syscall.poke64(message + MSG_CONTROLLEN, 0)
      Syscall.poke32(message + MSG_FLAGS, 0)

      if entry[:datagram]
        length = sys_recvfrom(fd, Syscall.peek64(iov), Syscall.peek64(iov + 8),
                              flags, name, name == 0 ? 0 : message + MSG_NAMELEN)
        return length
      end

      # A stream is read into each buffer in turn, stopping at the first that
      # is not filled: that is all there was.
      total = 0
      i = 0
      while i < count
        base = Syscall.peek64(iov + i * Syscall::IOVEC_SIZE)
        size = Syscall.peek64(iov + i * Syscall::IOVEC_SIZE + 8)
        if size > 0
          length = Syscall.sys_read(fd, base, size)
          if length < 0
            return total > 0 ? total : length
          end
          total += length
          break if length < size
        end
        i += 1
      end
      total
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
    # is the connection's real fate once that is known, and zero otherwise --
    # a four-byte errno, positive, with the length set. Reading it clears it,
    # as on Linux.
    def self.sys_getsockopt(fd, level, name, value, length_address)
      entry = FD.entry(fd)
      return EBADF if entry.nil?
      return ENOTSOCK unless entry[:socket]
      return EFAULT if value == 0

      if level == SOL_SOCKET && name == SO_ERROR
        error = 0
        if entry[:connecting] && entry[:handle]
          Net.pump
          state = Net.state(entry[:handle])
          if state == STATE_ERROR
            error = -connect_errno(entry[:handle])
            entry[:connecting] = false
          elsif state == STATE_CONNECTED
            entry[:connecting] = false
          end
        end
        Syscall.poke32(value, error)
        Syscall.poke32(length_address, 4) if length_address != 0
        return 0
      end

      if level == SOL_SOCKET && name == SO_TYPE
        Syscall.poke32(value, entry[:datagram] ? SOCK_DGRAM : SOCK_STREAM)
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

    # [ip, port] in host order, from a struct sockaddr_in.
    def self.read_sockaddr(address)
      bytes = Syscall.read_bytes(address, SOCKADDR_IN_SIZE)
      ip = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7]
      [ip, (bytes[2] << 8) | bytes[3]]
    end

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
