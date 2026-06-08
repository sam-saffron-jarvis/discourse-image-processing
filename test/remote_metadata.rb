# frozen_string_literal: true

require "socket"
require_relative "../lib/safe_image"

FIXTURES = File.expand_path("fixtures/images", __dir__)
JPG = File.join(FIXTURES, "huge.jpg")
GIF = File.join(FIXTURES, "animated.gif")

blocked = %w[
  0.0.0.0 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1
  192.0.0.1 192.0.2.1 192.31.196.1 192.52.193.1 192.168.0.1
  192.175.48.1 198.18.0.1 198.51.100.1
  203.0.113.1 224.0.0.1 240.0.0.1 255.255.255.255
  :: ::1 ::ffff:127.0.0.1 64:ff9b::808:808 64:ff9b:1::1 100::1
  2001::1 2001:2::1 2001:db8::1 2002::1 fc00::1 fd00::1 fe80::1 ff00::1
]
blocked.each do |address|
  raise "expected #{address} to be blocked" unless SafeImage::Remote.blocked_ip?(IPAddr.new(address))
end

allowed = %w[8.8.8.8 1.1.1.1 2001:4860:4860::8888 2606:4700:4700::1111]
allowed.each do |address|
  raise "expected #{address} to be allowed" if SafeImage::Remote.blocked_ip?(IPAddr.new(address))
end

same_origin_headers = SafeImage::Remote.redirect_headers(
  { "Authorization" => "secret", "Cookie" => "yum" },
  from: URI("https://example.com/a"),
  to: URI("https://example.com/b")
)
raise "same-origin redirect stripped headers" unless same_origin_headers.key?("Authorization") && same_origin_headers.key?("Cookie")

cross_origin_headers = SafeImage::Remote.redirect_headers(
  { "Authorization" => "secret", "Cookie" => "yum", "X-Test" => "nope", "Accept" => "image/*" },
  from: URI("https://example.com/a"),
  to: URI("https://evil.example/b")
)
raise "cross-origin redirect leaked Authorization" if cross_origin_headers.key?("Authorization")
raise "cross-origin redirect leaked Cookie" if cross_origin_headers.key?("Cookie")
raise "cross-origin redirect leaked custom header" if cross_origin_headers.key?("X-Test")
raise "cross-origin redirect stripped safe header" unless cross_origin_headers["Accept"] == "image/*"

filtered_headers = SafeImage::Remote.filtered_headers("Host" => "evil", "Connection" => "keep-alive", "X-Test" => "ok")
raise "filtered headers kept Host" if filtered_headers.key?("Host")
raise "filtered headers stripped normal header" unless filtered_headers["X-Test"] == "ok"

begin
  SafeImage::Remote.validate_uri!(URI("https://example.com:81/x"), allow_private: false)
  abort "remote disallowed port unexpectedly accepted"
rescue SafeImage::UnsafePathError
end

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

  old_http_proxy = ENV["HTTP_PROXY"]
  old_https_proxy = ENV["HTTPS_PROXY"]
  ENV["HTTP_PROXY"] = "http://127.0.0.1:1"
  ENV["HTTPS_PROXY"] = "http://127.0.0.1:1"
  begin
    raise "remote size mismatch" unless SafeImage.remote_size("#{url}/huge.jpg", allow_private: true, max_bytes: 1_000_000, max_pixels: 100_000_000) == [8900, 8900]
  ensure
    ENV["HTTP_PROXY"] = old_http_proxy
    ENV["HTTPS_PROXY"] = old_https_proxy
  end

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
