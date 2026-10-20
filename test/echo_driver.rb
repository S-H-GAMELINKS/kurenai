# test/terminal_driver.rb, with something on the host side to connect to.
#
# The kernel's address for this machine is 10.0.2.2 under QEMU's user-mode
# network, which reaches 127.0.0.1 here. An echo server on that port answers
# each line it is sent with "echo: " and the line, so a session can check that
# a connection made from inside the kernel carried bytes both ways.
#
#   ruby echo_driver.rb --echo-port N <terminal_driver.rb's arguments>
#
# The server runs on a thread of this process while the terminal driver runs
# on the main one, and goes when the driver finishes.

require "socket"

port_at = ARGV.index("--echo-port")
abort "echo_driver: --echo-port is required" unless port_at
port = Integer(ARGV.delete_at(port_at + 1))
ARGV.delete_at(port_at)

server = TCPServer.new("127.0.0.1", port)
Thread.new do
  loop do
    Thread.new(server.accept) do |client|
      while (line = client.gets)
        client.write("echo: #{line}")
      end
      client.close
    end
  end
end

load File.expand_path("terminal_driver.rb", __dir__)
