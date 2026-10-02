# Pages: finding them, handing them out, and getting them back.
#
# C supplies three facts it cannot avoid knowing -- where the image ends, where
# the bootloader left its description of the machine, and how much of the
# address space boot.S mapped. Everything decided from them is here: how much
# RAM there is, which part of it is the arena, which pages a program gets, and
# what happens to them once it is done.
#
# The arena is kept as free extents, [start, length], in address order with
# neighbours merged. At boot it is one extent covering all of it, so a page
# that has never been used and a page given back through munmap come from the
# same place by the same route. musl's allocator unmaps large blocks when they
# are freed, and CRuby trims its aligned heap mappings by unmapping the ends;
# both come back here.
#
# A list of extents rather than a bitmap: 2GB of 4KB pages is half a million
# bits, which would not fit in the VM's pool, while the extents number in the
# tens.
module Kernel
  module Memory
    PAGE = 4096

    # The arena starts on a 2MB boundary past the image, which keeps it clear
    # of the kernel's own BSS however large that grows.
    ALIGN = 0x200000

    # Leave the last 2MB alone; nothing should be handed the very top.
    RESERVED_TOP = 0x200000

    # What to assume when the bootloader says nothing.
    DEFAULT_END = 0x20000000   # 512MB

    # Multiboot's information structure begins with flags, then the low and
    # high memory sizes in kilobytes. mem_upper is what is above 1MB.
    MB_FLAGS          = 0
    MB_MEM_UPPER      = 8
    MB_FLAG_MEMORY    = 0x01
    ONE_MB            = 0x100000

    # Set to true and rebuild to print every allocation and release.
    TRACE = false

    # Held in a constant so it is rooted for the life of the VM, like the
    # descriptor table. Replaced in place, never reassigned.
    FREE = []

    # [start, end) of the arena, set once by init.
    ARENA = []

    # Asks the machine how much memory there is rather than assuming. The
    # amount matters: CRuby's garbage collector reserves its heap in one
    # mapping, and this kernel cannot reserve address space without also
    # committing the memory behind it.
    def self.init
      image_end, info, mapped_limit = Syscall.memory_layout

      start = (image_end + ALIGN - 1) & ~(ALIGN - 1)
      finish = DEFAULT_END

      if info != 0 && (Syscall.peek32(info + MB_FLAGS) & MB_FLAG_MEMORY) != 0
        top = ONE_MB + Syscall.peek32(info + MB_MEM_UPPER) * 1024
        top = mapped_limit if top > mapped_limit
        finish = top - RESERVED_TOP if top > RESERVED_TOP
      end

      ARENA.replace([start, finish])
      FREE.replace(finish > start ? [[start, finish - start]] : [])
    end

    def self.align(length)
      (length + PAGE - 1) & ~(PAGE - 1)
    end

    # Returns an address, or nil when no extent is large enough.
    def self.allocate(length)
      size = align(length)
      return nil if size <= 0

      i = 0
      while i < FREE.length
        start, available = FREE[i]
        if available >= size
          if available == size
            FREE.delete_at(i)
          else
            FREE[i] = [start + size, available - size]
          end
          # mmap promises zeroed pages, and musl's allocator relies on it.
          # Pages given back have been used, and RAM that never was is not
          # promised to be zero either.
          Syscall.memzero(start, size)
          @allocated = (@allocated || 0) + size
          puts "mmap #{size} at #{start}" if TRACE
          return start
        end
        i += 1
      end

      # Running out is not a condition the caller can do anything about, so
      # say so here, where the numbers are.
      puts "memory: cannot serve #{size} bytes, #{free_bytes} free " \
           "in #{FREE.length} extents"
      nil
    end

    # Takes back [address, address + length). Only the part inside the arena
    # is the arena's: a file mapping is an address in the image, and putting
    # that on the free list would hand the kernel's own memory to the next
    # mmap. Unmapping what is not mapped is not an error on Linux, so the rest
    # is ignored rather than refused.
    #
    # Extents are merged as a union, so a range given back twice is only free
    # once.
    def self.release(address, length)
      low, high = ARENA
      start = address
      finish = address + align(length)
      start = low if start < low
      finish = high if finish > high
      return if finish <= start

      @released = (@released || 0) + (finish - start)
      puts "munmap #{finish - start} at #{start}" if TRACE

      merged = []
      placed = false
      FREE.each do |s, l|
        e = s + l
        if e < start
          merged.push([s, l])
        elsif s > finish
          unless placed
            merged.push([start, finish - start])
            placed = true
          end
          merged.push([s, l])
        else
          # Overlapping or touching: absorb it.
          start = s if s < start
          finish = e if e > finish
        end
      end
      merged.push([start, finish - start]) unless placed
      FREE.replace(merged)
    end

    def self.free_bytes
      total = 0
      FREE.each { |_, l| total += l }
      total
    end

    def self.report
      puts "memory: #{(@allocated || 0) / 1024} KB mapped, " \
           "#{(@released || 0) / 1024} KB unmapped, " \
           "#{free_bytes / 1024} KB free in #{FREE.length} extents"
    end
  end
end
