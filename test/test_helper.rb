# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "tmpdir"

require "safe_image"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

module SafeImage
  # Base class for all SafeImage tests: shared fixtures, a lazily created
  # per-test scratch directory, and assertions for the Result objects the
  # public API returns.
  class TestCase < Minitest::Test
    FIXTURES = File.expand_path("fixtures/images", __dir__)

    JPG = File.join(FIXTURES, "huge.jpg")                  # 8900x8900 JPEG
    PNG = File.join(FIXTURES, "large_and_unoptimized.png") # 2032x1312 PNG
    HEIC = File.join(FIXTURES, "should_be_jpeg.heic")      # 846x1129 HEIC
    ICO = File.join(FIXTURES, "smallest.ico")              # 1x1 ICO
    GIF = File.join(FIXTURES, "animated.gif")              # animated GIF
    WEBP = File.join(FIXTURES, "animated.webp")            # animated WebP
    JXL = File.join(FIXTURES, "photo.jxl")                 # 400x260 JPEG XL

    # Pixel caps generous enough for the fixtures above. The cap behaviour
    # itself is exercised in PixelLimitTest.
    JPG_PIXELS = 100_000_000
    PNG_PIXELS = 10_000_000

    JPEG_MAGIC = "\xFF\xD8\xFF".b

    def teardown
      FileUtils.remove_entry(@tmpdir) if @tmpdir
      super
    end

    private

    def tmpdir
      @tmpdir ||= Dir.mktmpdir("safe_image-test-")
    end

    def tmp_path(name)
      File.join(tmpdir, name)
    end

    def write_tmp(name, content)
      tmp_path(name).tap { |path| File.write(path, content) }
    end

    def assert_file_written(path)
      assert_path_exists path
      assert_operator File.size(path), :>, 0, "expected #{path} to be non-empty"
    end

    def assert_jpeg_magic(path)
      assert_equal JPEG_MAGIC, File.binread(path, 3), "expected #{path} to start with the JPEG magic bytes"
    end

    # Asserts an operation Result: reported dimensions, optionally the
    # reported format, and a non-empty output file on disk.
    def assert_result(result, width:, height:, format: nil)
      assert_equal [width, height], [result.width, result.height], "result dimensions"
      assert_equal format, result.output_format, "result output format" if format
      assert_file_written(result.output) if result.respond_to?(:output) && result.output
    end

    # HEIC decoding depends on the installed ImageMagick delegates, so treat
    # a decode failure as an environment gap rather than a regression.
    def heic_or_skip
      yield
    rescue SafeImage::Error => e
      skip "HEIC is not supported by the installed ImageMagick delegates: #{e.message}"
    end

    # GIF output depends on libvips being built with cgif support, so treat a
    # missing saver as an environment gap rather than a regression.
    def gif_save_or_skip
      yield
    rescue SafeImage::UnsupportedFormatError => e
      raise unless e.message.include?("cannot save GIF")
      skip "GIF output is not supported by this libvips build: #{e.message}"
    end

    # JPEG XL support is optional at libvips build time.
    def jxl_or_skip
      yield
    rescue SafeImage::UnsupportedFormatError => e
      raise unless e.message.include?("JPEG XL")
      skip "JPEG XL is not supported by this libvips build: #{e.message}"
    end
  end
end
