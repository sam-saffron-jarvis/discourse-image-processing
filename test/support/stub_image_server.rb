# frozen_string_literal: true

require "socket"

# Minimal loopback HTTP server serving canned responses, so the remote
# metadata helpers can be exercised without real network access.
#
# Routes map a request path to either { content_type:, body: } for a 200
# response or { redirect: } for a 302.
#
# Bodies are written in small chunks and the per-path count of bytes actually
# handed to the socket is recorded, so tests can assert that a client aborted
# a download early. A client going away mid-body is expected, not an error.
class StubImageServer
  attr_reader :port

  BODY_CHUNK_BYTES = 8 * 1024

  def initialize(routes)
    @routes = routes
    @bytes_sent = {}
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @running = true
    @thread = Thread.new { serve }
  end

  def url(path)
    "http://127.0.0.1:#{@port}#{path}"
  end

  # Body bytes written to the socket for the most recent request to path.
  # An over-estimate of what the client read by at most the socket buffers.
  def bytes_sent(path)
    @mutex.synchronize { @bytes_sent.fetch(path, 0) }
  end

  def shutdown
    @running = false
    @server.close
    @thread.join
  end

  private

  def serve
    while @running
      socket = nil
      begin
        socket = @server.accept
        respond(socket, read_request_path(socket))
      rescue IOError, Errno::EBADF
        break
      rescue SystemCallError
        # Client aborted the connection; keep serving.
      ensure
        socket&.close
      end
    end
  end

  def read_request_path(socket)
    request_line = socket.gets.to_s
    while (line = socket.gets)
      break if line == "\r\n"
    end
    request_line.split[1].to_s
  end

  def respond(socket, path)
    route = @routes[path]
    if route.nil?
      socket.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    elsif route[:redirect]
      socket.write "HTTP/1.1 302 Found\r\nLocation: #{route[:redirect]}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    else
      body = route.fetch(:body)
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: #{route.fetch(:content_type)}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      write_body_counted(socket, path, body)
    end
  end

  def write_body_counted(socket, path, body)
    offset = 0
    while offset < body.bytesize
      chunk = body.byteslice(offset, BODY_CHUNK_BYTES)
      begin
        socket.write(chunk)
      rescue SystemCallError, IOError
        break
      end
      offset += chunk.bytesize
      @mutex.synchronize { @bytes_sent[path] = offset }
    end
  end
end
