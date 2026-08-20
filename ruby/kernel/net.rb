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
    end
  end
end
