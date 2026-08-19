# The terminal driver.
#
# There is no terminal. There is a serial port, and a program on the other end
# of it that behaves like one. Everything between those two facts -- when a
# read returns, whether what was typed is echoed back, what Return means -- is
# decided here, in Ruby, because none of it is a property of the hardware.
#
# This is the part of a kernel that a line editor actually talks to. Reline
# turns echo off and canonical mode off so it can draw the line itself, asks
# for one byte at a time with a timeout so it can tell an escape sequence from
# a lone Escape, and asks how wide the screen is. All of that arrives here as
# ioctl, and all of it is answered from the state below.
module Kernel
  module TTY
    # struct termios as the Linux kernel lays it out for TCGETS on x86_64.
    # Note this is the kernel's layout, not the one in libc's headers: the
    # kernel's c_cc has 19 entries and no speed fields, and the struct ends
    # after it.
    IFLAG  = 0
    OFLAG  = 4
    CFLAG  = 8
    LFLAG  = 12
    LINE   = 16
    CC     = 17
    NCCS   = 19
    SIZE   = CC + NCCS   # 36

    # c_cc indices.
    VINTR = 0; VQUIT = 1; VERASE = 2; VKILL = 3; VEOF = 4
    VTIME = 5; VMIN = 6

    # c_iflag
    ICRNL = 0x0100
    IXON  = 0x0400

    # c_oflag
    OPOST = 0x0001
    ONLCR = 0x0004

    # c_lflag
    ISIG   = 0x0001
    ICANON = 0x0002
    ECHO   = 0x0008
    IEXTEN = 0x8000

    # c_cflag: 8 bits, read and write enabled, 38400 baud. Nothing here can
    # change the line speed, but something will ask.
    CS8    = 0x0030
    CREAD  = 0x0080
    B38400 = 0x000F

    # The state a terminal starts in: canonical, echoing, signals enabled.
    # This is what a program sees before a line editor takes over.
    STATE = {
      iflag: ICRNL | IXON,
      oflag: OPOST | ONLCR,
      cflag: CS8 | CREAD | B38400,
      lflag: ISIG | ICANON | ECHO | IEXTEN,
      line: 0,
      cc: [3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0]
    }

    # Nothing can ask the far end how large it is, so this is what it is told.
    # 80x24 is the size a terminal is when nobody knows.
    WINSIZE = { rows: 24, columns: 80 }

    def self.canonical?
      (STATE[:lflag] & ICANON) != 0
    end

    def self.echo?
      (STATE[:lflag] & ECHO) != 0
    end

    def self.translate_cr?
      (STATE[:iflag] & ICRNL) != 0
    end

    # In raw mode these say how long a read waits: VMIN bytes, or VTIME tenths
    # of a second, whichever comes first. Reline asks for min 0, time 0, which
    # means "whatever is there, do not wait".
    def self.min_bytes
      STATE[:cc][VMIN]
    end

    def self.time_tenths
      STATE[:cc][VTIME]
    end

    # ---------------------------------------------------------------- ioctl

    def self.get_termios(address)
      bytes = Array.new(SIZE, 0)
      put_u32(bytes, IFLAG, STATE[:iflag])
      put_u32(bytes, OFLAG, STATE[:oflag])
      put_u32(bytes, CFLAG, STATE[:cflag])
      put_u32(bytes, LFLAG, STATE[:lflag])
      bytes[LINE] = STATE[:line]
      NCCS.times { |i| bytes[CC + i] = STATE[:cc][i] || 0 }
      Syscall.write_bytes(address, bytes)
      0
    end

    def self.set_termios(address)
      bytes = Syscall.read_bytes(address, SIZE)
      STATE[:iflag] = get_u32(bytes, IFLAG)
      STATE[:oflag] = get_u32(bytes, OFLAG)
      STATE[:cflag] = get_u32(bytes, CFLAG)
      STATE[:lflag] = get_u32(bytes, LFLAG)
      STATE[:line] = bytes[LINE]
      NCCS.times { |i| STATE[:cc][i] = bytes[CC + i] }
      0
    end

    # struct winsize is four unsigned shorts: rows, columns, and a pixel size
    # nothing here has.
    def self.get_winsize(address)
      Syscall.write_bytes(address, [
        WINSIZE[:rows] & 0xff, (WINSIZE[:rows] >> 8) & 0xff,
        WINSIZE[:columns] & 0xff, (WINSIZE[:columns] >> 8) & 0xff,
        0, 0, 0, 0
      ])
      0
    end

    def self.set_winsize(address)
      bytes = Syscall.read_bytes(address, 8)
      WINSIZE[:rows] = bytes[0] | (bytes[1] << 8)
      WINSIZE[:columns] = bytes[2] | (bytes[3] << 8)
      0
    end

    # ---------------------------------------------------------------- helpers

    def self.get_u32(bytes, offset)
      bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24)
    end

    def self.put_u32(bytes, offset, value)
      bytes[offset] = value & 0xff
      bytes[offset + 1] = (value >> 8) & 0xff
      bytes[offset + 2] = (value >> 16) & 0xff
      bytes[offset + 3] = (value >> 24) & 0xff
    end
  end
end
