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

    CTRL_SLU   = 0x0000_0040   # set link up
    CTRL_RESET = 0x0400_0000

    STATUS_LINK_UP    = 0x0000_0002
    STATUS_FULL_DUPLEX = 0x0000_0001

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
      STATE[:mac]
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

    def self.mac_string
      mac = STATE[:mac]
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
