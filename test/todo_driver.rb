# Boots the kernel and uses the TODO app the way its page does.
#
# The page itself runs in a browser -- Ruby on PicoRuby.wasm -- which a test
# here has no browser to run. What can be checked from outside is everything
# the page depends on: that the page, its Ruby and PicoRuby.wasm are served,
# the last with the type a browser insists on before it will compile it, and
# that the JSON API behind the page adds, completes and removes todos and
# keeps them between requests.
#
#   ruby todo_driver.rb --qemu QEMU --kernel ELF --log FILE --port N
#                       --wasm FILE [--seconds N]

require "json"
require "net/http"
require "optparse"

options = { seconds: 60 }
OptionParser.new do |o|
  o.on("--qemu PATH")   { |v| options[:qemu] = v }
  o.on("--kernel PATH") { |v| options[:kernel] = v }
  o.on("--log PATH")    { |v| options[:log] = v }
  o.on("--port N")      { |v| options[:port] = v.to_i }
  # The .wasm the build embedded, to compare with what is served.
  o.on("--wasm PATH")   { |v| options[:wasm] = v }
  o.on("--seconds N")   { |v| options[:seconds] = v.to_i }
end.parse!

%i[qemu kernel log port wasm].each do |key|
  abort "todo_driver: --#{key} is required" unless options[key]
end

transcript = +""
problems = []
deadline = Time.now + options[:seconds]

qemu_command = [
  options[:qemu],
  "-kernel", options[:kernel],
  "-m", "2048",
  "-serial", "stdio",
  "-display", "none",
  "-no-reboot",
  "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:#{options[:port]}-:80",
  "-device", "e1000,netdev=net0,mac=52:54:00:12:34:56",
]

def check(problems, what, ok)
  problems << what unless ok
end

IO.popen(qemu_command, "r+") do |qemu|
  begin
    until transcript.include?("http: serving") || Time.now > deadline
      if IO.select([qemu], nil, nil, 0.1)
        transcript << (qemu.read_nonblock(4096) rescue "")
      end
    end

    if transcript.include?("http: serving")
      http = Net::HTTP.new("127.0.0.1", options[:port])
      http.open_timeout = 5
      http.read_timeout = 10
      json = ->(response) { JSON.parse(response.body) }

      page = http.get("/todo/")
      check(problems, "/todo/ answered #{page.code}", page.code == "200")
      check(problems, "/todo/ does not load app.rb", page.body.to_s.include?('src="app.rb"'))

      script = http.get("/todo/app.rb")
      check(problems, "/todo/app.rb is not the Funicular app",
            script.code == "200" && script.body.to_s.include?("Funicular.start"))

      wasm = http.get("/picoruby/picoruby.wasm")
      check(problems, "picoruby.wasm served as #{wasm["content-type"].inspect}",
            wasm["content-type"] == "application/wasm")
      check(problems, "picoruby.wasm differs from the one embedded",
            wasm.body.to_s.b == File.binread(options[:wasm]))

      about = json.(http.get("/api/about"))
      check(problems, "/api/about says #{about.inspect}",
            about["engine"] == "ruby" && about["platform"] == "x86_64-kurenai")

      check(problems, "the list did not start empty", json.(http.get("/api/todos")) == [])

      first = json.(http.post("/api/todos", { title: "write a kernel in Ruby" }.to_json))
      second = json.(http.post("/api/todos", { title: "serve a page from it" }.to_json))
      check(problems, "POST answered #{first.inspect}",
            first["title"] == "write a kernel in Ruby" && first["done"] == false)

      done = json.(http.patch("/api/todos/#{first["id"]}", { done: true }.to_json))
      check(problems, "PATCH answered #{done.inspect}", done["done"] == true)

      removed = http.delete("/api/todos/#{second["id"]}")
      check(problems, "DELETE answered #{removed.code}", removed.code == "204")

      blank = http.post("/api/todos", { title: "  " }.to_json)
      check(problems, "a blank title answered #{blank.code}", blank.code == "422")

      list = json.(http.get("/api/todos"))
      check(problems, "the list ended as #{list.inspect}",
            list == [{ "id" => first["id"], "title" => "write a kernel in Ruby", "done" => true }])
    else
      problems << "the kernel never printed \"http: serving\""
    end
  rescue StandardError => e
    problems << "#{e.class}: #{e.message}"
  ensure
    Process.kill("TERM", qemu.pid) rescue nil
  end
end

File.write(options[:log], transcript)

if problems.empty?
  puts "ok: the TODO app is served, and its API keeps what it is told"
  exit 0
end

warn "todo_driver failed:"
problems.each { |p| warn "  #{p}" }
exit 1
