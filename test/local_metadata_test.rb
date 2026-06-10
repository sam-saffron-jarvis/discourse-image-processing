# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class LocalMetadataTest < TestCase
    def test_type_sniffs_content
      assert_equal :jpeg, SafeImage.type(JPG)
      assert_equal :png, SafeImage.type(PNG)
    end

    def test_size_and_dimensions
      assert_equal [8900, 8900], SafeImage.size(JPG)
      assert_equal [2032, 1312], SafeImage.dimensions(PNG)
    end

    def test_orientation
      assert_equal 1, SafeImage.orientation(JPG).to_i
    end

    def test_animated_detection
      assert SafeImage.animated?(GIF, max_pixels: PNG_PIXELS)
      assert SafeImage.animated?(WEBP, max_pixels: PNG_PIXELS)
    end

    def test_gif_metadata_uses_the_native_loader
      assert_equal :gif, SafeImage.type(GIF, max_pixels: PNG_PIXELS)
      assert_equal [320, 320], SafeImage.size(GIF, max_pixels: PNG_PIXELS)
      assert_equal "libvips-direct", SafeImage.probe(GIF, max_pixels: PNG_PIXELS).backend
    end

    def test_jxl_metadata_uses_the_native_loader
      jxl_or_skip do
        assert_equal :jxl, SafeImage.type(JXL)
        assert_equal [400, 260], SafeImage.size(JXL)
        assert_equal "libvips-direct", SafeImage.probe(JXL).backend
      end
    end

    def test_frame_count
      assert_equal 20, SafeImage.frame_count(GIF, max_pixels: PNG_PIXELS)
      assert_equal 67, SafeImage.frame_count(WEBP, max_pixels: PNG_PIXELS)
      assert_equal 1, SafeImage.frame_count(JPG, max_pixels: JPG_PIXELS)
      # ico directories are counted by the pure-Ruby parser.
      assert_equal 1, SafeImage.frame_count(ICO)
    end

    def test_info_combines_metadata
      info = SafeImage.info(JPG, animated: true, orientation: true, max_pixels: JPG_PIXELS)

      assert_equal :jpeg, info.type
      assert_equal [8900, 8900], info.size
      assert_equal false, info.animated
      assert_equal 1, info.orientation.to_i
    end
  end
end
