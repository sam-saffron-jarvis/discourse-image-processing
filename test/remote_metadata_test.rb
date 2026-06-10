# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class RemoteMetadataTest < TestCase
    BLOCKED_ADDRESSES = %w[
      0.0.0.0 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1
      192.0.0.1 192.0.2.1 192.31.196.1 192.52.193.1 192.168.0.1
      192.175.48.1 198.18.0.1 198.51.100.1
      203.0.113.1 224.0.0.1 240.0.0.1 255.255.255.255
      :: ::1 ::ffff:127.0.0.1 64:ff9b::808:808 64:ff9b:1::1 100::1
      2001::1 2001:2::1 2001:db8::1 2002::1 fc00::1 fd00::1 fe80::1 ff00::1
    ].freeze

    PUBLIC_ADDRESSES = %w[8.8.8.8 1.1.1.1 2001:4860:4860::8888 2606:4700:4700::1111].freeze

    def teardown
      @server&.shutdown
      super
    end

    def test_blocks_private_and_special_purpose_addresses
      BLOCKED_ADDRESSES.each do |address|
        assert Remote.blocked_ip?(IPAddr.new(address)), "expected #{address} to be blocked"
      end
    end

    def test_allows_public_addresses
      PUBLIC_ADDRESSES.each do |address|
        refute Remote.blocked_ip?(IPAddr.new(address)), "expected #{address} to be allowed"
      end
    end

    def test_same_origin_redirect_keeps_credential_headers
      headers = Remote.redirect_headers(
        { "Authorization" => "secret", "Cookie" => "yum" },
        from: URI("https://example.com/a"),
        to: URI("https://example.com/b")
      )

      assert_equal "secret", headers["Authorization"]
      assert_equal "yum", headers["Cookie"]
    end

    def test_cross_origin_redirect_strips_credential_headers
      headers = Remote.redirect_headers(
        { "Authorization" => "secret", "Cookie" => "yum", "X-Test" => "nope", "Accept" => "image/*" },
        from: URI("https://example.com/a"),
        to: URI("https://evil.example/b")
      )

      refute headers.key?("Authorization"), "leaked Authorization"
      refute headers.key?("Cookie"), "leaked Cookie"
      refute headers.key?("X-Test"), "leaked custom header"
      assert_equal "image/*", headers["Accept"], "stripped safe header"
    end

    def test_filtered_headers_drop_connection_level_headers
      headers = Remote.filtered_headers("Host" => "evil", "Connection" => "keep-alive", "X-Test" => "ok")

      refute headers.key?("Host"), "kept Host"
      assert_equal "ok", headers["X-Test"], "stripped normal header"
    end

    def test_initial_headers_strip_credentials
      headers = Remote.initial_headers("Authorization" => "Bearer test-token", "Cookie" => "test-cookie", "Accept" => "image/*")

      refute headers.key?("Authorization"), "leaked Authorization"
      refute headers.key?("Cookie"), "leaked Cookie"
      assert_equal "image/*", headers["Accept"], "stripped safe Accept"
    end

    def test_validate_uri_rejects_disallowed_port
      assert_raises(UnsafePathError) do
        Remote.validate_uri!(URI("https://example.com:81/x"), allow_private: false)
      end
    end

    def test_private_addresses_are_blocked_by_default
      assert_raises(UnsafePathError) { SafeImage.remote_size(server.url("/huge.jpg")) }
    end

    def test_remote_size_ignores_proxy_environment
      with_env("HTTP_PROXY" => "http://127.0.0.1:1", "HTTPS_PROXY" => "http://127.0.0.1:1") do
        assert_equal [8900, 8900],
          SafeImage.remote_size(server.url("/huge.jpg"), allow_private: true, max_bytes: 1_000_000, max_pixels: JPG_PIXELS)
      end
    end

    def test_remote_type
      assert_equal :jpeg,
        SafeImage.remote_type(server.url("/huge.jpg"), allow_private: true, max_bytes: 1_000_000, max_pixels: JPG_PIXELS)
    end

    def test_follows_redirects
      assert_equal [8900, 8900],
        SafeImage.remote_dimensions(server.url("/redirect"), allow_private: true, max_bytes: 1_000_000, max_pixels: JPG_PIXELS)
    end

    def test_remote_svg_type_and_size
      assert_equal :svg, SafeImage.remote_type(server.url("/icon.svg"), allow_private: true, max_bytes: 1_000_000)
      assert_equal [12, 34], SafeImage.remote_size(server.url("/icon.svg"), allow_private: true, max_bytes: 1_000_000)
    end

    def test_remote_animated_detection
      assert SafeImage.remote_animated?(server.url("/animated"), allow_private: true, max_bytes: 1_000_000, max_pixels: PNG_PIXELS)
    end

    def test_remote_dominant_color
      assert_match(/\A\h{6}\z/,
        SafeImage.remote_dominant_color(server.url("/photo.png"), allow_private: true, max_bytes: 5_000_000, max_pixels: PNG_PIXELS))
    end

    def test_rejects_non_image_content_type
      assert_raises(UnsupportedFormatError) do
        SafeImage.fetch_remote(server.url("/html-as-jpg.jpg"), allow_private: true, max_bytes: 1_000_000) { |_| }
      end
    end

    def test_rejects_content_type_and_extension_mismatch
      assert_raises(UnsupportedFormatError) do
        SafeImage.fetch_remote(server.url("/png-as-jpg.jpg"), allow_private: true, max_bytes: 1_000_000) { |_| }
      end
    end

    def test_enforces_max_bytes
      assert_raises(LimitError) do
        SafeImage.remote_size(server.url("/huge.jpg"), allow_private: true, max_bytes: 10)
      end
    end

    # The content-type and extension-agreement checks need only the response
    # headers, so an unsupported body — however large — must be rejected
    # without downloading it.
    def test_rejects_unsupported_content_type_before_reading_body
      assert_raises(UnsupportedFormatError) do
        SafeImage.remote_size(server.url("/big-html-as-jpg.jpg"), allow_private: true)
      end

      assert_operator server.bytes_sent("/big-html-as-jpg.jpg"), :<, big_html_body.bytesize / 2
    end

    # A body whose first bytes cannot belong to the claimed image format is
    # dropped after the first chunk instead of being downloaded to the cap.
    def test_rejects_mismatched_signature_after_first_bytes
      assert_raises(InvalidImageError) do
        SafeImage.remote_size(server.url("/garbage.png"), allow_private: true)
      end

      assert_operator server.bytes_sent("/garbage.png"), :<, garbage_png_body.bytesize / 2
    end

    # Metadata answers come from the image header; once a prefix probe
    # succeeds the rest of the body is not downloaded.
    def test_remote_size_stops_downloading_after_header_prefix
      assert_equal [8900, 8900],
        SafeImage.remote_size(server.url("/big.jpg"), allow_private: true, max_pixels: JPG_PIXELS)

      assert_operator server.bytes_sent("/big.jpg"), :<, big_jpg_body.bytesize / 2
    end

    # A header that extends past the first probe threshold fails the early
    # probes (truncated prefix), is retried at the next threshold, and still
    # answers correctly without downloading the multi-megabyte tail.
    def test_prefix_probe_retries_until_header_is_complete
      local = tmp_path("slow-header.jpg")
      File.binwrite(local, slow_header_jpg_body)
      assert_equal [8900, 8900], SafeImage.size(local, max_pixels: JPG_PIXELS), "padded fixture must stay a valid JPEG"

      assert_equal [8900, 8900],
        SafeImage.remote_size(server.url("/slow-header.jpg"), allow_private: true, max_pixels: JPG_PIXELS)

      assert_operator server.bytes_sent("/slow-header.jpg"), :<, slow_header_jpg_body.bytesize / 2
    end

    # "Not animated" can only be proven from the complete file (a truncated
    # animation undercounts frames), so a false answer requires the whole
    # body.
    def test_remote_not_animated_requires_full_download
      refute SafeImage.remote_animated?(server.url("/big.jpg"), allow_private: true, max_pixels: JPG_PIXELS)

      assert_equal big_jpg_body.bytesize, server.bytes_sent("/big.jpg")
    end

    def test_signatures_accept_real_fixture_heads
      { ".jpg" => JPG, ".jpeg" => JPG, ".png" => PNG, ".gif" => GIF,
        ".webp" => WEBP, ".heic" => HEIC, ".heif" => HEIC, ".avif" => HEIC,
        ".ico" => ICO, ".jxl" => JXL }.each do |ext, fixture|
        head = File.binread(fixture, Remote::SIGNATURE_HEAD_BYTES)
        Remote.verify_signature!(ext, head)
      end
      # SVG has no signature and must never be rejected.
      Remote.verify_signature!(".svg", "<svg xmlns=")

      assert_raises(InvalidImageError) { Remote.verify_signature!(".png", "<!doctype htm") }
    end

    private

    def server
      @server ||= StubImageServer.new(
        "/huge.jpg" => { content_type: "image/jpeg", body: File.binread(JPG) },
        "/animated" => { content_type: "image/gif", body: File.binread(GIF) },
        "/photo.png" => { content_type: "image/png", body: File.binread(PNG) },
        "/png-as-jpg.jpg" => { content_type: "image/png", body: File.binread(PNG) },
        "/html-as-jpg.jpg" => { content_type: "text/html", body: "<!doctype html><script>alert(1)</script>" },
        "/icon.svg" => { content_type: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="34"></svg>' },
        "/redirect" => { redirect: "/huge.jpg" },
        "/big.jpg" => { content_type: "image/jpeg", body: big_jpg_body },
        "/slow-header.jpg" => { content_type: "image/jpeg", body: slow_header_jpg_body },
        "/garbage.png" => { content_type: "image/png", body: garbage_png_body },
        "/big-html-as-jpg.jpg" => { content_type: "text/html", body: big_html_body }
      )
    end

    # The byte-count assertions tolerate everything the kernel may buffer
    # past the client's abort, so the synthetic bodies are several megabytes
    # with assertions at half their size.

    # Valid JPEG with a multi-megabyte tail after EOI; header questions are
    # answerable from the first kilobytes.
    def big_jpg_body
      @big_jpg_body ||= File.binread(JPG) + ("\x00".b * 8_000_000)
    end

    # Valid JPEG whose markers span several probe thresholds: three maximum-
    # size COM segments (~192KB) after SOI push SOF past the first 64KB probe.
    def slow_header_jpg_body
      @slow_header_jpg_body ||= begin
        jpg = File.binread(JPG)
        comment = "\xFF\xFE\xFF\xFF".b + ("c".b * 65_533)
        jpg.byteslice(0, 2) + (comment * 3) + jpg.byteslice(2, jpg.bytesize - 2) + ("\x00".b * 6_000_000)
      end
    end

    def garbage_png_body
      @garbage_png_body ||= "not a png at all ".b * 250_000
    end

    def big_html_body
      @big_html_body ||= "<!doctype html>".b + ("x".b * 4_000_000)
    end

    def with_env(overrides)
      previous = overrides.keys.to_h { |key| [key, ENV[key]] }
      overrides.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
  end
end
