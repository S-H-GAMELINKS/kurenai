# Waiting, for everything that can be waited on.
#
# There were two of these and they disagreed. sys_poll knew about the console
# and nothing else -- a pipe or a socket handed to it got revents zero forever
# -- and select did not exist at all. CRuby needs both: poll is what
# rb_io_wait_readable uses after a read returns EAGAIN, and select(2) is what
# IO.select lowers to, which is how a server watches several listeners at once.
#
# So readiness is decided in one place for every kind of descriptor, and the
# four syscalls differ only in how they say what they want and how they report
# what they got.
#
# Nothing in here waits. A dispatch that does not return holds the VM, and
# there is one VM for every thread the kernel runs: one caller sitting in a
# poll would stop every other caller's write. So each dispatch looks once, and
# if nothing is ready and the deadline has not passed it answers
# Syscall::WAIT_AGAIN, which never reaches CRuby. kernel/bridge.c takes that
# to mean "wait for the next tick and ask me again", leaves the VM, and repeats
# the same call with the same arguments.
#
# The deadline has to survive that. Each retry is a fresh dispatch that would
# compute "now plus the timeout" again and never expire, so the deadline is
# computed once and held by the bridge for the length of the call -- that is
# what Syscall.held_deadline is for.
module Kernel
  module Poll
    POLLIN   = 0x001
    POLLPRI  = 0x002
    POLLOUT  = 0x004
    POLLERR  = 0x008
    POLLHUP  = 0x010
    POLLNVAL = 0x020

    # struct pollfd is { int fd; short events; short revents; }
    POLLFD_SIZE   = 8
    POLLFD_EVENTS = 4
    POLLFD_REVENTS = 6

    NO_DEADLINE = -1

    # What a descriptor could do right now, masked to what was asked about.
    # POLLERR, POLLHUP and POLLNVAL are reported whether or not they were asked
    # for, which is what poll(2) does.
    def self.revents(fd, events)
      if FD.console?(fd)
        ready = 0
        ready |= POLLIN if fd == FD::CONSOLE_IN && Syscall.serial_ready?
        ready |= POLLOUT unless fd == FD::CONSOLE_IN
        return ready & (events | POLLERR | POLLHUP | POLLNVAL)
      end

      entry = FD.entry(fd)
      return POLLNVAL if entry.nil?

      ready = 0
      if entry[:socket]
        ready |= socket_revents(entry)
      elsif entry[:pipe]
        if entry[:writable]
          ready |= POLLOUT
        else
          ready |= POLLIN unless entry[:buffer].empty?
        end
      else
        # A file in the image is always ready, both ways; writing fails later.
        ready |= POLLIN | POLLOUT
      end

      ready & (events | POLLERR | POLLHUP | POLLNVAL)
    end

    # POLLHUP matters more than it looks. CRuby folds it in with POLLIN when it
    # decides whether a descriptor is readable, so a connection whose peer has
    # gone has to report both -- otherwise the read that would return zero is
    # never attempted and end of file never arrives.
    def self.socket_revents(entry)
      handle = entry[:handle]

      # A datagram socket can always be sent on, and is readable once a
      # datagram is waiting. Before it has a handle nothing can have arrived.
      if entry[:datagram]
        ready = POLLOUT
        ready |= POLLIN if handle && Net.udp_readable?(handle)
        return ready
      end

      return POLLHUP if handle.nil? && !entry[:listening]
      return 0 if handle.nil?

      if entry[:connecting]
        ready = Sockets.connect_revents(entry)
        return ready if ready
      end

      ready = 0
      if entry[:listening]
        # Draining here rather than asking is what lets a connection be
        # reported without being consumed: it moves out of lwIP's single
        # accepted slot and into this descriptor's queue, where accept4 will
        # find it. The queue is made at listen time, so a poll that finds
        # nothing allocates nothing.
        ready |= POLLIN if Sockets.drain_accepts(entry) > 0
      else
        ready |= POLLIN if entry[:eof] || Net.readable?(handle)
        if Net.closed?(handle)
          ready |= POLLIN | POLLHUP
        elsif Net.sendable(handle) > 0
          ready |= POLLOUT
        end
      end
      ready
    end

    # One look. Returns what the block found ready, 0 once the deadline has
    # passed, or Syscall::WAIT_AGAIN to be asked again. deadline is in
    # milliseconds since boot, or nil to wait indefinitely.
    def self.wait(deadline)
      # Before looking, so that a poll with a zero timeout still sees whatever
      # has arrived.
      Net.pump if E1000.up?

      ready = yield
      return ready if ready > 0

      held = Syscall.held_deadline(deadline || NO_DEADLINE)
      return 0 if held != NO_DEADLINE && Syscall.clock_millis >= held

      Syscall::WAIT_AGAIN
    end

    # ---------------------------------------------------------------- poll

    def self.poll(fds, nfds, timeout_ms)
      deadline = timeout_ms < 0 ? nil : Syscall.clock_millis + timeout_ms

      wait(deadline) do
        count = 0
        i = 0
        while i < nfds
          entry = fds + i * POLLFD_SIZE
          fd = Syscall.peek32(entry)
          if fd < 0
            Syscall.poke16(entry + POLLFD_REVENTS, 0)
          else
            events = Syscall.peek32(entry + POLLFD_EVENTS) & 0xFFFF
            ready = revents(fd, events)
            Syscall.poke16(entry + POLLFD_REVENTS, ready)
            count += 1 if ready != 0
          end
          i += 1
        end
        count
      end
    end

    # ---------------------------------------------------------------- select
    #
    # fd_set is a bitmap of unsigned longs, and CRuby always allocates at least
    # 128 bytes of it. It is read and written 32 bits at a time rather than 64:
    # FD::LIMIT is 64, so the top descriptor would need 1 << 63, which does not
    # fit in the mruby integer this arithmetic is done in.
    def self.select(nfds, readfds, writefds, exceptfds, deadline)
      return -22 if nfds < 0   # EINVAL
      limit = nfds > FD::LIMIT ? FD::LIMIT : nfds

      want_r_lo = readfds == 0 ? 0 : Syscall.peek32(readfds)
      want_r_hi = readfds == 0 ? 0 : Syscall.peek32(readfds + 4)
      want_w_lo = writefds == 0 ? 0 : Syscall.peek32(writefds)
      want_w_hi = writefds == 0 ? 0 : Syscall.peek32(writefds + 4)
      want_e_lo = exceptfds == 0 ? 0 : Syscall.peek32(exceptfds)
      want_e_hi = exceptfds == 0 ? 0 : Syscall.peek32(exceptfds + 4)

      got_r_lo = 0; got_r_hi = 0
      got_w_lo = 0; got_w_hi = 0
      got_e_lo = 0; got_e_hi = 0

      ready = wait(deadline) do
        got_r_lo = 0; got_r_hi = 0
        got_w_lo = 0; got_w_hi = 0
        got_e_lo = 0; got_e_hi = 0
        hits = 0

        fd = 0
        while fd < limit
          high = fd >= 32
          bit = 1 << (fd & 31)
          asked_read  = ((high ? want_r_hi : want_r_lo) & bit) != 0
          asked_write = ((high ? want_w_hi : want_w_lo) & bit) != 0
          asked_error = ((high ? want_e_hi : want_e_lo) & bit) != 0

          if asked_read || asked_write || asked_error
            events = 0
            events |= POLLIN  if asked_read
            events |= POLLOUT if asked_write
            events |= POLLPRI if asked_error
            got = revents(fd, events)

            if asked_read && (got & (POLLIN | POLLHUP | POLLERR)) != 0
              high ? got_r_hi |= bit : got_r_lo |= bit
              hits += 1
            end
            if asked_write && (got & (POLLOUT | POLLERR)) != 0
              high ? got_w_hi |= bit : got_w_lo |= bit
              hits += 1
            end
            if asked_error && (got & POLLPRI) != 0
              high ? got_e_hi |= bit : got_e_lo |= bit
              hits += 1
            end
          end
          fd += 1
        end
        hits
      end

      # Not finished: the sets are left exactly as they were, because the
      # same call is coming back with the same pointers.
      return ready if ready == Syscall::WAIT_AGAIN

      write_set(readfds, nfds, got_r_lo, got_r_hi)
      write_set(writefds, nfds, got_w_lo, got_w_hi)
      write_set(exceptfds, nfds, got_e_lo, got_e_hi)
      ready
    end

    # Writes the answer and zeroes the rest, out to as many words as the caller
    # said it was asking about. On a timeout everything is zero, which is what
    # says "nothing was ready" rather than "the sets are unchanged".
    def self.write_set(address, nfds, low, high)
      return if address == 0

      words = (nfds + 31) / 32
      i = 0
      while i < words
        value = i == 0 ? low : (i == 1 ? high : 0)
        Syscall.poke32(address + i * 4, value)
        i += 1
      end
    end
  end
end
