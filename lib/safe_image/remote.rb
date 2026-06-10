# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "tempfile"
require "time"
require "tmpdir"
require "uri"
# net/http and resolv are required lazily inside the methods that fetch, not at
# load time: requiring them pulls in resolv, which (Ruby 3.4+) reads
# /etc/resolv.conf eagerly. The Landlock-sandboxed worker loads this file but
# never performs remote fetches, and on hosts where /etc/resolv.conf is a
# symlink into /run the sandbox denies that read and the worker dies at boot.

module SafeImage
  module Remote
    module_function

    DEFAULT_MAX_BYTES = 20 * 1024 * 1024
    DEFAULT_MAX_REDIRECTS = 3
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 10
    DEFAULT_TOTAL_TIMEOUT = 30
    DEFAULT_ALLOWED_PORTS = [80, 443].freeze
    USER_AGENT = "safe_image/#{VERSION}".freeze

    SAFE_CROSS_ORIGIN_REDIRECT_HEADERS = %w[accept accept-encoding user-agent].freeze
    SAFE_INITIAL_REQUEST_HEADERS = SAFE_CROSS_ORIGIN_REDIRECT_HEADERS
    FORBIDDEN_REQUEST_HEADERS = %w[
      host connection keep-alive proxy-authenticate proxy-authorization
      proxy-connection te trailer transfer-encoding upgrade
    ].freeze

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
      "image/jxl" => ".jxl",
      "image/svg+xml" => ".svg"
    }.freeze

    EXTENSIONS = %w[.jpg .jpeg .png .gif .webp .heic .heif .avif .ico .jxl .svg].freeze

    # First-bytes signatures per downloaded extension, checked as soon as the
    # first SIGNATURE_HEAD_BYTES of the body arrive so an obviously mislabeled
    # response is dropped without downloading the rest. Each entry lists
    # alternative candidates; a candidate is a list of [offset, bytes] pairs
    # that must all match. The check rejects only on a definite mismatch of
    # every candidate against fully-available bytes, so it can never reject an
    # image the configured backend could decode — decoders sniff these same
    # magic bytes to pick a loader. SVG has no usable signature and is exempt.
    SIGNATURES = {
      ".jpg" => [[[0, "\xFF\xD8\xFF".b]]],
      ".jpeg" => [[[0, "\xFF\xD8\xFF".b]]],
      ".png" => [[[0, "\x89PNG\r\n\x1A\n".b]]],
      ".gif" => [[[0, "GIF8".b]]],
      ".webp" => [[[0, "RIFF".b], [8, "WEBP".b]]],
      ".ico" => [[[0, "\x00\x00\x01\x00".b]]],
      ".heic" => [[[4, "ftyp".b]]],
      ".heif" => [[[4, "ftyp".b]]],
      ".avif" => [[[4, "ftyp".b]]],
      ".jxl" => [[[0, "\xFF\x0A".b]], [[0, "\x00\x00\x00\x0CJXL \r\n\x87\n".b]]]
    }.freeze

    SIGNATURE_HEAD_BYTES = 12

    # The metadata helpers probe the partially-downloaded file at these
    # growing byte thresholds and abort the transfer once the answer is
    # stable, instead of always downloading up to max_bytes.
    PREFIX_PROBE_INITIAL_BYTES = 64 * 1024
    PREFIX_PROBE_GROWTH_FACTOR = 4

    # SVG is excluded from prefix probing: SvgMetadata enforces a total-size
    # cap (MAX_SVG_BYTES) that probing a prefix would bypass, and remote SVGs
    # are small enough that downloading them fully costs little.
    PREFIX_PROBE_EXTENSIONS = (EXTENSIONS - [".svg"]).freeze

    # Sentinel a metadata_fetch block returns when the prefix parsed but its
    # answer could still change with more data (e.g. "not animated", which a
    # truncated file can report for an animated one).
    CONTINUE_DOWNLOAD = Object.new.freeze

    BLOCKED_IP_RANGES = [
      # IPv4 special-use / non-public ranges. Default remote fetching is for
      # public Internet images only; callers probing trusted internal URLs must
      # opt in with allow_private: true.
      "0.0.0.0/8",          # current network
      "10.0.0.0/8",         # RFC1918 private-use
      "100.64.0.0/10",      # RFC6598 carrier-grade NAT
      "127.0.0.0/8",        # loopback
      "169.254.0.0/16",     # RFC3927 link-local
      "172.16.0.0/12",      # RFC1918 private-use
      "192.0.0.0/24",       # IETF protocol assignments
      "192.0.2.0/24",       # TEST-NET-1
      "192.31.196.0/24",    # AS112-v4
      "192.52.193.0/24",    # AMT
      "192.168.0.0/16",     # RFC1918 private-use
      "192.175.48.0/24",    # direct delegation AS112 service
      "198.18.0.0/15",      # benchmark testing
      "198.51.100.0/24",    # TEST-NET-2
      "203.0.113.0/24",     # TEST-NET-3
      "224.0.0.0/4",        # multicast
      "240.0.0.0/4",        # reserved / future-use
      "255.255.255.255/32", # limited broadcast

      # IPv6 special-use / non-public ranges.
      "::/128",             # unspecified
      "::1/128",            # loopback
      "::/96",              # deprecated IPv4-compatible IPv6
      "::ffff:0:0/96",      # IPv4-mapped IPv6
      "64:ff9b::/96",       # well-known NAT64 prefix
      "64:ff9b:1::/48",     # local-use NAT64 prefix
      "100::/64",           # discard-only prefix
      "2001::/23",          # IETF protocol assignments, incl. Teredo/benchmarking
      "2001:db8::/32",      # documentation
      "2002::/16",          # 6to4
      "fc00::/7",           # unique local address
      "fe80::/10",          # link-local unicast
      "ff00::/8"            # multicast
    ].map { |range| IPAddr.new(range) }.freeze

    def fetch(
      url,
      max_bytes: DEFAULT_MAX_BYTES,
      max_redirects: DEFAULT_MAX_REDIRECTS,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      total_timeout: DEFAULT_TOTAL_TIMEOUT,
      allow_private: false,
      allowed_ports: DEFAULT_ALLOWED_PORTS,
      headers: {}
    )
      uri = parse_uri(url)
      started_at = monotonic_time

      Tempfile.create(["safe-image-remote", ".bin"], binmode: true) do |file|
        response = request(
          uri,
          io: file,
          max_bytes: max_bytes,
          max_redirects: max_redirects,
          open_timeout: open_timeout,
          read_timeout: read_timeout,
          total_timeout: total_timeout,
          started_at: started_at,
          allow_private: allow_private,
          allowed_ports: allowed_ports,
          headers: headers
        )
        file.flush

        ext = response.fetch(:ext)
        path = file.path
        if File.extname(path) != ext
          renamed = path.sub(/\.bin\z/, ext)
          FileUtils.mv(path, renamed)
          begin
            validate_downloaded_image!(renamed, ext)
            yield renamed
          ensure
            FileUtils.rm_f(renamed)
          end
        else
          validate_downloaded_image!(path, ext)
          yield path
        end
      end
    end

    def info(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, total_timeout: DEFAULT_TOTAL_TIMEOUT, allow_private: false, allowed_ports: DEFAULT_ALLOWED_PORTS, headers: {}, max_pixels: nil, animated: false, orientation: false)
      metadata_fetch(url, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, total_timeout: total_timeout, allow_private: allow_private, allowed_ports: allowed_ports, headers: headers) do |path, eof|
        result = SafeImage.info(path, max_pixels: max_pixels, animated: animated, orientation: orientation)
        # A truncated file can undercount frames but never overcount, so
        # "animated" is final as soon as it is true; "not animated" is only
        # provable from the complete file. Type, dimensions and orientation
        # come from the header the successful probe just parsed, so they
        # cannot change with more data.
        if animated && result.animated != true && !eof
          CONTINUE_DOWNLOAD
        else
          result
        end
      end
    end

    def size(url, **kwargs)
      info(url, **kwargs).size
    end

    def type(url, **kwargs)
      info(url, **kwargs).type
    end

    def animated?(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, total_timeout: DEFAULT_TOTAL_TIMEOUT, allow_private: false, allowed_ports: DEFAULT_ALLOWED_PORTS, headers: {}, max_pixels: nil)
      metadata_fetch(url, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, total_timeout: total_timeout, allow_private: allow_private, allowed_ports: allowed_ports, headers: headers) do |path, eof|
        answer = SafeImage.animated?(path, max_pixels: max_pixels)
        next CONTINUE_DOWNLOAD if !eof && answer != true

        answer
      end
    end

    def dominant_color(url, max_bytes: DEFAULT_MAX_BYTES, max_redirects: DEFAULT_MAX_REDIRECTS, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, total_timeout: DEFAULT_TOTAL_TIMEOUT, allow_private: false, allowed_ports: DEFAULT_ALLOWED_PORTS, headers: {}, max_pixels: nil)
      fetch(url, max_bytes: max_bytes, max_redirects: max_redirects, open_timeout: open_timeout, read_timeout: read_timeout, total_timeout: total_timeout, allow_private: allow_private, allowed_ports: allowed_ports, headers: headers) do |path|
        SafeImage.dominant_color(path, max_pixels: max_pixels)
      end
    end

    # Single-GET download that re-attempts the local metadata probe as bytes
    # arrive (at PREFIX_PROBE_INITIAL_BYTES, then growing by
    # PREFIX_PROBE_GROWTH_FACTOR) and aborts the transfer as soon as the
    # block's answer is final. The block receives (path, eof) and must return
    # CONTINUE_DOWNLOAD while its answer could still change with more data.
    #
    # Safety contract: any error from a pre-EOF probe means "not enough bytes
    # yet" — it is swallowed and the download continues, so the complete file
    # always gets the last word with exactly the validation and error
    # behaviour of the full-download path (validate_downloaded_image! plus an
    # un-rescued final probe). A file that never early-exits is handled
    # byte-for-byte like Remote.fetch handles it.
    def metadata_fetch(url, max_bytes:, max_redirects:, open_timeout:, read_timeout:, total_timeout:, allow_private:, allowed_ports:, headers:, &compute)
      uri = parse_uri(url)
      started_at = monotonic_time

      Tempfile.create(["safe-image-remote", ".bin"], binmode: true) do |file|
        original_path = file.path
        path = original_path
        ext = nil
        next_probe_at = PREFIX_PROBE_INITIAL_BYTES

        begin
          early = catch(:metadata_answer) do
            request(
              uri,
              io: file,
              max_bytes: max_bytes,
              max_redirects: max_redirects,
              open_timeout: open_timeout,
              read_timeout: read_timeout,
              total_timeout: total_timeout,
              started_at: started_at,
              allow_private: allow_private,
              allowed_ports: allowed_ports,
              headers: headers,
              # The extension is known before the body: give the tempfile its
              # final name up front so probes dispatch on the right loader.
              on_headers: ->(response_ext) do
                ext = response_ext
                renamed = original_path.sub(/\.bin\z/, ext)
                FileUtils.mv(original_path, renamed)
                path = renamed
              end,
              on_progress: ->(bytes) do
                next unless PREFIX_PROBE_EXTENSIONS.include?(ext)
                next if bytes < next_probe_at

                next_probe_at *= PREFIX_PROBE_GROWTH_FACTOR while bytes >= next_probe_at
                file.flush
                answer =
                  begin
                    compute.call(path, false)
                  rescue StandardError
                    CONTINUE_DOWNLOAD
                  end
                throw :metadata_answer, [answer] unless CONTINUE_DOWNLOAD.equal?(answer)
              end
            )
            nil
          end

          if early
            early.first
          else
            file.flush
            validate_downloaded_image!(path, ext)
            compute.call(path, true)
          end
        ensure
          FileUtils.rm_f(path) unless path == original_path
        end
      end
    end

    def request(uri, io:, max_bytes:, max_redirects:, open_timeout:, read_timeout:, total_timeout:, started_at:, allow_private:, allowed_ports:, headers: {}, on_headers: nil, on_progress: nil)
      require "net/http"
      raise ArgumentError, "too many redirects" if max_redirects < 0
      check_deadline!(started_at, total_timeout)
      ipaddr = validate_uri!(uri, allow_private: allow_private, allowed_ports: allowed_ports)

      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = ipaddr if ipaddr
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "image/*,*/*;q=0.1"
      request["Accept-Encoding"] = "identity"
      initial_headers(headers).each { |key, value| request[key.to_s] = value.to_s }

      bytes = 0
      content_type = nil
      ext = nil

      http.request(request) do |response|
        check_deadline!(started_at, total_timeout)

        case response
        when Net::HTTPRedirection
          location = response["location"] or raise Error, "redirect without Location"
          redirected = parse_uri(uri.merge(location).to_s)
          if uri.scheme == "https" && redirected.scheme == "http"
            raise UnsafePathError, "refusing HTTPS to HTTP redirect"
          end
          return request(
            redirected,
            io: io,
            max_bytes: max_bytes,
            max_redirects: max_redirects - 1,
            open_timeout: open_timeout,
            read_timeout: read_timeout,
            total_timeout: total_timeout,
            started_at: started_at,
            allow_private: allow_private,
            allowed_ports: allowed_ports,
            headers: redirect_headers(headers, from: uri, to: redirected),
            on_headers: on_headers,
            on_progress: on_progress
          )
        when Net::HTTPSuccess
          content_length = response["content-length"].to_i
          raise LimitError, "remote image exceeds #{max_bytes} bytes" if content_length > max_bytes

          content_type = response["content-type"].to_s.split(";", 2).first.to_s.downcase
          # Everything the content-type and extension-agreement checks need is
          # in the headers: reject unsupported or mismatched responses before
          # reading a single body byte.
          ext = extension_for(uri, content_type)
          on_headers&.call(ext)

          head = "".b
          head_checked = false
          response.read_body do |chunk|
            check_deadline!(started_at, total_timeout)
            bytes += chunk.bytesize
            raise LimitError, "remote image exceeds #{max_bytes} bytes" if bytes > max_bytes
            unless head_checked
              head << chunk
              if head.bytesize >= SIGNATURE_HEAD_BYTES
                verify_signature!(ext, head)
                head_checked = true
                head = nil
              end
            end
            io.write(chunk)
            on_progress&.call(bytes)
          end
          verify_signature!(ext, head) if !head_checked && !head.empty?
        else
          raise Error, "remote image request failed: HTTP #{response.code}"
        end
      end

      { uri: uri, content_type: content_type, ext: ext, bytes: bytes }
    end

    # Rejects a body whose first bytes definitively cannot belong to the
    # format the response claimed. Formats without a fixed signature (SVG)
    # and bytes not yet downloaded are never grounds for rejection.
    def verify_signature!(ext, head)
      candidates = SIGNATURES[ext]
      return unless candidates

      compatible = candidates.any? do |candidate|
        candidate.all? do |offset, bytes|
          slice = head.byteslice(offset, bytes.bytesize).to_s
          slice.empty? || slice == bytes.byteslice(0, slice.bytesize)
        end
      end
      return if compatible

      raise InvalidImageError, "remote image first bytes do not match #{ext.delete_prefix(".")} signature"
    end

    def parse_uri(url)
      uri = URI.parse(url.to_s)
      raise ArgumentError, "remote image URL must be http or https" unless %w[http https].include?(uri.scheme)
      raise ArgumentError, "remote image URL must include a host" if uri.host.to_s.empty?
      uri
    rescue URI::InvalidURIError => e
      raise ArgumentError, "invalid remote image URL: #{e.message}"
    end

    def validate_uri!(uri, allow_private:, allowed_ports: DEFAULT_ALLOWED_PORTS)
      unless allow_private || allowed_ports.nil? || allowed_ports.include?(uri.port)
        raise UnsafePathError, "remote image URL uses a disallowed port"
      end
      return nil if allow_private

      require "resolv"
      resolver = Resolv::DNS.new
      resolver.timeouts = [2, 2]
      addresses = resolver.getaddresses(uri.host).map(&:to_s)
      raise UnsafePathError, "remote image host did not resolve" if addresses.empty?

      addresses.each do |address|
        ip = IPAddr.new(address)
        if blocked_ip?(ip)
          raise UnsafePathError, "remote image host resolves to a non-public address"
        end
      end

      # Pin the socket to a vetted address so validation and connection cannot
      # observe different DNS answers. Prefer IPv4 first for compatibility with
      # common hosts, but either family is fine because every address above was
      # checked.
      addresses.sort_by { |address| address.include?(":") ? 1 : 0 }.first
    end

    def blocked_ip?(ip)
      BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
    end

    def filtered_headers(headers)
      headers.reject { |key, _| FORBIDDEN_REQUEST_HEADERS.include?(key.to_s.downcase) }
    end

    def initial_headers(headers)
      filtered_headers(headers).select { |key, _| SAFE_INITIAL_REQUEST_HEADERS.include?(key.to_s.downcase) }
    end

    def redirect_headers(headers, from:, to:)
      headers = filtered_headers(headers)
      return headers if same_origin?(from, to)

      headers.select { |key, _| SAFE_CROSS_ORIGIN_REDIRECT_HEADERS.include?(key.to_s.downcase) }
    end

    def same_origin?(a, b)
      a.scheme.to_s.downcase == b.scheme.to_s.downcase &&
        a.host.to_s.downcase == b.host.to_s.downcase &&
        a.port == b.port
    end

    def check_deadline!(started_at, total_timeout)
      return unless total_timeout
      raise Error, "remote image request timed out" if monotonic_time - started_at > total_timeout
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def extension_for(uri, content_type)
      content_ext = CONTENT_TYPE_EXTENSIONS[content_type]
      raise UnsupportedFormatError, "remote image has unsupported or missing content type: #{content_type.inspect}" unless content_ext

      ext = File.extname(uri.path).downcase
      if EXTENSIONS.include?(ext)
        normalized_ext = ext == ".jpeg" ? ".jpg" : ext
        normalized_content_ext = content_ext == ".jpeg" ? ".jpg" : content_ext
        unless normalized_ext == normalized_content_ext
          raise UnsupportedFormatError, "remote image extension #{ext.inspect} does not match content type #{content_type.inspect}"
        end
        return ext
      end

      content_ext
    end

    def validate_downloaded_image!(path, ext)
      if ext == ".svg"
        SvgMetadata.probe(path)
      else
        SafeImage.probe(path)
      end
    end
  end
end
