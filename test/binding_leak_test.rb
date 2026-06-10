# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # The Fiddle binding owns GObject reference counting; a pairing bug shows
  # up as monotonic RSS growth, not a test failure. Hammer a representative
  # mix of operations and assert memory stays bounded.
  class BindingLeakTest < TestCase
    ITERATIONS = 50
    ALLOWED_GROWTH_KB = 30_000

    def test_repeated_operations_do_not_leak
      skip "requires /proc" unless File.readable?("/proc/self/status")

      # Warm caches, lazy init and allocator pools.
      5.times { exercise }
      GC.start
      before = rss_kb

      ITERATIONS.times { exercise }
      GC.start
      after = rss_kb

      assert_operator after - before, :<, ALLOWED_GROWTH_KB,
        "RSS grew #{after - before}KB over #{ITERATIONS} iterations; the binding is likely leaking references"
    end

    private

    # Touches every GValue shape the binding uses: loaders (enum args),
    # savers (bool/int/flags), stats (matrix read), text + linear (string and
    # double-array args) and the raw-memory PNG encoder.
    def exercise
      SafeImage.size(GIF, max_pixels: PNG_PIXELS)
      SafeImage.dominant_color(GIF, max_pixels: PNG_PIXELS, backend: :vips)
      SafeImage.thumbnail(input: GIF, output: tmp_path("leak.jpg"), width: 64, height: 64, optimize: false, max_pixels: PNG_PIXELS)
      SafeImage.letter_avatar(output: tmp_path("leak.png"), size: 64, background_rgb: [1, 2, 3], letter: "S", backend: :vips)
      Native.png_from_rgba("\xFF\x00\x00\xFF".b * 64, 8, 8, tmp_path("leak-rgba.png"))
    end

    def rss_kb
      File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
    end
  end
end
