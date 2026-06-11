# frozen_string_literal: true

require "fileutils"
require_relative "test_helper"

module SafeImage
  # Runs the whole public API with the Landlock sandbox configured to prove
  # every operation works through atomic sandboxed child processes. Sandbox
  # results cross a process boundary, so hashes may come back with string
  # keys where the inline path uses symbols.
  class SandboxIntegrationTest < TestCase
    def setup
      super
      skip "Landlock::SafeExec unavailable" unless SafeImage.sandbox_available?
      configure_safe_image(landlock: true)
    end

    def test_sandbox_reports_configured
      assert SafeImage.config.landlock
      assert_predicate SafeImage, :sandbox?
    end

    def test_metadata_helpers
      assert_equal :jpeg, SafeImage.type(JPG, max_pixels: JPG_PIXELS)
      assert_equal [8900, 8900], SafeImage.size(JPG, max_pixels: JPG_PIXELS)
      assert_equal [2032, 1312], SafeImage.dimensions(PNG, max_pixels: PNG_PIXELS)
      assert_equal 1, SafeImage.orientation(JPG, max_pixels: JPG_PIXELS).to_i
      assert_match(/\A\h{6}\z/, SafeImage.dominant_color(PNG, max_pixels: PNG_PIXELS))

      info = SafeImage.info(JPG, animated: true, orientation: true, max_pixels: JPG_PIXELS)
      assert_equal [8900, 8900], [info.width, info.height]
      assert_equal :jpeg, info.type.to_sym
      assert_equal false, info.animated
    end

    def test_probe
      probe = SafeImage.probe(JPG, max_pixels: JPG_PIXELS)
      assert_equal [8900, 8900], [probe.width, probe.height]
    end

    def test_thumbnail_and_resize
      thumb = SafeImage.thumbnail(input: JPG, output: tmp_path("thumb.jpg"), width: 600, height: 400, optimize: true, max_pixels: JPG_PIXELS)
      assert_result thumb, width: 600, height: 400

      resized = SafeImage.resize(JPG, tmp_path("resize.jpg"), 600, 400, optimize: true, max_pixels: JPG_PIXELS)
      assert_result resized, width: 600, height: 400
    end

    def test_crop_with_both_backends
      vips = SafeImage.crop(JPG, tmp_path("crop-vips.jpg"), 400, 400, optimize: true, max_pixels: JPG_PIXELS)
      assert_result vips, width: 400, height: 400

      configure_safe_image(backend: :imagemagick, landlock: true)
      im = SafeImage.crop(JPG, tmp_path("crop-im.jpg"), 400, 400, optimize: true, max_pixels: JPG_PIXELS)
      assert_result im, width: 400, height: 400
    end

    def test_downsize_with_both_backends
      vips = SafeImage.downsize(PNG, tmp_path("down-vips.png"), "50%", max_pixels: PNG_PIXELS)
      assert_result vips, width: 1016, height: 656

      configure_safe_image(backend: :imagemagick, landlock: true)
      im = SafeImage.downsize(PNG, tmp_path("down-im.png"), "50%", max_pixels: PNG_PIXELS)
      assert_result im, width: 1016, height: 656
    end

    def test_convert
      png = SafeImage.convert(PNG, tmp_path("png.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
      assert_result png, width: 2032, height: 1312

      heic = heic_or_skip do
        SafeImage.convert(HEIC, tmp_path("heic.jpg"), format: "jpg", quality: 85, max_pixels: PNG_PIXELS)
      end
      assert_result heic, width: 846, height: 1129
    end

    def test_fix_orientation
      result = SafeImage.fix_orientation(JPG, tmp_path("oriented.jpg"), max_pixels: JPG_PIXELS)
      assert_file_written result.output if result.respond_to?(:output) && result.output
    end

    def test_convert_favicon_to_png
      result = SafeImage.convert_favicon_to_png(ICO, tmp_path("ico.png"), max_pixels: PNG_PIXELS)
      assert_result result, width: 1, height: 1
    end

    def test_letter_avatar
      result = SafeImage.letter_avatar(output: tmp_path("letter.png"), size: 360, background_rgb: [1, 2, 3], letter: "S", font: "Adwaita-Sans")
      assert_result result, width: 360, height: 360
    end

    def test_animation_helpers
      frame_count = SafeImage.frame_count(GIF, max_pixels: PNG_PIXELS)
      assert_operator frame_count, :>, 1
      assert SafeImage.animated?(GIF, max_pixels: PNG_PIXELS)
    end

    def test_thumbnail_of_animated_webp
      result = SafeImage.thumbnail(input: WEBP, output: tmp_path("webp.jpg"), width: 120, height: 120, max_pixels: PNG_PIXELS)
      assert_result result, width: 120, height: 120
    end

    def test_sanitize_svg
      svg = write_tmp("bad.svg", %q{<svg onload="x"><script>x</script><rect width="1" height="1" onclick="x"/></svg>})

      result = SafeImage.sanitize_svg!(svg, id_namespace: :standalone)
      assert result["sanitized"] || result[:sanitized], "sanitize_svg! did not report sanitizing"
      refute_match(/script|onload|onclick/, File.read(svg), "svg still unsafe")
    end

    # The :standalone symbol must survive JSON transport to the worker, not
    # arrive as the string "standalone" and be treated as a real namespace.
    def test_sanitize_svg_standalone_symbol_crosses_sandbox
      svg = write_tmp("standalone.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <defs><linearGradient id="g"/></defs>
          <rect fill="url(#g)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(svg, id_namespace: :standalone)
      cleaned = File.read(svg)

      assert_includes cleaned, "id='g'", "standalone produced a namespaced id through the sandbox"
      assert_includes cleaned, "url(#g)", "standalone namespaced a reference through the sandbox"
      refute_includes cleaned, "standalone-", "the :standalone symbol leaked as a namespace"
    end

    # The documented ArgumentError for a missing/invalid id_namespace must be
    # raised by the parent before the worker launches, not surface as a sandbox
    # CommandError.
    def test_sanitize_svg_namespace_validation_raises_argument_error
      svg = write_tmp("v.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"/>')
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(svg) }
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(svg, id_namespace: nil) }
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(svg, id_namespace: "") }
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(svg, id_namespace: "bad/ns") }
    end

    def test_sanitize_svg_string_namespace_crosses_sandbox
      svg = write_tmp("ns.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <defs><linearGradient id="g"/></defs>
          <rect fill="url(#g)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(svg, id_namespace: "u1")
      cleaned = File.read(svg)

      assert_includes cleaned, "id='u1-g'", "string namespace not applied through the sandbox"
      assert_includes cleaned, "url(#u1-g)", "reference not namespaced through the sandbox"
    end

    def test_optimize
      jpg = tmp_path("opt.jpg")
      FileUtils.cp(JPG, jpg)

      result = SafeImage.optimize(jpg, strict: true)
      assert_includes result.fetch("tools") { result.fetch(:tools) }, "jpegoptim"
    end

    def test_optimize_image!
      jpg = tmp_path("opt-bang.jpg")
      FileUtils.cp(JPG, jpg)

      result = SafeImage.optimize_image!(jpg, strict: true)
      assert_includes result.fetch("tools") { result.fetch(:tools) }, "jpegoptim"
    end
  end
end
