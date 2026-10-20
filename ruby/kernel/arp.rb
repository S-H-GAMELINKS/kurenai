# ARP, and the driver's own proof that it works.
#
# lwIP will do ARP for real traffic. This stays because it is the only check
# that covers the descriptor rings without a protocol stack above them: one
# frame out, one frame in, and the answer came from another machine. When HTTP
# stops working, the question "can the card still send and receive at all" has
# to be answerable without the thing that broke.
#
# Frames are built in the card's own transmit buffer and read out of its
# receive buffer, so nothing here copies. The bytes cross as an Array only
# where the kernel genuinely has to decide their values.
module Kernel
  module ARP
    ETHERTYPE_ARP = 0x0806

    HARDWARE_ETHERNET = 1
    PROTOCOL_IPV4     = 4
    PROTOCOL_IP       = 0x0800

    REQUEST = 1
    REPLY   = 2

    BROADCAST = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    # An ARP frame over Ethernet is 42 bytes and every field is fixed width, so
    # the offsets are stated rather than computed.
    FRAME_LENGTH  = 42
    OPERATION     = 20
    SENDER_MAC    = 22
    SENDER_IP     = 28
    TARGET_IP     = 38

    def self.request(sender_mac, sender_ip, target_ip)
      BROADCAST +
        sender_mac +
        [ETHERTYPE_ARP >> 8, ETHERTYPE_ARP & 0xFF] +
        [0, HARDWARE_ETHERNET] +
        [PROTOCOL_IP >> 8, PROTOCOL_IP & 0xFF] +
        [6, PROTOCOL_IPV4] +
        [0, REQUEST] +
        sender_mac + sender_ip +
        [0, 0, 0, 0, 0, 0] + target_ip
    end

    # Sends a request and waits for the answer, asking again every
    # RESEND_MS. Returns the MAC the target claims, or nil if nothing came
    # back in time.
    #
    # Once, within a second, was not enough: about one boot in twenty-five
    # nothing came back. Asking again every 200ms within the same second did
    # not help either, so it is not one lost frame -- for a while after the
    # card reports link up, nothing gets through at all. Why is not known;
    # it happens with the timer interrupt switched off too, so it predates
    # threads. DHCP, which starts right after and retries for seconds, never
    # noticed. Asking again for up to three seconds answered forty boots out
    # of forty.
    #
    # Frames that are not the reply being waited for are dropped rather than
    # queued. There is nothing yet to queue them for, and a driver check that
    # quietly depended on a queue would be testing the queue.
    RESEND_MS = 200

    def self.resolve(target_ip, timeout_ms)
      return nil unless E1000.up?

      sender_mac = E1000::STATE[:mac]
      sender_ip  = IPV4_ADDRESS
      frame = request(sender_mac, sender_ip, target_ip)

      deadline = Syscall.clock_millis + timeout_ms
      resend_at = 0
      answer = nil
      while answer.nil? && Syscall.clock_millis < deadline
        if Syscall.clock_millis >= resend_at
          Syscall.write_bytes(E1000.transmit_buffer, frame)
          return nil unless E1000.transmit(FRAME_LENGTH)
          resend_at = Syscall.clock_millis + RESEND_MS
        end
        E1000.each_frame do |address, length|
          next if answer
          next if length < FRAME_LENGTH
          next unless Syscall.peek32(address + 12) & 0xFFFF == 0x0608  # 0x0806, on the wire
          bytes = Syscall.read_bytes(address, FRAME_LENGTH)
          next unless bytes[OPERATION] == 0 && bytes[OPERATION + 1] == REPLY
          next unless bytes[SENDER_IP, 4] == target_ip
          answer = bytes[SENDER_MAC, 6]
        end
        Syscall.idle if answer.nil?
      end
      answer
    end

    # This machine's address, until DHCP replaces it. QEMU's user-mode network
    # hands out 10.0.2.15 and gateways through 10.0.2.2, so using them before
    # there is a DHCP client to ask is not a guess.
    IPV4_ADDRESS = [10, 0, 2, 15]
    GATEWAY      = [10, 0, 2, 2]

    def self.dotted(bytes)
      text = ""
      i = 0
      while i < bytes.length
        text = text + "." unless i == 0
        text = text + bytes[i].to_s
        i += 1
      end
      text
    end

    def self.report
      unless E1000.up?
        puts "arp: no card"
        return
      end

      mac = resolve(GATEWAY, 3000)
      if mac
        puts "arp: #{dotted(GATEWAY)} is at #{E1000.mac_string_of(mac)}"
      else
        puts "arp: #{dotted(GATEWAY)} did not answer"
      end
    end
  end
end
