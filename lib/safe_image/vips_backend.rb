# frozen_string_literal: true

module SafeImage
  module VipsBackend
    module_function

    DIMENSIONS_RE = /\A(?:(?<percent>\d+(?:\.\d+)?)%|(?<w>\d*)x(?<h>\d*)(?<only_down>>)?|(?<pixels>\d+)@)\z/

    def crop_north(input:, output:, width:, height:, format:, quality: 85, max_pixels: nil)
      Native.crop_north(input.to_s, output.to_s, Integer(width), Integer(height), format.to_s, Integer(quality), max_pixels)
    end

    def downsize(input:, output:, dimensions:, format:, quality: 85, max_pixels: nil)
      probe = SafeImage.probe(input, max_pixels: max_pixels)
      scale = scale_for(probe.width, probe.height, dimensions)
      # Never upscale, but always re-encode through the native saver — even on a
      # no-op scale of 1.0 — so the output is metadata-stripped rather than a
      # verbatim copy of the untrusted input bytes.
      scale = [scale, 1.0].min
      Native.resize(input.to_s, output.to_s, scale, normalized_format(format), Integer(quality), max_pixels)
    end

    def dominant_color(input, max_pixels: nil)
      input = PathSafety.ensure_regular_file!(input).to_s
      rgb = Native.dominant_color(input, max_pixels)
      format("%02X%02X%02X", *rgb)
    end

    def frame_count(input, max_pixels: nil)
      input = PathSafety.ensure_regular_file!(input).to_s
      Native.pages(input, max_pixels)
    end

    def orientation(input, max_pixels: nil)
      input = PathSafety.ensure_regular_file!(input).to_s
      Native.orientation(input, max_pixels)
    end

    # Maps the public font tokens (shared with the ImageMagick backend) to
    # Pango family names. DejaVu Sans additionally pins the font file bundled
    # with the gem, so its rendering does not depend on host fonts.
    BUNDLED_DEJAVU = File.expand_path("fonts/DejaVuSans.ttf", __dir__)
    PANGO_FONTS = {
      "DejaVu-Sans" => ["DejaVu Sans", BUNDLED_DEJAVU],
      "NimbusSans-Regular" => ["Nimbus Sans", nil],
      "Liberation-Sans" => ["Liberation Sans", nil],
      "Arial" => ["Arial", nil],
      "Helvetica" => ["Helvetica", nil],
      "Adwaita-Sans" => ["Adwaita Sans", nil]
    }.freeze

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "DejaVu-Sans")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      size = Integer(size)
      raise ArgumentError, "size must be 1..4096" unless (1..4096).cover?(size)
      pointsize = Integer(pointsize)
      raise ArgumentError, "pointsize must be 1..2000" unless (1..2000).cover?(pointsize)
      rgb = Array(background_rgb).map { |value| Integer(value) }
      unless rgb.length == 3 && rgb.all? { |value| (0..255).cover?(value) }
        raise ArgumentError, "background_rgb must have three channels in 0..255"
      end
      family, fontfile = PANGO_FONTS.fetch(font.to_s) { raise ArgumentError, "unsupported font: #{font.to_s.inspect}" }
      fontfile = nil unless fontfile && File.file?(fontfile)

      # vips_text parses Pango markup, and the glyph derives from user input.
      glyph = letter.to_s.each_grapheme_cluster.first.to_s.strip
      markup = glyph.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      Native.letter_avatar(output, size, rgb[0], rgb[1], rgb[2], markup, "#{family} #{pointsize}", fontfile.to_s)
      {
        input_format: "generated",
        output_format: "png",
        width: size,
        height: size,
        duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      }
    end

    def normalized_format(format)
      format = format.to_s.downcase
      format == "jpeg" ? "jpg" : format
    end

    def scale_for(width, height, dimensions)
      dimensions = dimensions.to_s
      match = DIMENSIONS_RE.match(dimensions) or raise ArgumentError, "unsupported dimensions: #{dimensions.inspect}"

      if match[:percent]
        return Float(match[:percent]) / 100.0
      end

      if match[:pixels]
        target_pixels = Float(match[:pixels])
        return Math.sqrt(target_pixels / (Integer(width) * Integer(height)))
      end

      target_w = match[:w].to_s.empty? ? nil : Float(match[:w])
      target_h = match[:h].to_s.empty? ? nil : Float(match[:h])
      scales = []
      scales << target_w / width if target_w
      scales << target_h / height if target_h
      raise ArgumentError, "missing width/height in dimensions: #{dimensions.inspect}" if scales.empty?
      scales.min
    end
  end
end
