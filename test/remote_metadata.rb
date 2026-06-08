# frozen_string_literal: true

require "socket"
require_relative "../lib/safe_image"

FIXTURES = File.expand_path("fixtures/images", __dir__)
JPG = File.join(FIXTURES, "huge.jpg")
GIF = File.join(FIXTURES, "animated.gif")

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
running = true

thread = Thread.new do
  while running
    begin
      socket = server.accept

      request_line = socket.gets.to_s
      path = request_line.split[1].to_s
      while (line = socket.gets)
        break if line == "\r\n"
      end

      case path
    when "/huge.jpg"
      body = File.binread(JPG)
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      socket.write body
    when "/animated"
      body = File.binread(GIF)
      socket.write "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      socket.write body
    when "/redirect"
      socket.write "HTTP/1.1 302 Found\r\nLocation: /huge.jpg\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    else
      socket.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end
    rescue IOError
      break
    ensure
      socket&.close
    end
  end
end

url = "http://127.0.0.1:#{port}"

begin
  begin
    SafeImage.remote_size("#{url}/huge.jpg")
    abort "remote private address unexpectedly allowed"
  rescue SafeImage::UnsafePathError
  end

  raise "remote size mismatch" unless SafeImage.remote_size("#{url}/huge.jpg", allow_private: true, max_bytes: 1_000_000, max_pixels: 100_000_000) == [8900, 8900]
  raise "remote type mismatch" unless SafeImage.remote_type("#{url}/huge.jpg", allow_private: true, max_bytes: 1_000_000, max_pixels: 100_000_000) == :jpeg
  raise "remote redirect mismatch" unless SafeImage.remote_dimensions("#{url}/redirect", allow_private: true, max_bytes: 1_000_000, max_pixels: 100_000_000) == [8900, 8900]
  raise "remote animated mismatch" unless SafeImage.remote_animated?("#{url}/animated", allow_private: true, max_bytes: 1_000_000, max_pixels: 10_000_000)

  begin
    SafeImage.remote_size("#{url}/huge.jpg", allow_private: true, max_bytes: 10)
    abort "remote max_bytes unexpectedly ignored"
  rescue SafeImage::LimitError
  end

  puts "OK remote metadata helpers"
ensure
  running = false
  server.close
  thread.join
end
