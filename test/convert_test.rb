# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class ConvertTest < TestCase
    def test_native_convert_flattens_alpha_onto_white_like_imagemagick
      vips_result = SafeImage.convert(PNG, tmp_path("v.jpg"), format: "jpg", quality: 85, encoder: :vips, max_pixels: PNG_PIXELS)
      im_result = SafeImage.convert(PNG, tmp_path("i.jpg"), format: "jpg", quality: 85, backend: :imagemagick, max_pixels: PNG_PIXELS)

      assert_equal "libvips-direct", vips_result.backend
      assert_equal "imagemagick", im_result.backend
      vips_color = SafeImage.dominant_color(tmp_path("v.jpg"))
      im_color = SafeImage.dominant_color(tmp_path("i.jpg"))
      vips_color.scan(/../).zip(im_color.scan(/../)).each do |v, m|
        assert_in_delta v.to_i(16), m.to_i(16), 4, "flatten drift (vips=#{vips_color} imagemagick=#{im_color})"
      end
    end

    def test_heic_to_jpeg_no_longer_needs_imagemagick
      result = heic_or_skip do
        SafeImage.convert(HEIC, tmp_path("h.jpg"), format: "jpg", quality: 85, encoder: :vips, max_pixels: PNG_PIXELS)
      end

      assert_equal "libvips-direct", result.backend
      assert_result result, width: 846, height: 1129, format: "jpg"
    end

    def test_jxl_to_jpeg_converts_natively
      result = jxl_or_skip do
        SafeImage.convert(JXL, tmp_path("x.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
      end

      assert_equal "libvips-direct", result.backend
      assert_result result, width: 400, height: 260, format: "jpg"
    end

    def test_gif_to_png_converts_natively
      result = SafeImage.convert(GIF, tmp_path("g.png"), format: "png", max_pixels: PNG_PIXELS)

      assert_equal "libvips-direct", result.backend
      assert_result result, width: 320, height: 320, format: "png"
    end

    def test_ico_input_falls_back_to_imagemagick_under_auto
      result = SafeImage.convert(ICO, tmp_path("o.png"), format: "png")

      assert_equal "imagemagick", result.backend
    end

    def test_backend_vips_is_fail_closed
      assert_raises(UnsupportedFormatError) do
        SafeImage.convert(ICO, tmp_path("o.png"), format: "png", backend: :vips)
      end
    end

    def test_legacy_encoder_imagemagick_routes_through_imagemagick
      result = SafeImage.convert(PNG, tmp_path("l.jpg"), format: "jpg", encoder: :imagemagick, max_pixels: PNG_PIXELS)

      assert_equal "imagemagick", result.backend
    end

    def test_conflicting_backend_and_encoder_raise
      assert_raises(ArgumentError) do
        SafeImage.convert(PNG, tmp_path("x.jpg"), format: "jpg", backend: :imagemagick, encoder: :cjpegli)
      end
    end

    def test_rejects_unknown_backend
      assert_raises(ArgumentError) do
        SafeImage.convert(PNG, tmp_path("x.jpg"), format: "jpg", backend: :gd)
      end
    end
  end
end
