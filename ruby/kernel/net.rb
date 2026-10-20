# The network, from the Ruby side.
#
# lwIP is C and the card is Ruby, and this is where they meet. Neither knows
# about the other: lwIP leaves frames in a queue and takes them from a buffer,
# the driver drains the queue and fills the buffer, and this decides when.
#
# "When" is the interesting part. There is no interrupt to drive any of it --
# kernel/idt.c installs the CPU's exception vectors and nothing else -- so the
# network advances only while pump is being called, and pump is called from the
# waiting loops in the syscall dispatcher. A packet that arrives while CRuby is
# computing sits in the card's ring until the next syscall waits for something.
# For a server that is exactly when it matters, and it is a real property of
# this kernel rather than an implementation detail.
module Kernel
  module Net
    def self.up(timeout_ms)
      return false unless E1000.up?

      # The MAC packed most significant byte first, which is the order it is
      # written and read in.
      mac = E1000::STATE[:mac]
      packed = 0
      i = 0
      while i < 6
        packed = (packed << 8) | mac[i]
        i += 1
      end

      return false unless Syscall.net_up(packed)

      # DHCP is a conversation, so it needs pumping to happen. QEMU's
      # user-mode network answers immediately; the timeout is for the case
      # where nothing is listening at all.
      deadline = Syscall.clock_millis + timeout_ms
      until Syscall.net_bound?
        return false if Syscall.clock_millis >= deadline
        pump
        Syscall.idle
      end
      true
    end

    # One turn of the crank: everything the card has received into lwIP,
    # everything lwIP wants to send onto the card, and lwIP's timers.
    #
    # Allocates nothing. That is a requirement rather than an economy: this runs
    # inside a single Kernel::Syscall.dispatch, and kernel/bridge.c only
    # restores the mruby GC arena when that dispatch returns -- so an object
    # created here would live for as long as the wait does, which for a server
    # waiting on a connection is unbounded.
    def self.pump
      E1000.each_frame do |address, length|
        Syscall.net_input(address, length)
      end

      # lwIP queues frames rather than sending them, so this drains the queue
      # into the card's transmit buffer. One copy, into the place the card
      # reads from.
      loop do
        length = Syscall.net_tx_take(E1000.transmit_buffer)
        break if length == 0
        E1000.transmit(length)
      end

      Syscall.net_timeouts
      nil
    end

    def self.bound?
      Syscall.net_bound?
    end

    # ---------------------------------------------------------------- sockets
    #
    # picoruby-socket's port layer, one call away. These are thin on purpose:
    # the socket policy -- descriptors, errno, what a read of a closed
    # connection means -- belongs in the syscall layer, and this is the
    # mechanism it will be written against.
    #
    # Handles are pointers, carried as Integers. Nothing dereferences them on
    # this side.
    WOULD_BLOCK = -2

    def self.listen(port, backlog)
      Syscall.socket_listen(port, backlog)
    end

    def self.accept(server)
      Syscall.socket_accept(server)
    end

    # The payload never becomes a Ruby object: lwIP copies it straight to the
    # address named here, which for a read syscall is CRuby's own buffer.
    def self.recv(socket, address, length)
      Syscall.socket_recv(socket, address, length)
    end

    def self.send(socket, address, length)
      Syscall.socket_send(socket, address, length)
    end

    # How much lwIP will take right now. The write path needs it to size a
    # partial write, and poll needs it to answer whether a socket is writable.
    def self.sendable(socket)
      Syscall.socket_sendable(socket)
    end

    def self.peer_ip(socket)
      Syscall.socket_peer_ip(socket)
    end

    def self.peer_port(socket)
      Syscall.socket_peer_port(socket)
    end

    def self.local_ip(socket)
      Syscall.socket_local_ip(socket)
    end

    def self.local_port(socket)
      Syscall.socket_local_port(socket)
    end

    def self.readable?(socket)
      Syscall.socket_readable?(socket)
    end

    def self.closed?(socket)
      Syscall.socket_closed?(socket)
    end

    def self.close(socket)
      Syscall.socket_close(socket)
    end

    def self.close_server(server)
      Syscall.socket_close_server(server)
    end

    # An outgoing connection, started and not waited for. nil when lwIP would
    # not even send the SYN.
    def self.connect(ip, port)
      Syscall.socket_connect(ip, port)
    end

    # picoruby-socket's SOCKET_STATE_* for the connection, and the err_t lwIP
    # gave when it failed.
    def self.state(socket)
      Syscall.socket_state(socket)
    end

    def self.error(socket)
      Syscall.socket_error(socket)
    end

    # ---------------------------------------------------------------- datagrams
    #
    # kernel/net.c's datagram sockets, which keep each datagram whole with its
    # sender. Handles are pointers, as above.

    def self.udp_open
      Syscall.udp_open
    end

    def self.udp_bind(socket, port)
      Syscall.udp_bind(socket, port)
    end

    def self.udp_sendto(socket, address, length, ip, port)
      Syscall.udp_sendto(socket, address, length, ip, port)
    end

    # The oldest datagram, straight into the caller's buffer: its length, or
    # WOULD_BLOCK when none has arrived. udp_sender_ip and udp_sender_port then
    # say who sent it.
    def self.udp_recv(socket, address, length)
      Syscall.udp_recv(socket, address, length)
    end

    def self.udp_sender_ip(socket)
      Syscall.udp_sender_ip(socket)
    end

    def self.udp_sender_port(socket)
      Syscall.udp_sender_port(socket)
    end

    def self.udp_readable?(socket)
      Syscall.udp_readable?(socket)
    end

    def self.udp_local_port(socket)
      Syscall.udp_local_port(socket)
    end

    def self.udp_close(socket)
      Syscall.udp_close(socket)
    end

    def self.dotted(address)
      "#{(address >> 24) & 0xFF}.#{(address >> 16) & 0xFF}." \
        "#{(address >> 8) & 0xFF}.#{address & 0xFF}"
    end

    # A netmask is more usefully read as a prefix length.
    def self.prefix_length(netmask)
      bits = 0
      i = 31
      while i >= 0
        break if netmask & (1 << i) == 0
        bits += 1
        i -= 1
      end
      bits
    end

    # Proof that the socket layer underneath is wired up, without waiting for
    # anyone to connect. Creating a listener means a pcb was allocated, bound
    # and put into listen; accept returning nil means the accept callback is
    # installed and has simply not fired. Both are things that would otherwise
    # only be discovered once CRuby was on top of them.
    def self.listener_check(port)
      server = listen(port, 1)
      return "failed" if server.nil?

      pump
      pending = accept(server)
      close(pending) if pending
      close_server(server)
      pending ? "one waiting" : "idle"
    end

    def self.report
      unless E1000.up?
        puts "net: no card"
        return
      end

      unless bound?
        puts "net: no address"
        return
      end

      # A transmit queue that overflows silently looks exactly like a network
      # that is merely slow, so it is only ever mentioned when it happened.
      dropped = Syscall.net_tx_dropped
      note = dropped > 0 ? ", #{dropped} frames dropped" : ""

      puts "net: #{dotted(Syscall.net_address)}/" \
           "#{prefix_length(Syscall.net_netmask)} " \
           "gw #{dotted(Syscall.net_gateway)} up#{note}"
      puts "net: tcp listener #{listener_check(80)}"
    end
  end
end
