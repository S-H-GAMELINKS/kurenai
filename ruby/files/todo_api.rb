# The TODO app's server half: a small JSON API, mounted on WEBrick at
# /api/todos. The page in /www/todo is the other half, written in Ruby too and
# run in the browser by PicoRuby.wasm, so a todo goes from Ruby in the browser
# to Ruby in WEBrick to a file the Ruby kernel keeps -- and back.
#
#   GET    /api/todos        every todo, oldest first
#   POST   /api/todos        {"title": "..."}            -> the new todo
#   PATCH  /api/todos/:id    {"done": true, "title": ...} -> the changed todo
#   DELETE /api/todos/:id                                 -> 204
#   GET    /api/about        which Ruby is answering
#
# Todos are kept in one JSON file, rewritten on every change. The filesystem
# is in memory, so they last as long as the machine does -- across reloads of
# the page, not across boots.
require "json"
require "webrick"

module TodoAPI
  class Store
    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @todos = File.exist?(path) ? JSON.parse(File.read(path)) : []
      @next_id = (@todos.map { |todo| todo["id"] }.max || 0) + 1
    end

    def all
      @mutex.synchronize { @todos.map(&:dup) }
    end

    def create(title)
      @mutex.synchronize do
        todo = { "id" => @next_id, "title" => title, "done" => false }
        @next_id += 1
        @todos << todo
        save
        todo.dup
      end
    end

    def update(id, changes)
      @mutex.synchronize do
        todo = @todos.find { |t| t["id"] == id }
        return nil unless todo

        todo["title"] = changes["title"].to_s.strip if changes.key?("title")
        todo["done"] = changes["done"] == true if changes.key?("done")
        save
        todo.dup
      end
    end

    def delete(id)
      @mutex.synchronize do
        removed = @todos.reject! { |t| t["id"] == id }
        save if removed
        !removed.nil?
      end
    end

    private

    def save
      File.write(@path, JSON.generate(@todos))
    end
  end

  # One servlet for the collection and its members. WEBrick dispatches on the
  # method name, so PATCH is simply do_PATCH.
  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(server, store)
      super(server)
      @store = store
    end

    def do_GET(request, response)
      id = member_id(request)
      return not_found(response) if id

      json(response, 200, @store.all)
    end

    def do_POST(request, response)
      return not_found(response) if member_id(request)

      title = body(request)["title"].to_s.strip
      return json(response, 422, { "error" => "title can't be blank" }) if title.empty?

      json(response, 201, @store.create(title))
    end

    def do_PATCH(request, response)
      id = member_id(request)
      return not_found(response) unless id

      todo = @store.update(id, body(request))
      todo ? json(response, 200, todo) : not_found(response)
    end

    def do_DELETE(request, response)
      id = member_id(request)
      return not_found(response) unless id
      return not_found(response) unless @store.delete(id)

      response.status = 204
    end

    private

    # "/api/todos/3" -> 3; "/api/todos" -> nil.
    def member_id(request)
      rest = request.path_info.to_s.delete_prefix("/")
      rest.empty? ? nil : Integer(rest, exception: false) || -1
    end

    def body(request)
      parsed = JSON.parse(request.body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def json(response, status, value)
      response.status = status
      response.content_type = "application/json"
      # The list changes under the page; a cached copy would show it stale.
      response["Cache-Control"] = "no-store"
      response.body = JSON.generate(value)
    end

    def not_found(response)
      json(response, 404, { "error" => "not found" })
    end
  end

  def self.mount(server, path)
    store = Store.new(path)
    server.mount("/api/todos", Servlet, store)
    server.mount_proc("/api/about") do |_request, response|
      response.content_type = "application/json"
      response.body = JSON.generate(
        "engine" => RUBY_ENGINE, "version" => RUBY_VERSION,
        "platform" => RUBY_PLATFORM, "server" => "WEBrick #{WEBrick::VERSION}"
      )
    end
    store
  end
end
