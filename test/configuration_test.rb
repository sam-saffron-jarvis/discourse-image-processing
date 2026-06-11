# frozen_string_literal: true

require "open3"
require "json"
require_relative "test_helper"

module SafeImage
  # configure! is the single place backend, sandbox and the pixel ceiling are
  # decided. Operations before it raise; validation is eager; re-calling it
  # replaces the configuration atomically.
  class ConfigurationTest < TestCase
    # The suite configures SafeImage in setup, so the unconfigured state is
    # exercised in a fresh subprocess — including a pure-Ruby operation and a
    # remote fetch, which must fail before any file or network I/O.
    UNCONFIGURED_SCRIPT = <<~'RUBY'
      require "safe_image"
      require "json"

      out = {}
      attempts = {
        "probe" => -> { SafeImage.probe(ENV["JPG"]) },
        "thumbnail" => -> { SafeImage.thumbnail(input: ENV["JPG"], output: File.join(ENV["OUT"], "x.jpg"), width: 1, height: 1) },
        "dominant_color" => -> { SafeImage.dominant_color(ENV["JPG"]) },
        "sanitize_svg!" => -> { SafeImage.sanitize_svg!(ENV["SVG"], id_namespace: :standalone) },
        "fetch_remote" => -> { SafeImage.fetch_remote("https://192.0.2.1/never-fetched.png") {} }
      }
      attempts.each do |name, attempt|
        attempt.call
        out[name] = "no error"
      rescue SafeImage::NotConfiguredError => e
        out[name] = e.message
      end
      out["configured?"] = SafeImage.configured?

      puts JSON.dump(out)
    RUBY

    def test_operations_before_configure_raise_not_configured
      svg = write_tmp("plain.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>')
      env = { "JPG" => JPG, "SVG" => svg, "OUT" => tmpdir }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", UNCONFIGURED_SCRIPT)

      assert status.success?, "unconfigured child process failed:\n#{stderr}"
      out = JSON.parse(stdout.lines.last)

      assert_equal false, out["configured?"]
      %w[probe thumbnail dominant_color sanitize_svg! fetch_remote].each do |operation|
        assert_includes out.fetch(operation), "SafeImage.configure!",
          "#{operation} must raise NotConfiguredError with the call to make"
      end
      refute_path_exists tmp_path("x.jpg"), "thumbnail ran before configure!"
    end

    def test_rejects_unknown_backend
      assert_raises(ArgumentError) { SafeImage.configure!(backend: :gd, landlock: false) }
    end

    def test_rejects_non_boolean_landlock
      assert_raises(ArgumentError) { SafeImage.configure!(backend: :vips, landlock: :maybe) }
    end

    def test_rejects_non_positive_max_pixels
      assert_raises(ArgumentError) { SafeImage.configure!(backend: :vips, landlock: false, max_pixels: 0) }
    end

    def test_reconfigure_last_wins
      configure_safe_image(backend: :imagemagick)
      assert_equal :imagemagick, SafeImage.config.backend

      configure_safe_image(backend: :vips)
      assert_equal :vips, SafeImage.config.backend
    end

    def test_failed_configure_keeps_the_previous_config
      configure_safe_image(backend: :vips)
      assert_raises(ArgumentError) { SafeImage.configure!(backend: :gd, landlock: false) }

      assert_equal :vips, SafeImage.config.backend
    end

    def test_string_backend_is_normalized
      configure_safe_image(backend: "imagemagick")

      assert_equal :imagemagick, SafeImage.config.backend
    end

    def test_config_is_frozen_with_the_default_pixel_ceiling
      assert_predicate SafeImage.config, :frozen?
      assert_equal DEFAULT_MAX_PIXELS, SafeImage.config.max_pixels
    end

    def test_configured_max_pixels_is_the_default_ceiling
      configure_safe_image(max_pixels: 1_000)

      assert_raises(LimitError) { SafeImage.probe(JPG) }
    end

    def test_per_call_max_pixels_overrides_the_configured_default
      configure_safe_image(max_pixels: 1_000)
      probe = SafeImage.probe(JPG, max_pixels: JPG_PIXELS)

      assert_equal [8900, 8900], [probe.width, probe.height]
    end
  end
end
