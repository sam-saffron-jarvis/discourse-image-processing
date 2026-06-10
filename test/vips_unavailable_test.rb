# frozen_string_literal: true

require "open3"
require "json"
require_relative "test_helper"

module SafeImage
  # The libvips binding loads at runtime, so a host with only ImageMagick
  # must keep working: :auto backends route to ImageMagick, pure-Ruby paths
  # (SVG, ICO metadata) are unaffected, and only explicit backend: :vips
  # calls fail closed. Exercised in a subprocess with the library override
  # pointed at a name that cannot resolve.
  class VipsUnavailableTest < TestCase
    SCRIPT = <<~'RUBY'
      require "safe_image"
      require "json"

      out = {}
      out[:available] = SafeImage::VipsGlue.available?
      out[:probe_jpg] = SafeImage.probe(ENV["JPG"], max_pixels: 100_000_000).backend
      out[:probe_ico] = SafeImage.probe(ENV["ICO"]).backend
      out[:thumb] = SafeImage.thumbnail(input: ENV["JPG"], output: File.join(ENV["OUT"], "t.jpg"), width: 60, height: 40, max_pixels: 100_000_000).backend
      out[:resize] = SafeImage.resize(ENV["PNG"], File.join(ENV["OUT"], "r.png"), 100, 65, max_pixels: 10_000_000).backend
      out[:gif_convert] = SafeImage.convert(ENV["GIF"], File.join(ENV["OUT"], "g.png"), format: "png", max_pixels: 10_000_000).backend
      out[:dominant] = SafeImage.dominant_color(ENV["PNG"], max_pixels: 10_000_000)
      out[:dominant_ico] = SafeImage.dominant_color(ENV["ICO"])
      out[:avatar] = SafeImage.letter_avatar(output: File.join(ENV["OUT"], "a.png"), size: 64, background_rgb: [1, 2, 3], letter: "S").backend
      out[:favicon] = SafeImage.convert_favicon_to_png(ENV["ICO"], File.join(ENV["OUT"], "f.png")).backend
      out[:frames] = SafeImage.frame_count(ENV["GIF"], max_pixels: 10_000_000)
      out[:orientation] = SafeImage.orientation(ENV["JPG"])
      begin
        SafeImage.thumbnail(input: ENV["JPG"], output: File.join(ENV["OUT"], "x.jpg"), width: 10, height: 10, backend: :vips, max_pixels: 100_000_000)
        out[:vips_pin] = "no error"
      rescue SafeImage::VipsUnavailableError
        out[:vips_pin] = "raised"
      end

      puts JSON.dump(out)
    RUBY

    def test_gracefully_degrades_to_imagemagick_without_libvips
      env = {
        "SAFE_IMAGE_LIBVIPS" => "libsafe-image-no-such-library.so.0",
        "JPG" => JPG, "PNG" => PNG, "GIF" => GIF, "ICO" => ICO, "OUT" => tmpdir
      }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", SCRIPT)

      assert status.success?, "vips-less child process failed:\n#{stderr}"
      out = JSON.parse(stdout.lines.last)

      assert_equal false, out["available"]
      assert_equal "imagemagick", out["probe_jpg"]
      assert_equal "ico-metadata", out["probe_ico"], "pure-Ruby paths must not depend on libvips"
      assert_equal "imagemagick", out["thumb"]
      assert_equal "imagemagick", out["resize"]
      assert_equal "imagemagick", out["gif_convert"]
      assert_match(/\A\h{6}\z/, out["dominant"])
      assert_match(/\A\h{6}\z/, out["dominant_ico"])
      assert_equal "imagemagick", out["avatar"]
      assert_equal "imagemagick", out["favicon"]
      assert_equal 20, out["frames"]
      assert_equal 1, out["orientation"]
      assert_equal "raised", out["vips_pin"], "explicit backend: :vips must fail closed"
    end
  end
end
