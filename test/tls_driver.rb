# test/terminal_driver.rb, with a TLS server on the host side to connect to.
#
# A certificate authority and a server certificate are made here, for the
# address the kernel reaches this machine at under QEMU's user-mode network,
# 10.0.2.2. The server answers each line with "echo: " and the line, over TLS.
#
# The session is the one given with --input, with CA_PEM replaced by the CA
# certificate as a Ruby string literal, so the kernel can write it to a file
# and trust it -- the way termfront is pointed at a server with its own CA
# through TERMFRONT_TLS_CA_FILE.
#
#   ruby tls_driver.rb --tls-port N <terminal_driver.rb's arguments>

require "openssl"
require "socket"
require "tmpdir"

port_at = ARGV.index("--tls-port")
abort "tls_driver: --tls-port is required" unless port_at
port = Integer(ARGV.delete_at(port_at + 1))
ARGV.delete_at(port_at)

def certificate(subject, key, issuer, issuer_key, serial, extensions)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = serial
  cert.subject = OpenSSL::X509::Name.parse(subject)
  cert.issuer = issuer ? issuer.subject : cert.subject
  cert.public_key = key
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + 3600
  factory = OpenSSL::X509::ExtensionFactory.new
  factory.subject_certificate = cert
  factory.issuer_certificate = issuer || cert
  extensions.each { |name, value, critical| cert.add_extension(factory.create_extension(name, value, critical)) }
  cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
  cert
end

ca_key = OpenSSL::PKey::EC.generate("prime256v1")
ca = certificate("/CN=picoruby-kernel test CA", ca_key, nil, ca_key, 1,
                 [["basicConstraints", "CA:TRUE", true],
                  ["keyUsage", "keyCertSign, cRLSign", true]])
server_key = OpenSSL::PKey::EC.generate("prime256v1")
server = certificate("/CN=10.0.2.2", server_key, ca, ca_key, 2,
                     [["basicConstraints", "CA:FALSE", true],
                      ["subjectAltName", "IP:10.0.2.2", false],
                      ["extendedKeyUsage", "serverAuth", false]])

context = OpenSSL::SSL::SSLContext.new
context.cert = server
context.key = server_key
context.min_version = OpenSSL::SSL::TLS1_2_VERSION
listener = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", port), context)

Thread.new do
  loop do
    client = begin
      listener.accept
    rescue OpenSSL::SSL::SSLError
      next
    end
    Thread.new(client) do |c|
      while (line = c.gets)
        c.write("echo: #{line}")
      end
      c.close
    end
  end
end

input_at = ARGV.index("--input")
session = File.read(ARGV[input_at + 1]).gsub("CA_PEM", ca.to_pem.inspect)
generated = File.join(Dir.mktmpdir("tls_driver"), "session.txt")
File.write(generated, session)
ARGV[input_at + 1] = generated

load File.expand_path("terminal_driver.rb", __dir__)
