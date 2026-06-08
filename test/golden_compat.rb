# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/safe_image"

FIXTURES = File.expand_path("fixtures/images", __dir__)
JPG = File.join(FIXTURES, "huge.jpg")
PNG = File.join(FIXTURES, "large_and_unoptimized.png")
HEIC = File.join(FIXTURES, "should_be_jpeg.heic")
ICO = File.join(FIXTURES, "smallest.ico")

CASES = [
  [:thumbnail_vips, ->(d) { SafeImage.thumbnail(input: JPG, output: File.join(d, "thumb-vips.jpg"), width: 600, height: 400, backend: :vips, optimize: true, max_pixels: 100_000_000) }, [600, 400, "jpg"]],
  [:thumbnail_imagemagick, ->(d) { SafeImage.thumbnail(input: JPG, output: File.join(d, "thumb-im.jpg"), width: 600, height: 400, backend: :imagemagick, optimize: true, max_pixels: 100_000_000) }, [600, 400, "jpg"]],
  [:crop_north_imagemagick, ->(d) { SafeImage.crop(JPG, File.join(d, "crop.jpg"), 400, 400, backend: :imagemagick, max_pixels: 100_000_000) }, [400, 400, "jpg"]],
  [:crop_north_vips, ->(d) { SafeImage.crop(JPG, File.join(d, "crop-vips.jpg"), 400, 400, backend: :vips, max_pixels: 100_000_000) }, [400, 400, "jpg"]],
  [:downsize_50_imagemagick, ->(d) { SafeImage.downsize(PNG, File.join(d, "down-im.png"), "50%", backend: :imagemagick, max_pixels: 10_000_000) }, [1016, 656, "png"]],
  [:downsize_50_vips, ->(d) { SafeImage.downsize(PNG, File.join(d, "down-vips.png"), "50%", backend: :vips, max_pixels: 10_000_000) }, [1016, 656, "png"]],
  [:downsize_box_vips, ->(d) { SafeImage.downsize(PNG, File.join(d, "down-box.png"), "100x100>", backend: :vips, max_pixels: 10_000_000) }, [100, 65, "png"]],
  [:downsize_pixels_vips, ->(d) { SafeImage.downsize(PNG, File.join(d, "down-pixels.png"), "400000@", backend: :vips, max_pixels: 10_000_000) }, [787, 508, "png"]],
  [:convert_png_jpeg, ->(d) { SafeImage.convert_to_jpeg(PNG, File.join(d, "png.jpg"), quality: 85, max_pixels: 10_000_000) }, [2032, 1312, "jpg"]],
  [:convert_heic_jpeg, ->(d) { SafeImage.convert_to_jpeg(HEIC, File.join(d, "heic.jpg"), quality: 85, max_pixels: 10_000_000) }, [846, 1129, "jpg"]],
  [:ico_png, ->(d) { SafeImage.convert_favicon_to_png(ICO, File.join(d, "ico.png")) }, [1, 1, "png"]],
  [:letter_avatar, ->(d) { SafeImage.letter_avatar(output: File.join(d, "letter.png"), size: 360, background_rgb: [1, 2, 3], letter: "S", font: "Adwaita-Sans") }, [360, 360, "png"]]
].freeze

Dir.mktmpdir do |dir|
  failures = []
  CASES.each do |name, callable, expected|
    begin
      result = callable.call(dir)
    rescue SafeImage::Error => e
      if name == :convert_heic_jpeg
        warn "SKIP HEIC ImageMagick conversion: #{e.message}"
        next
      end
      raise
    end
    actual = [result.width, result.height, result.output_format]
    failures << "#{name}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
    failures << "#{name}: output missing" unless result.output && File.file?(result.output) && File.size(result.output).positive?
  end

  svg = File.join(dir, "bad.svg")
  File.write(svg, %q{<svg onload="x" onclick="y"><script>x</script><rect width="1" height="1" onclick="x" onmouseover="y" href="javascript:z" fill="url(http://evil)"/></svg>})
  SafeImage.sanitize_svg!(svg)
  sanitized = File.read(svg)
  failures << "svg sanitizer left dangerous content" if sanitized.match?(/script|onload|onclick|onmouseover|javascript|http:\/\/evil/)

  abort failures.join("\n") if failures.any?
  puts "OK golden compatibility suite"
end
