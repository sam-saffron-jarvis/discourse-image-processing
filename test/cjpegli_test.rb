# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # The optional cjpegli encoder is availability-driven, like the optimizer
  # tools: installed means used for JPEG output on the vips backend, absent
  # means the backend encodes. It is never offered as a configuration knob.
  class CjpegliTest < TestCase
    # Last-resort stub: Runner resolves binaries from a hardcoded
    # TRUSTED_PATH and ignores ENV["PATH"], so an installed cjpegli cannot
    # be made genuinely unavailable from a test.
    def test_convert_uses_the_native_encoder_when_cjpegli_is_unavailable
      JpegliBackend.stub(:available?, false) do
        result = SafeImage.convert(PNG, tmp_path("native.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)

        assert_equal "libvips-direct", result.backend
        assert_jpeg_magic tmp_path("native.jpg")
      end
    end

    def test_imagemagick_backend_produces_jpeg_without_cjpegli
      configure_safe_image(backend: :imagemagick)
      out = tmp_path("magick.jpg")
      result = SafeImage.convert(PNG, out, format: "jpg", quality: 85, max_pixels: PNG_PIXELS)

      assert_equal "imagemagick", result.backend
      assert_jpeg_magic out
    end

    def test_convert_uses_cjpegli_for_png_input_after_native_decode
      require_cjpegli!
      out = tmp_path("converted.jpg")
      result = SafeImage.convert(PNG, out, format: "jpg", quality: 85, max_pixels: PNG_PIXELS)

      assert_equal "libvips-direct+cjpegli", result.backend
      assert_jpeg_magic out
      assert_equal :jpeg, SafeImage.type(out, max_pixels: PNG_PIXELS)
    end

    def test_convert_to_jpeg_respects_pixel_cap_before_cjpegli_encode
      assert_raises(LimitError) do
        SafeImage.convert(PNG, tmp_path("too-big.jpg"), format: "jpg", quality: 85, max_pixels: 1)
      end
    end

    def test_convert_falls_back_to_vips_for_heic_input
      require_cjpegli!
      result = heic_or_skip do
        SafeImage.convert(HEIC, tmp_path("heic.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
      end

      refute_equal "cjpegli", result.backend, "cjpegli cannot decode HEIC directly"
    end

    def test_thumbnail_uses_cjpegli_when_installed
      require_cjpegli!
      out = tmp_path("thumb.jpg")
      result = SafeImage.thumbnail(input: JPG, output: out, width: 320, height: 200, max_pixels: JPG_PIXELS)

      assert_includes result.backend, "cjpegli"
      assert_result result, width: 320, height: 200
      assert_jpeg_magic out
    end

    def test_thumbnail_on_the_imagemagick_backend_never_uses_cjpegli
      configure_safe_image(backend: :imagemagick)
      result = SafeImage.thumbnail(input: JPG, output: tmp_path("im.jpg"), width: 60, height: 40, max_pixels: JPG_PIXELS)

      assert_equal "imagemagick", result.backend
    end

    def test_crop_uses_cjpegli_when_installed
      require_cjpegli!
      out = tmp_path("crop.jpg")
      result = SafeImage.crop(JPG, out, 200, 160, max_pixels: JPG_PIXELS)

      assert_includes result.backend, "cjpegli"
      assert_result result, width: 200, height: 160
      assert_jpeg_magic out
    end

    def test_downsize_uses_cjpegli_when_installed
      require_cjpegli!
      out = tmp_path("down.jpg")
      result = SafeImage.downsize(PNG, out, "320x200>", max_pixels: PNG_PIXELS)

      assert_includes result.backend, "cjpegli"
      assert_jpeg_magic out
    end

    def test_thumbnail_from_png_source_with_auto_chroma_subsampling
      require_cjpegli!
      out = tmp_path("thumb-from-png.jpg")
      result = SafeImage.thumbnail(
        input: PNG, output: out,
        width: 320, height: 200, chroma_subsampling: :auto, max_pixels: PNG_PIXELS
      )

      assert_includes result.backend, "cjpegli"
      assert_jpeg_magic out
    end

    private

    def require_cjpegli!
      skip "cjpegli is not installed" unless JpegliBackend.available?
    end
  end
end
