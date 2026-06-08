# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "tempfile"
require "uri"

module SafeImage
  module Remote
    module_function

    DEFAULT_MAX_BYTES = 20 * 1024 * 1024
    DEFAULT_MAX_REDIRECTS = 3
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 10
    USER_AGENT = "safe_image/#{VERSION}".freeze

    CONTENT_TYPE_EXTENSIONS = {
      "image/jpeg" => ".jpg",
      "image/jpg" => ".jpg",
      "image/png" => ".png",
      "image/gif" => ".gif",
      "image/webp" => ".webp",
      "image/heic" => ".heic",
      "image/heif" => ".heif",
      "image/avif" => ".avif",
      "image/x-icon" => ".ico",
      "image/vnd.microsoft.icon" => ".ico",
      "image/svg+xml" => ".svg"
    }.freeze

    EXTENSIONS = %w[.jpg .jpeg .png .gif .webp .heic .heif .avif .ico .svg].freeze

    def fetch(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, allow_private: false, headers: {})
      uri = parse_uri(url)
      response = request(uri, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, allow_private: allow_private, headers: headers)
      ext = extension_for(response.fetch(:uri), response.fetch(:content_type))

      Tempfile.create(["safe-image-remote", ext], binmode: true) do |file|
        file.write(response.fetch(:body))
        file.flush
        yield file.path
      end
    end

    def info(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, allow_private: false, headers: {}, max_pixels: nil, animated: false, orientation: false)
      fetch(url, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, allow_private: allow_private, headers: headers) do |path|
        SafeImage.info(path, max_pixels: max_pixels, animated: animated, orientation: orientation)
      end
    end

    def size(url, **kwargs)
      info(url, **kwargs).size
    end

    def type(url, **kwargs)
      info(url, **kwargs).type
    end

    def animated?(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, allow_private: false, headers: {}, max_pixels: nil)
      fetch(url, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, allow_private: allow_private, headers: headers) do |path|
        SafeImage.animated?(path, max_pixels: max_pixels)
      end
    end

    def request(uri, max_bytes:, max_redirects:, open_timeout:, read_timeout:, allow_private:, headers: {})
      raise ArgumentError, "too many redirects" if max_redirects < 0
      validate_uri!(uri, allow_private: allow_private)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "image/*,*/*;q=0.1"
      headers.each { |key, value| request[key.to_s] = value.to_s }

      body = +"".b
      final_uri = uri
      content_type = nil

      http.request(request) do |response|
        case response
        when Net::HTTPRedirection
          location = response["location"] or raise Error, "redirect without Location"
          redirected = uri.merge(location)
          return request(
            redirected,
            max_bytes: max_bytes,
            max_redirects: max_redirects - 1,
            open_timeout: open_timeout,
            read_timeout: read_timeout,
            allow_private: allow_private,
            headers: headers
          )
        when Net::HTTPSuccess
          content_length = response["content-length"].to_i
          raise LimitError, "remote image exceeds #{max_bytes} bytes" if content_length > max_bytes

          content_type = response["content-type"].to_s.split(";", 2).first.to_s.downcase
          response.read_body do |chunk|
            body << chunk
            raise LimitError, "remote image exceeds #{max_bytes} bytes" if body.bytesize > max_bytes
          end
        else
          raise Error, "remote image request failed: HTTP #{response.code}"
        end
      end

      { uri: final_uri, body: body, content_type: content_type }
    end

    def parse_uri(url)
      uri = URI.parse(url.to_s)
      raise ArgumentError, "remote image URL must be http or https" unless %w[http https].include?(uri.scheme)
      raise ArgumentError, "remote image URL must include a host" if uri.host.to_s.empty?
      uri
    rescue URI::InvalidURIError => e
      raise ArgumentError, "invalid remote image URL: #{e.message}"
    end

    def validate_uri!(uri, allow_private:)
      return if allow_private

      Resolv.each_address(uri.host) do |address|
        ip = IPAddr.new(address)
        if ip.loopback? || ip.link_local? || ip.private? || ip.to_s == "0.0.0.0" || ip.to_s == "::"
          raise UnsafePathError, "remote image host resolves to a private address"
        end
      end
    end

    def extension_for(uri, content_type)
      ext = File.extname(uri.path).downcase
      return ext if EXTENSIONS.include?(ext)

      CONTENT_TYPE_EXTENSIONS.fetch(content_type) do
        raise UnsupportedFormatError, "remote image has unsupported or missing content type: #{content_type.inspect}"
      end
    end
  end
end
