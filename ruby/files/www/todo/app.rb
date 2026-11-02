# The TODO app's browser half, run by PicoRuby.wasm with Funicular.
#
# Every todo lives on the server -- /api/todos, Ruby in WEBrick, see
# /todo_api.rb -- and every change is a request followed by a fresh list, so
# the page shows exactly what the server holds. The server's own Ruby is asked
# for at start-up and named at the bottom, next to this one's.

class TodoApp < Funicular::Component
  def initialize_state
    { todos: [], loaded: false, error: nil, server: nil }
  end

  def component_mounted
    reload
    Funicular::HTTP.get("/api/about") do |response|
      patch(server: response.data) unless response.error?
    end
  end

  def reload
    Funicular::HTTP.get("/api/todos") do |response|
      if response.error?
        patch(error: response.error_message, loaded: true)
      else
        patch(todos: response.data, loaded: true, error: nil)
      end
    end
  end

  # After a change: the new list if it worked, the reason if it did not.
  def after_change(response)
    if response.error?
      patch(error: response.error_message)
    else
      reload
    end
  end

  def handle_add(event)
    event.preventDefault
    field = JS.document.getElementById("new-todo")
    title = field[:value].to_s.strip
    return if title.empty?

    field[:value] = ""
    Funicular::HTTP.post("/api/todos", { title: title }) { |r| after_change(r) }
  end

  def toggle(todo)
    -> {
      Funicular::HTTP.patch("/api/todos/#{todo["id"]}", { done: !todo["done"] }) do |r|
        after_change(r)
      end
    }
  end

  def remove(todo)
    -> {
      Funicular::HTTP.delete("/api/todos/#{todo["id"]}") { |r| after_change(r) }
    }
  end

  def render
    todos = state[:todos]
    # select and size rather than count: this is mruby, without enum-ext.
    left = todos.select { |todo| !todo["done"] }.size

    div do
      form(onsubmit: :handle_add) do
        input(type: "text", id: "new-todo", placeholder: "What needs doing?",
              autocomplete: "off")
        button(type: "submit") { "Add" }
      end

      if !state[:loaded]
        p(class: "status") { "Loading…" }
      elsif todos.empty?
        ul { li(class: "empty") { "Nothing to do." } }
      else
        ul do
          todos.each do |todo|
            li(key: todo["id"], class: todo["done"] ? "done" : "") do
              input(type: "checkbox", checked: todo["done"], onchange: toggle(todo))
              span(class: "title") { todo["title"] }
              button(onclick: remove(todo), title: "Delete") { "×" }
            end
          end
        end
      end

      p(class: "status") { "#{left} of #{todos.size} left" } if state[:loaded]
      p(class: "status error") { state[:error] } if state[:error]

      footer do
        server = state[:server]
        if server
          p { "Server: #{server["engine"]} #{server["version"]} [#{server["platform"]}], #{server["server"]}" }
        end
        p { "Browser: #{RUBY_ENGINE} #{RUBY_VERSION} on PicoRuby.wasm, with Funicular" }
      end
    end
  end
end

# The placeholder the page shows until Ruby is running; it is running now.
JS.document.getElementById("booting").remove
Funicular.start(TodoApp, container: "app")
