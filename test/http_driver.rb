# Boots the kernel and asks it for a web page.
#
# The kernel's HTTP demo listens for a couple of seconds and then gives way to
# irb, so a test cannot boot, sleep and hope: it has to watch the console and
# knock the moment the door opens. That is the whole reason this exists rather
# than a shell script with a sleep in it.
#
#   ruby http_driver.rb --qemu QEMU --kernel ELF --log FILE --port N
#                       [--requests N] [--expect TEXT] [--seconds N]
#                       [--until PATTERN]

require "optparse"
require "net/http"

options = { seconds: 60, requests: 2, port: 18080, expect: nil }
OptionParser.new do |o|
  o.on("--qemu PATH")     { |v| options[:qemu] = v }
  o.on("--kernel PATH")   { |v| options[:kernel] = v }
  o.on("--log PATH")      { |v| options[:log] = v }
  o.on("--port N")        { |v| options[:port] = v.to_i }
  o.on("--requests N")    { |v| options[:requests] = v.to_i }
  o.on("--expect TEXT")   { |v| options[:expect] = v }
  o.on("--seconds N")     { |v| options[:seconds] = v.to_i }
  o.on("--until PATTERN") { |v| options[:until] = v }
end.parse!

%i[qemu kernel log port].each do |key|
  abort "http_driver: --#{key} is required" unless options[key]
end

transcript = +""
deadline = Time.now + options[:seconds]
responses = []
failures = []

# The card is declared the same way here as in the run target and in
# boot_serial.cmake, plus the forward that makes the guest's port 80 reachable
# from this side. User-mode networking needs no privileges, which is what makes
# this runnable as an ordinary test.
qemu_command = [
  options[:qemu],
  "-kernel", options[:kernel],
  "-m", "2048",
  "-cpu", "max",
  "-serial", "stdio",
  "-display", "none",
  "-no-reboot",
  "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:#{options[:port]}-:80",
  "-device", "e1000,netdev=net0,mac=52:54:00:12:34:56",
]

def request(port, path)
  Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 5) do |http|
    response = http.get(path)
    [response.code, response.body]
  end
end

IO.popen(qemu_command, "r+") do |qemu|
  listening = false
  asked = 0

  begin
    while Time.now < deadline
      ready = IO.select([qemu], nil, nil, 0.1)
      if ready
        begin
          transcript << qemu.read_nonblock(4096)
        rescue EOFError
          break
        end
      end

      # The kernel says when it is ready. Anything before that would be
      # refused, because slirp only forwards to a guest that is listening.
      listening ||= transcript.include?("http: listening")

      if listening && asked < options[:requests]
        asked += 1
        begin
          code, body = request(options[:port], "/request-#{asked}")
          responses << [code, body]
        rescue => e
          failures << "request #{asked}: #{e.class}: #{e.message}"
        end
      end

      break if options[:until] && transcript.match?(Regexp.new(options[:until]))
    end
  ensure
    Process.kill("TERM", qemu.pid) rescue nil
  end
end

File.write(options[:log], transcript)

problems = failures.dup
if responses.length < options[:requests]
  problems << "only #{responses.length} of #{options[:requests]} requests answered"
end
responses.each_with_index do |(code, body), i|
  problems << "request #{i + 1} answered #{code}" unless code == "200"
  if options[:expect] && !body.to_s.include?(options[:expect])
    problems << "request #{i + 1} body was #{body.inspect}"
  end
end

if problems.empty?
  puts "ok: #{responses.length} requests answered 200 by the kernel"
  exit 0
end

warn "http_driver failed:"
problems.each { |p| warn "  #{p}" }
warn "--- serial ---"
warn transcript
exit 1
