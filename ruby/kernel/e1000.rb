# The network card, in Ruby.
#
# An Intel 82540EM -- what QEMU's "e1000" is. Its registers are memory mapped,
# and the low 4GB of this machine is identity mapped, so the address its BAR
# reports is the address peek32 and poke32 read and write. Nothing in this file
# needs C except the two port instructions PCI configuration space is defined
# in, and those are in pci.rb.
#
# The card is never allowed to raise an interrupt. kernel/idt.c installs the
# CPU's thirty-two exception vectors and nothing else, so a device interrupt
# would be delivered to a gate that does not exist -- and even with a gate,
# arriving while the mruby VM is servicing a syscall would re-enter a VM that
# is already running. So the interrupt mask stays at zero and the card is
# polled, which is what the serial port already does.
module Kernel
  module E1000
    VENDOR_INTEL   = 0x8086
    DEVICE_82540EM = 0x100E

    # Register offsets from the base address.
    CTRL   = 0x0000   # device control
    STATUS = 0x0008   # device status
    EERD   = 0x0014   # EEPROM read
    IMC    = 0x00D8   # interrupt mask clear
    RCTL   = 0x0100   # receive control
    TCTL   = 0x0400   # transmit control
    TIPG   = 0x0410   # transmit inter-packet gap
    RDBAL  = 0x2800   # receive descriptor base, low half
    RDBAH  = 0x2804
    RDLEN  = 0x2808   # receive ring length in bytes
    RDH    = 0x2810   # receive head, written by the card
    RDT    = 0x2818   # receive tail, written by this driver
    TDBAL  = 0x3800
    TDBAH  = 0x3804
    TDLEN  = 0x3808
    TDH    = 0x3810
    TDT    = 0x3818
    MTA    = 0x5200   # multicast table array, 128 entries
    RAL    = 0x5400   # receive address, low four bytes
    RAH    = 0x5404   # and the high two, plus the valid bit

    CTRL_SLU   = 0x0000_0040   # set link up
    CTRL_RESET = 0x0400_0000

    STATUS_LINK_UP    = 0x0000_0002
    STATUS_FULL_DUPLEX = 0x0000_0001

    RAH_ADDRESS_VALID = 0x8000_0000

    RCTL_ENABLE            = 0x0000_0002
    RCTL_BROADCAST_ACCEPT  = 0x0000_8000
    RCTL_STRIP_CRC         = 0x0400_0000
    # BSIZE 00 with BSEX 0 means 2048-byte buffers, which is the default and is
    # why it does not appear here: a frame is at most 1518 bytes.

    TCTL_ENABLE            = 0x0000_0002
    TCTL_PAD_SHORT_PACKETS = 0x0000_0008
    TCTL_COLLISION_THRESHOLD = 0x0000_00F0   # 15, the documented value
    TCTL_COLLISION_DISTANCE  = 0x0004_0000   # 64, likewise

    # 10, 8 and 6 in the three gap fields, as the manual specifies for copper.
    TIPG_DEFAULT = 10 | (8 << 10) | (6 << 20)

    # Sixteen descriptors each way. The ring length register counts bytes and
    # the card requires a multiple of 128, which 16 * 16 satisfies.
    DESCRIPTOR_SIZE  = 16
    RING_ENTRIES     = 16
    RING_BYTES       = DESCRIPTOR_SIZE * RING_ENTRIES
    BUFFER_SIZE      = 2048
    BUFFERS_BYTES    = BUFFER_SIZE * RING_ENTRIES

    # Receive descriptor: the address of the buffer, then a 32-bit word holding
    # the length, then a word beginning with the status byte.
    DESC_LENGTH = 8
    DESC_STATUS = 12

    STATUS_DESCRIPTOR_DONE = 0x01
    STATUS_END_OF_PACKET   = 0x02

    # Transmit descriptor command byte, which shares a word with the length.
    # Report status is what makes the card set descriptor-done, which is the
    # only way a polled driver can tell that a frame has left.
    CMD_END_OF_PACKET   = 0x01
    CMD_INSERT_CRC      = 0x02
    CMD_REPORT_STATUS   = 0x08

    # EEPROM read register. Write the word address and the start bit, wait for
    # done, and the word arrives in the top half.
    EERD_START = 0x0000_0001
    EERD_DONE  = 0x0000_0010
    EERD_ADDR_SHIFT = 8
    EERD_DATA_SHIFT = 16

    # The MAC lives in the first three EEPROM words, low byte of each first.
    EEPROM_MAC_WORD = 0

    # Held in a constant for the same reason FD::TABLE is: it has to survive
    # across syscalls, and a constant is unambiguously rooted for the life of
    # the VM.
    STATE = {}

    def self.base
      STATE[:base]
    end

    def self.present?
      !STATE[:base].nil?
    end

    def self.read(offset)
      Syscall.peek32(STATE[:base] + offset)
    end

    def self.write(offset, value)
      Syscall.poke32(STATE[:base] + offset, value)
    end

    # Finds the card, enables it and reads its address. Returns the MAC as an
    # array of six bytes, or nil if there is no card in the machine -- which is
    # a thing to report rather than a thing to fail on: the kernel is perfectly
    # usable without a network.
    def self.probe
      slot = PCI.find(VENDOR_INTEL, DEVICE_82540EM)
      return nil unless slot

      PCI.enable(slot)
      base = PCI.bar(slot, 0)
      return nil if base.nil? || base == 0

      STATE[:slot] = slot
      STATE[:base] = base

      # Before anything else, and before any register is trusted: no
      # interrupts. Reset does this too, but saying it here means it is true
      # even on a card some firmware has already started.
      write(IMC, 0xFFFF_FFFF)

      STATE[:mac] = read_mac
      return nil if STATE[:mac].nil?

      configure
      STATE[:mac]
    end

    # Brings the card up: its own address, the two descriptor rings, and the
    # receiver and transmitter enabled. After this the card is reading and
    # writing memory by itself, which is what bus mastering was enabled for.
    def self.configure
      write(CTRL, read(CTRL) | CTRL_SLU)

      # The card matches incoming frames against this address. Without it the
      # ARP reply -- which is unicast, unlike the request -- is dropped by the
      # card before the driver ever sees it.
      mac = STATE[:mac]
      write(RAL, mac[0] | (mac[1] << 8) | (mac[2] << 16) | (mac[3] << 24))
      write(RAH, mac[4] | (mac[5] << 8) | RAH_ADDRESS_VALID)

      # Nothing here joins a multicast group, and the table comes up
      # unspecified rather than empty.
      i = 0
      while i < 128
        write(MTA + i * 4, 0)
        i += 1
      end

      allocate_rings
      start_receiver
      start_transmitter
      STATE[:up] = true
    end

    # Descriptors and buffers, from the kernel's page allocator -- the same
    # free extents mmap is served from. There is no address translation to
    # arrange: the low 4GB is identity mapped, so the address handed back is the
    # address the card will use. On a machine with an IOMMU this is where the
    # mapping would go.
    def self.allocate_rings
      STATE[:rx_ring]    = Memory.allocate(RING_BYTES)
      STATE[:tx_ring]    = Memory.allocate(RING_BYTES)
      STATE[:rx_buffers] = Memory.allocate(BUFFERS_BYTES)
      STATE[:tx_buffers] = Memory.allocate(BUFFERS_BYTES)

      Syscall.memzero(STATE[:rx_ring], RING_BYTES)
      Syscall.memzero(STATE[:tx_ring], RING_BYTES)

      # Each receive descriptor points at its buffer. The card fills them in
      # order and the driver hands them back the same way.
      i = 0
      while i < RING_ENTRIES
        Syscall.poke64(STATE[:rx_ring] + i * DESCRIPTOR_SIZE,
                       STATE[:rx_buffers] + i * BUFFER_SIZE)
        i += 1
      end

      STATE[:rx_next] = 0
      STATE[:tx_next] = 0
    end

    def self.start_receiver
      ring = STATE[:rx_ring]
      write(RDBAL, ring & 0xFFFF_FFFF)
      write(RDBAH, ring >> 32)
      write(RDLEN, RING_BYTES)

      # Head at the first descriptor, tail at the last. The card owns
      # everything between them, so this hands it all but one.
      write(RDH, 0)
      write(RDT, RING_ENTRIES - 1)

      write(RCTL, RCTL_ENABLE | RCTL_BROADCAST_ACCEPT | RCTL_STRIP_CRC)
    end

    def self.start_transmitter
      ring = STATE[:tx_ring]
      write(TDBAL, ring & 0xFFFF_FFFF)
      write(TDBAH, ring >> 32)
      write(TDLEN, RING_BYTES)

      # Both at the first descriptor: the card owns nothing until a frame is
      # actually queued.
      write(TDH, 0)
      write(TDT, 0)

      write(TIPG, TIPG_DEFAULT)
      write(TCTL, TCTL_ENABLE | TCTL_PAD_SHORT_PACKETS |
                  TCTL_COLLISION_THRESHOLD | TCTL_COLLISION_DISTANCE)
    end

    def self.up?
      STATE[:up] == true
    end

    # ---------------------------------------------------------------- transmit
    #
    # The caller writes the frame into the buffer this returns and then says how
    # long it is. Two steps rather than one so that nothing is copied: the
    # bytes are built where the card will read them.
    def self.transmit_buffer
      STATE[:tx_buffers] + STATE[:tx_next] * BUFFER_SIZE
    end

    def self.transmit(length)
      return false unless up?

      slot = STATE[:tx_next]
      descriptor = STATE[:tx_ring] + slot * DESCRIPTOR_SIZE

      Syscall.poke64(descriptor, transmit_buffer)
      # Length, then an unused checksum offset, then the command byte: one
      # 32-bit write covers all three.
      command = CMD_END_OF_PACKET | CMD_INSERT_CRC | CMD_REPORT_STATUS
      Syscall.poke32(descriptor + DESC_LENGTH, length | (command << 24))
      Syscall.poke32(descriptor + DESC_STATUS, 0)

      STATE[:tx_next] = (slot + 1) % RING_ENTRIES
      write(TDT, STATE[:tx_next])

      # Wait for the card to say it has taken it. A polled driver has no other
      # way to know, and returning before then would let the next frame
      # overwrite this one's buffer.
      spins = 0
      until Syscall.peek32(descriptor + DESC_STATUS) & STATUS_DESCRIPTOR_DONE != 0
        spins += 1
        return false if spins > 1_000_000
        Syscall.idle
      end
      true
    end

    # ---------------------------------------------------------------- receive
    #
    # Yields the address and length of every frame the card has left in the
    # ring, then hands each descriptor back. A block rather than a return value
    # because the buffer belongs to the card again as soon as the descriptor is
    # returned, and the caller must be finished with it by then.
    def self.each_frame
      return 0 unless up?

      count = 0
      loop do
        slot = STATE[:rx_next]
        descriptor = STATE[:rx_ring] + slot * DESCRIPTOR_SIZE
        status = Syscall.peek32(descriptor + DESC_STATUS) & 0xFF
        break if status & STATUS_DESCRIPTOR_DONE == 0

        if status & STATUS_END_OF_PACKET != 0
          length = Syscall.peek32(descriptor + DESC_LENGTH) & 0xFFFF
          yield(STATE[:rx_buffers] + slot * BUFFER_SIZE, length)
          count += 1
        end

        # Hand it back: clear the status the card set, then move the tail to
        # this descriptor, which is what tells the card it may fill it again.
        Syscall.poke32(descriptor + DESC_STATUS, 0)
        STATE[:rx_next] = (slot + 1) % RING_ENTRIES
        write(RDT, slot)
      end
      count
    end

    def self.read_eeprom(word)
      write(EERD, (word << EERD_ADDR_SHIFT) | EERD_START)
      spins = 0
      until (value = read(EERD)) & EERD_DONE != 0
        spins += 1
        return nil if spins > 100_000
        Syscall.idle
      end
      (value >> EERD_DATA_SHIFT) & 0xFFFF
    end

    def self.read_mac
      bytes = []
      word = 0
      while word < 3
        value = read_eeprom(EEPROM_MAC_WORD + word)
        return nil if value.nil?
        bytes << (value & 0xFF)
        bytes << ((value >> 8) & 0xFF)
        word += 1
      end
      bytes
    end

    # sprintf is not in this build of mruby, and neither is String#rjust.
    def self.hex2(byte)
      digits = byte.to_s(16)
      digits.length < 2 ? "0" + digits : digits
    end

    def self.mac_string_of(mac)
      return "unknown" if mac.nil?

      text = ""
      i = 0
      while i < mac.length
        text = text + ":" unless i == 0
        text = text + hex2(mac[i])
        i += 1
      end
      text
    end

    def self.mac_string
      mac_string_of(STATE[:mac])
    end

    # What the card says about its own link. Reported at boot because "is there
    # a cable" is the first question asked when nothing arrives, and QEMU's
    # answer is immediate rather than negotiated.
    def self.link_up?
      return false unless present?
      read(STATUS) & STATUS_LINK_UP != 0
    end

    def self.report
      unless present?
        puts "e1000: no card"
        return
      end

      puts "e1000: base #{STATE[:base].to_s(16)} mac #{mac_string} " \
           "link #{link_up? ? "up" : "down"}"
    end
  end
end
