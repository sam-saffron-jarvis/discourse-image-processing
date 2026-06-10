# frozen_string_literal: true

require "open3"
require_relative "test_helper"

module SafeImage
  # Pixel-for-pixel parity between this gem's ImageMagick-compatible
  # operations and the reference `convert` pipelines they replace.
  class ImageMagickParityTest < TestCase
    PROFILE = File.expand_path("../lib/safe_image/RT_sRGB.icm", __dir__)

    def test_resize_matches_reference_pipeline
      expected = tmp_path("reference.jpg")
      reference_convert(
        "jpeg:#{JPG}[0]", "-auto-orient", "-gravity", "center", "-background", "transparent",
        "-thumbnail", "600x400^", "-extent", "600x400", "-interpolate", "catrom",
        "-unsharp", "2x0.5+0.7+0", "-interlace", "none", "-profile", PROFILE, expected
      )

      actual = tmp_path("actual.jpg")
      SafeImage.resize(JPG, actual, 600, 400, backend: :imagemagick, optimize: false)

      assert_pixel_identical expected, actual
    end

    def test_crop_matches_reference_pipeline
      expected = tmp_path("reference.jpg")
      reference_convert(
        "jpeg:#{JPG}[0]", "-auto-orient", "-gravity", "north", "-background", "transparent",
        "-thumbnail", "400x400^", "-crop", "400x400+0+0", "-unsharp", "2x0.5+0.7+0",
        "-interlace", "none", "-profile", PROFILE, expected
      )

      actual = tmp_path("actual.jpg")
      SafeImage.crop(JPG, actual, 400, 400, backend: :imagemagick, optimize: false)

      assert_pixel_identical expected, actual
    end

    def test_downsize_matches_reference_pipeline
      expected = tmp_path("reference.png")
      reference_convert(
        "png:#{PNG}[0]", "-auto-orient", "-gravity", "center", "-background", "transparent",
        "-interlace", "none", "-resize", "50%", "-profile", PROFILE, expected
      )

      actual = tmp_path("actual.png")
      SafeImage.downsize(PNG, actual, "50%", backend: :imagemagick, optimize: false)

      assert_pixel_identical expected, actual
    end

    private

    def reference_convert(*args)
      system(ImageMagickBackend.convert_command, *args, exception: true)
    end

    def assert_pixel_identical(expected, actual)
      _stdout, stderr, _status = Open3.capture3("compare", "-metric", "AE", expected, actual, "null:")
      metric = stderr.strip
      assert_includes ["0", "0 (0)"], metric, "expected pixel parity, got AE #{metric}"
    end
  end
end
