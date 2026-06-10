# frozen_string_literal: true

require "open3"
require_relative "test_helper"

module SafeImage
  # Hostile input is routine for this gem; libvips' GLib warnings about it
  # must not litter stderr (test output, production logs). Failures still
  # surface as exceptions. SAFE_IMAGE_VIPS_WARNINGS=1 restores the warnings.
  class VipsLogSilenceTest < TestCase
    SCRIPT = <<~'RUBY'
      require "safe_image"
      begin
        SafeImage.probe(ARGV[0])
      rescue SafeImage::InvalidImageError
        print "rejected"
      end
    RUBY

    def test_rejected_input_does_not_write_vips_warnings_to_stderr
      stdout, stderr, = run_probe({})

      assert_equal "rejected", stdout
      refute_match(/VIPS-WARNING/, stderr, "GLib warnings leaked to stderr")
    end

    def test_opt_out_keeps_the_warnings
      _stdout, stderr, = run_probe({ "SAFE_IMAGE_VIPS_WARNINGS" => "1" })

      assert_match(/VIPS-WARNING/, stderr)
    end

    private

    def run_probe(env)
      fake = write_tmp("fake.png", "not a png")
      Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", SCRIPT, fake)
    end
  end
end
