# The date, from the CMOS clock.
#
# The TSC counts time since boot, and until now that was every clock there
# was: Time.now said 1970 and a few seconds. That stops being harmless the
# moment a certificate is checked, because a certificate is valid between two
# dates, and 1970 is between none of them.
#
# The PC's real-time clock is a chip from 1984 behind two I/O ports, and
# reading it is policy all the way down: whether it counts in BCD or binary,
# whether its hours are 12 or 24, which register holds the century, and how to
# avoid reading in the middle of an update. So all of that is here, and C only
# moves the bytes. The result is handed to kernel/timer.c once, as Unix time,
# and the wall clock runs on the TSC from then on.
#
# QEMU's clock is the host's, in UTC.
module Kernel
  module Clock
    SECONDS  = 0x00
    MINUTES  = 0x02
    HOURS    = 0x04
    DAY      = 0x07
    MONTH    = 0x08
    YEAR     = 0x09
    STATUS_A = 0x0A
    STATUS_B = 0x0B
    CENTURY  = 0x32   # where QEMU and most PCs keep it; ACPI's FADT would say

    UPDATING = 0x80   # status A: the chip is changing the registers
    BINARY   = 0x04   # status B: values are binary rather than BCD
    HOURS_24 = 0x02   # status B: hours run 0-23 rather than 1-12
    PM       = 0x80   # the hour's top bit, on a 12-hour clock

    # The registers, read twice until two readings agree: an update can start
    # between any two reads, and the status bit only says one is about to.
    def self.read_raw
      last = nil
      10.times do
        n = 0
        n += 1 while (Syscall.cmos_read(STATUS_A) & UPDATING) != 0 && n < 100_000
        now = [SECONDS, MINUTES, HOURS, DAY, MONTH, YEAR, CENTURY].map do |reg|
          Syscall.cmos_read(reg)
        end
        return now if now == last
        last = now
      end
      last
    end

    def self.bcd(value)
      (value >> 4) * 10 + (value & 0x0F)
    end

    # [year, month, day, hour, minute, second], in UTC.
    def self.read
      seconds, minutes, hours, day, month, year, century = read_raw
      status = Syscall.cmos_read(STATUS_B)

      pm = (hours & PM) != 0
      hours &= ~PM
      if (status & BINARY) == 0
        seconds = bcd(seconds)
        minutes = bcd(minutes)
        hours = bcd(hours)
        day = bcd(day)
        month = bcd(month)
        year = bcd(year)
        century = bcd(century)
      end
      hours = (hours % 12) + 12 if (status & HOURS_24) == 0 && pm
      hours = 0 if (status & HOURS_24) == 0 && !pm && hours == 12

      # A chip that keeps no century says 0 there; nothing this kernel runs
      # was written before 2000.
      century = 20 if century < 19 || century > 30
      [century * 100 + year, month, day, hours, minutes, seconds]
    end

    # Days since 1970-01-01 for a date in the proleptic Gregorian calendar,
    # from Howard Hinnant's days_from_civil.
    def self.days_from_civil(year, month, day)
      year -= 1 if month <= 2
      era = (year >= 0 ? year : year - 399) / 400
      year_of_era = year - era * 400
      shifted = month > 2 ? month - 3 : month + 9
      day_of_year = (153 * shifted + 2) / 5 + day - 1
      day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
      era * 146_097 + day_of_era - 719_468
    end

    def self.init
      year, month, day, hour, minute, second = read
      unix = days_from_civil(year, month, day) * 86_400 +
             hour * 3600 + minute * 60 + second
      Syscall.set_realtime(unix)
      puts "clock: #{year}-#{two(month)}-#{two(day)} " \
           "#{two(hour)}:#{two(minute)}:#{two(second)} UTC"
    end

    def self.two(n)
      n < 10 ? "0#{n}" : n.to_s
    end
  end
end
