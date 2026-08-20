# Stands in for the terminal at the far end of the serial port.
#
# Reline drives a real terminal: it asks where the cursor is with an escape
# sequence and waits for the answer. A pipe cannot answer, so a test that pipes
# input in hangs at the first prompt, and TERM=dumb -- which avoids the
# question -- tests the path that does not use the terminal at all.
#
# So this plays the terminal. It relays input, records output, and answers the
# one question Reline actually needs answered. It is not an emulator: it tracks
# no screen and interprets nothing else.
#
#   ruby terminal_driver.rb --qemu QEMU --kernel ELF --log FILE
#                           --input FILE [--seconds N] [--until PATTERN]

require "optparse"

options = { seconds: 60 }
OptionParser.new do |o|
  o.on("--qemu PATH")    { |v| options[:qemu] = v }
  o.on("--kernel PATH")  { |v| options[:kernel] = v }
  o.on("--log PATH")     { |v| options[:log] = v }
  o.on("--input PATH")   { |v| options[:input] = v }
  o.on("--seconds N")    { |v| options[:seconds] = v.to_i }
  o.on("--until PATTERN"){ |v| options[:until] = v }
  # The kernel boots into its web server and stays there. Anything on the
  # console stops it, which is how irb is reached at all -- so a test that wants
  # irb has to knock first.
  o.on("--wake PATTERN")  { |v| options[:wake] = v }
end.parse!

%i[qemu kernel log input].each do |key|
  abort "terminal_driver: --#{key} is required" unless options[key]
end

script = File.read(options[:input]).lines
transcript = +""
deadline = Time.now + options[:seconds]

# The cursor position Reline is told. Nothing here tracks a screen, and the
# answer only has to be somewhere sane: Reline uses it to learn which column
# the prompt starts in.
CURSOR_REPORT = "\e[1;1R"
CURSOR_QUERY = "\e[6n"

# The network card is spelled out here as well as in the run target and in
# cmake/verify/boot_serial.cmake, the same way -m 2048 is: each way of starting
# this kernel builds its own command line, and a launcher that quietly differs
# from the others is worse than the repetition.
IO.popen([options[:qemu],
          "-kernel", options[:kernel],
          "-m", "2048",
          "-serial", "stdio",
          "-display", "none",
          "-no-reboot",
          "-netdev", "user,id=net0",
          "-device", "e1000,netdev=net0,mac=52:54:00:12:34:56"], "r+") do |qemu|
  answered = 0
  sent = 0
  prompt_seen = false
  woken = options[:wake].nil?

  begin
    while Time.now < deadline
      ready = IO.select([qemu], nil, nil, 0.2)
      if ready
        begin
          chunk = qemu.read_nonblock(4096)
        rescue EOFError
          break
        end
        transcript << chunk
        print chunk
        $stdout.flush
      end

      # Answer every cursor query that has appeared and not been answered.
      queries = transcript.scan(CURSOR_QUERY).length
      while answered < queries
        qemu.write(CURSOR_REPORT)
        qemu.flush
        answered += 1
        $answered_count = answered
      end

      # Knock once, when the kernel says it is serving. Until then there is no
      # prompt to wait for: it is in an accept loop, and the only thing that
      # ends one is input.
      if !woken && transcript.match?(Regexp.new(options[:wake]))
        qemu.write("\n")
        qemu.flush
        woken = true
      end

      # Feed the script once irb is up, one line at a time so each is read as
      # its own line rather than arriving as one burst.
      prompt_seen ||= transcript.include?("irb(main):001")
      if prompt_seen && sent < script.length && (queries == answered)
        qemu.write(script[sent])
        qemu.flush
        sent += 1
        $sent_count = sent
        sleep 0.4
      end

      break if options[:until] && transcript.match?(Regexp.new(options[:until]))
    end
  rescue Errno::EIO, Errno::EPIPE
    # QEMU went away; whatever was recorded is the result.
  ensure
    Process.kill("TERM", qemu.pid) rescue nil
  end
end

File.write(options[:log], transcript)
warn "terminal_driver: answered #{$answered_count.to_i} cursor queries, " \
     "sent #{$sent_count.to_i}/#{script.length} lines"

