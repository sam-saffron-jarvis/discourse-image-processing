# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class OrientationTest < TestCase
    def test_reads_exif_orientation_natively
      path = oriented_jpg("o6.jpg", 6, width: 192, height: 128)

      assert_equal 6, SafeImage.orientation(path)
      assert_equal 6, ImageMagickBackend.orientation(path), "backends disagree"
    end

    def test_clamps_garbage_orientation_tags
      assert_equal 1, SafeImage.orientation(oriented_jpg("o99.jpg", 99, width: 64, height: 64))
    end

    def test_defaults_to_upright
      assert_equal 1, SafeImage.orientation(JPG)
      assert_equal 1, SafeImage.orientation(PNG)
      assert_equal 1, SafeImage.orientation(ICO)
      assert_equal 1, SafeImage.orientation(write_tmp("icon.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>'))
    end

    def test_fix_orientation_uses_jpegtran_for_mcu_aligned_jpegs
      skip "jpegtran unavailable" unless Runner.available?("jpegtran")
      path = oriented_jpg("aligned.jpg", 6, width: 192, height: 128)

      result = SafeImage.fix_orientation(path, tmp_path("fixed.jpg"))

      assert_equal "jpegtran", result.backend
      assert_result result, width: 128, height: 192, format: "jpg"
      assert_equal 1, SafeImage.orientation(tmp_path("fixed.jpg"))
    end

    def test_fix_orientation_reencodes_non_aligned_jpegs
      path = oriented_jpg("ragged.jpg", 6, width: 201, height: 131)

      result = SafeImage.fix_orientation(path, tmp_path("fixed.jpg"))

      assert_equal "libvips-direct", result.backend
      assert_result result, width: 131, height: 201, format: "jpg"
      assert_equal 1, SafeImage.orientation(tmp_path("fixed.jpg"))
    end

    def test_fix_orientation_in_place
      path = oriented_jpg("inplace.jpg", 6, width: 192, height: 128)

      SafeImage.fix_orientation(path)

      assert_equal 1, SafeImage.orientation(path)
      assert_equal [128, 192], SafeImage.size(path)
    end

    def test_fix_orientation_imagemagick_backend_remains_available
      path = oriented_jpg("im.jpg", 6, width: 192, height: 128)

      result = SafeImage.fix_orientation(path, tmp_path("fixed.jpg"), backend: :imagemagick)

      assert_equal "imagemagick", result.backend
      assert_result result, width: 128, height: 192, format: "jpg"
    end

    def test_fix_orientation_rejects_invalid_quality
      path = oriented_jpg("q.jpg", 6, width: 201, height: 131)

      assert_raises(ArgumentError) { SafeImage.fix_orientation(path, tmp_path("fixed.jpg"), quality: 9000) }
    end

    def test_fix_orientation_rejects_unknown_backend
      assert_raises(ArgumentError) { SafeImage.fix_orientation(JPG, tmp_path("fixed.jpg"), backend: :gd) }
    end

    private

    # Renders a JPEG of the given dimensions and splices in a minimal EXIF
    # APP1 segment carrying the orientation tag.
    def oriented_jpg(name, orientation, width:, height:)
      plain = tmp_path("plain-#{name}")
      SafeImage.thumbnail(input: PNG, output: plain, width: width, height: height, max_pixels: PNG_PIXELS)
      jpg = File.binread(plain)
      tiff = "II".b + [42, 8].pack("vV") + [1].pack("v") + [0x0112, 3, 1, orientation, 0].pack("vvVvv") + [0].pack("V")
      app1 = "\xFF\xE1".b + [tiff.bytesize + 8].pack("n") + "Exif\0\0".b + tiff
      write_tmp(name, jpg[0, 2] + app1 + jpg[2..])
    end
  end
end
