# Pages, and getting them back.
#
# The C arena only moves forward: it hands out pages above the kernel image and
# has no way to take any back. That half stays in C, because it is the machine
# -- what RAM exists and where. Deciding what happens to a page once a program
# is done with it is policy, and lives here.
#
# Pages given back through munmap are kept as free extents, [start, length],
# in address order with neighbours merged. An anonymous mmap takes from them
# first and only reaches the arena when nothing here is large enough. musl's
# allocator unmaps large blocks when they are freed, and CRuby trims its
# aligned heap mappings by unmapping the ends, so without this every one of
# those was memory gone for the life of the system.
#
# A list of extents rather than a bitmap: 2GB of 4KB pages is half a million
# bits, which would not fit in the VM's pool, while the extents number in the
# tens.
module Kernel
  module Memory
    PAGE = 4096

    # Held in a constant so it is rooted for the life of the VM, like the
    # descriptor table. Replaced in place, never reassigned.
    FREE = []

    def self.align(length)
      (length + PAGE - 1) & ~(PAGE - 1)
    end

    # Returns an address, or nil when neither the free extents nor the arena
    # can serve the request.
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
          # mmap promises zeroed pages, and these have been used. The arena's
          # pages are zeroed by the C side when they are first handed out.
          Syscall.memzero(start, size)
          @reused = (@reused || 0) + size
          return start
        end
        i += 1
      end

      page = Syscall.alloc_pages(size)
      page == 0 ? nil : page
    end

    # Takes back [address, address + length). Only the part inside the arena
    # that has been handed out is the arena's: a file mapping is an address in
    # the image, and putting that on the free list would hand the kernel's own
    # memory to the next mmap. Unmapping what is not mapped is not an error on
    # Linux, so the rest is ignored rather than refused.
    #
    # Extents are merged as a union, so a range given back twice is only free
    # once.
    def self.release(address, length)
      low, high = Syscall.arena_range
      start = address
      finish = address + align(length)
      start = low if start < low
      finish = high if finish > high
      return if finish <= start

      @released = (@released || 0) + (finish - start)

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
      puts "memory: #{(@released || 0) / 1024} KB unmapped, " \
           "#{(@reused || 0) / 1024} KB reused, " \
           "#{free_bytes / 1024} KB free in #{FREE.length} extents"
    end
  end
end
