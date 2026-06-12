# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class ConvertTest < TestCase
    def test_native_convert_flattens_alpha_onto_white_like_imagemagick
      # Native.convert directly: the public path may encode generated JPEGs with
      # cjpegli when it is installed, and this test pins the vips flatten behaviour.
      Native.convert(PNG, tmp_path("v.jpg"), "jpg", 85, PNG_PIXELS)

      configure_safe_image(backend: :imagemagick)
      im_result = SafeImage.convert(PNG, tmp_path("i.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
      assert_equal "imagemagick", im_result.backend

      configure_safe_image(backend: :vips)
      vips_color = SafeImage.dominant_color(tmp_path("v.jpg"))
      im_color = SafeImage.dominant_color(tmp_path("i.jpg"))
      vips_color.scan(/../).zip(im_color.scan(/../)).each do |v, m|
        assert_in_delta v.to_i(16), m.to_i(16), 4, "flatten drift (vips=#{vips_color} imagemagick=#{im_color})"
      end
    end

    def test_heic_to_jpeg_no_longer_needs_imagemagick
      result = heic_or_skip do
        SafeImage.convert(HEIC, tmp_path("h.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
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

    def test_ico_input_fails_closed_on_the_vips_backend
      assert_raises(UnsupportedFormatError) do
        SafeImage.convert(ICO, tmp_path("o.png"), format: "png")
      end
    end

    def test_ico_input_converts_with_the_imagemagick_backend
      configure_safe_image(backend: :imagemagick)
      result = SafeImage.convert(ICO, tmp_path("o.png"), format: "png")

      assert_equal "imagemagick", result.backend
    end
  end
end
