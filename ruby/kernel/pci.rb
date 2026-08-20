# PCI configuration space, in Ruby.
#
# A device driver is mostly a conversation with registers, and registers are
# just addresses -- which is why this can be Ruby at all. The low 4GB is
# identity mapped, so a card's memory-mapped registers live at exactly the
# physical address its BAR reports, and peek32/poke32 reach them directly.
#
# The configuration space is the one part that is not memory. It is reached
# through two ports: write the address of the register you want to 0xCF8, then
# read or write it at 0xCFC. That is what inl and outl are for, and it is the
# whole reason this file needs anything from C.
#
# Only bus 0 is scanned, and only function 0 of each device. QEMU's machine
# puts everything on one bus and the NIC is not multifunction, so walking
# further would be inventing generality for a machine that does not have it.
module Kernel
  module PCI
    CONFIG_ADDRESS = 0xCF8
    CONFIG_DATA    = 0xCFC

    # Offsets in the 256-byte configuration space of a device.
    VENDOR_ID   = 0x00   # and device id in the high half
    COMMAND     = 0x04   # and status in the high half
    CLASS_CODE  = 0x08
    BAR0        = 0x10

    # Command register bits. Memory space has to be enabled before the BAR
    # answers, and bus mastering before the card may touch RAM on its own --
    # which is the whole point of a descriptor ring.
    COMMAND_IO_SPACE     = 0x0001
    COMMAND_MEMORY_SPACE = 0x0002
    COMMAND_BUS_MASTER   = 0x0004

    NO_DEVICE = 0xFFFF

    def self.address(bus, device, function, offset)
      0x8000_0000 |
        (bus << 16) | (device << 11) | (function << 8) | (offset & 0xFC)
    end

    def self.read32(bus, device, function, offset)
      Syscall.outl(CONFIG_ADDRESS, address(bus, device, function, offset))
      Syscall.inl(CONFIG_DATA)
    end

    def self.write32(bus, device, function, offset, value)
      Syscall.outl(CONFIG_ADDRESS, address(bus, device, function, offset))
      Syscall.outl(CONFIG_DATA, value)
    end

    # Returns [bus, device, function] for the first match, or nil. Vendor and
    # device ids share one register, vendor in the low half.
    def self.find(vendor_id, device_id)
      device = 0
      while device < 32
        identity = read32(0, device, 0, VENDOR_ID)
        vendor = identity & 0xFFFF
        unless vendor == NO_DEVICE || vendor == 0
          if vendor == vendor_id && (identity >> 16) == device_id
            return [0, device, 0]
          end
        end
        device += 1
      end
      nil
    end

    # A 32-bit memory BAR. The low four bits describe the BAR rather than
    # belonging to the address, so they are masked off.
    def self.bar(slot, index)
      value = read32(slot[0], slot[1], slot[2], BAR0 + index * 4)
      return nil if (value & 1) == 1        # an I/O BAR, not memory
      value & 0xFFFF_FFF0
    end

    # Lets the card answer on its BAR and read and write memory by itself.
    def self.enable(slot)
      command = read32(slot[0], slot[1], slot[2], COMMAND) & 0xFFFF
      command |= COMMAND_MEMORY_SPACE | COMMAND_BUS_MASTER
      write32(slot[0], slot[1], slot[2], COMMAND, command)
      command
    end
  end
end
