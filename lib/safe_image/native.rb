# frozen_string_literal: true

require_relative "vips_glue"

module SafeImage
  # The libvips fast path, implemented in pure Ruby on top of the VipsGlue
  # Fiddle binding (formerly a compiled C extension; the function surface and
  # messages are unchanged). Loaders are explicit per extension, every decode
  # enforces the pixel cap from the header before pixel data is touched, and
  # all images are released deterministically.
  module Native
    LOADERS = {
      "jpg" => "jpegload",
      "png" => "pngload",
      "webp" => "webpload",
      "gif" => "gifload",
      "heic" => "heifload",
      "avif" => "heifload",
      "jxl" => "jxlload"
    }.freeze

    class << self
      def probe(path)
        started = monotime
        VipsGlue.with_images do |track|
          image, format = load_image(track, String(path))
          {
            format: format,
            width: VipsGlue.width(image),
            height: VipsGlue.height(image),
            duration_ms: monotime - started
          }
        end
      end

      def thumbnail(input, output, width, height, format, quality, max_pixels)
        started = monotime
        input = String(input)
        output = String(output)
        width = Integer(width)
        height = Integer(height)
        quality = Integer(quality)
        raise ArgumentError, "width and height must be positive" if width <= 0 || height <= 0
        validate_quality!(quality)
        out_format = output_format!(format)

        VipsGlue.with_images do |track|
          # Header read through the explicit loader: validates the bytes and
          # enforces the pixel cap before any full decode.
          header, input_format = load_image(track, input)
          check_pixels!(header, max_pixels)

          # Thumbnail from the file so libvips can shrink on load (e.g.
          # libjpeg DCT downscaling); auto-rotates by default.
          thumb = track.call(
            VipsGlue.operation(
              "thumbnail",
              { filename: input, width: width, height: height,
                size: "both", crop: "centre", fail_on: "error" }
            )
          )
          save_image(thumb, output, out_format, quality)
          info(input_format, out_format, thumb, started)
        end
      end

      def resize(input, output, scale, format, quality, max_pixels)
        started = monotime
        scale = Float(scale)
        quality = Integer(quality)
        unless scale.finite? && scale.positive? && scale <= 100.0
          raise ArgumentError, "scale must be finite and in 0..100"
        end
        validate_quality!(quality)
        out_format = output_format!(format)

        VipsGlue.with_images do |track|
          image, input_format = load_image(track, String(input))
          check_pixels!(image, max_pixels)
          rotated = track.call(VipsGlue.operation("autorot", { in: image }))
          resized = track.call(VipsGlue.operation("resize", { in: rotated, scale: scale }))
          save_image(resized, String(output), out_format, quality)
          info(input_format, out_format, resized, started)
        end
      end

      def crop_north(input, output, width, height, format, quality, max_pixels)
        started = monotime
        width = Integer(width)
        height = Integer(height)
        quality = Integer(quality)
        raise ArgumentError, "width and height must be positive" if width <= 0 || height <= 0
        validate_quality!(quality)
        out_format = output_format!(format)

        VipsGlue.with_images do |track|
          image, input_format = load_image(track, String(input))
          check_pixels!(image, max_pixels)
          rotated = track.call(VipsGlue.operation("autorot", { in: image }))

          scale = [width.fdiv(VipsGlue.width(rotated)), height.fdiv(VipsGlue.height(rotated))].max * 1.0000001
          resized = track.call(VipsGlue.operation("resize", { in: rotated, scale: scale }))
          left = [(VipsGlue.width(resized) - width) / 2, 0].max
          cropped = track.call(
            VipsGlue.operation("extract_area", { input: resized, left: left, top: 0, width: width, height: height })
          )
          save_image(cropped, String(output), out_format, quality)
          info(input_format, out_format, cropped, started)
        end
      end

      def convert(input, output, format, quality, max_pixels)
        started = monotime
        quality = Integer(quality)
        validate_quality!(quality)
        out_format = output_format!(format)

        VipsGlue.with_images do |track|
          image, input_format = load_image(track, String(input))
          check_pixels!(image, max_pixels)
          rotated = track.call(VipsGlue.operation("autorot", { in: image }))

          # JPEG has no alpha; flatten onto white to match the ImageMagick
          # convert path (libvips composites onto black otherwise).
          final =
            if out_format == "jpg" && VipsGlue.alpha?(rotated)
              track.call(VipsGlue.operation("flatten", { in: rotated, background: [255.0, 255.0, 255.0] }))
            else
              rotated
            end
          save_image(final, String(output), out_format, quality)
          info(input_format, out_format, final, started)
        end
      end

      # Alpha-weighted average colour as [r, g, b] integers. Premultiplying
      # keeps parity with ImageMagick's resize-based average; per-band means
      # come from vips_stats (row b+1, column 4 of the stats matrix).
      def dominant_color(path, max_pixels)
        VipsGlue.with_images do |track|
          image, = load_image(track, String(path))
          check_pixels!(image, max_pixels)

          srgb =
            if VipsGlue.colourspace_supported?(image)
              track.call(VipsGlue.operation("colourspace", { in: image, space: "srgb" }))
            else
              image
            end
          has_alpha = VipsGlue.alpha?(srgb)
          work = has_alpha ? track.call(VipsGlue.operation("premultiply", { in: srgb })) : srgb

          stats = track.call(VipsGlue.operation("stats", { in: work }))
          columns = VipsGlue.width(stats)
          matrix = VipsGlue.image_bytes(stats).unpack("d*")
          mean = ->(band) { matrix[(band + 1) * columns + 4] || 0.0 }

          bands = VipsGlue.bands(work)
          colour_bands = has_alpha ? bands - 1 : bands
          colour_bands = colour_bands.clamp(1, 3)
          raise InvalidImageError, "image has no colour bands" if colour_bands < 1

          alpha_mean = has_alpha ? mean.call(bands - 1) : 255.0
          (0...3).map do |band|
            value = mean.call([band, colour_bands - 1].min)
            value = alpha_mean.positive? ? value * 255.0 / alpha_mean : 0.0 if has_alpha
            value.round.clamp(0, 255)
          end
        end
      end

      def pages(path, max_pixels)
        VipsGlue.with_images do |track|
          image, = load_image(track, String(path))
          check_pixels!(image, max_pixels)
          VipsGlue.pages(image)
        end
      end

      def orientation(path, max_pixels)
        VipsGlue.with_images do |track|
          image, = load_image(track, String(path))
          check_pixels!(image, max_pixels)
          value = VipsGlue.orientation(image)
          (1..8).cover?(value) ? value : 1
        end
      end

      # Encodes a raw RGBA buffer (top-down rows) as PNG. Used by the
      # pure-Ruby ICO decoder.
      def png_from_rgba(bytes, width, height, output)
        bytes = String(bytes)
        width = Integer(width)
        height = Integer(height)
        raise ArgumentError, "width and height must be positive" if width <= 0 || height <= 0
        raise LimitError, "rgba buffer dimensions exceed 4096x4096" if width > 4096 || height > 4096
        raise ArgumentError, "rgba buffer must be width*height*4 bytes" if bytes.bytesize != width * height * 4

        VipsGlue.with_images do |track|
          image = track.call(VipsGlue.image_from_memory(bytes, width, height, 4, 0)) # 0 = uchar
          srgb = track.call(VipsGlue.operation("copy", { in: image, interpretation: "srgb" }))
          save_image(srgb, String(output), "png", 100)
        end
        true
      end

      # Renders a letter avatar: a Pango glyph mask blended in white at 80%
      # opacity over a solid background via a single linear transform. The
      # markup string is escaped by the Ruby caller; font and fontfile come
      # from an allowlist.
      def letter_avatar(output, size, red, green, blue, markup, font, fontfile)
        size = Integer(size)
        markup = String(markup)
        font = String(font)
        fontfile = String(fontfile)
        channels = [Integer(red), Integer(green), Integer(blue)]
        raise ArgumentError, "size must be 1..4096" unless (1..4096).cover?(size)
        unless channels.all? { |value| (0..255).cover?(value) }
          raise ArgumentError, "background channels must be 0..255"
        end
        unless VipsGlue.type_find?("text")
          raise UnsupportedFormatError, "this libvips build has no text renderer (Pango support missing)"
        end

        VipsGlue.with_images do |track|
          mask =
            if markup.empty?
              # Blank letter: solid background only.
              track.call(VipsGlue.operation("black", { width: size, height: size }))
            else
              text_inputs = { text: markup, font: font, dpi: 72 }
              text_inputs[:fontfile] = fontfile unless fontfile.empty?
              text = track.call(VipsGlue.operation("text", text_inputs))

              # vips_text returns the tight ink box; crop to the canvas when
              # the pointsize overflows it, then centre the ink optically.
              text_w = VipsGlue.width(text)
              text_h = VipsGlue.height(text)
              if text_w > size || text_h > size
                crop_w = [text_w, size].min
                crop_h = [text_h, size].min
                text = track.call(
                  VipsGlue.operation(
                    "extract_area",
                    { input: text, left: (text_w - crop_w) / 2, top: (text_h - crop_h) / 2,
                      width: crop_w, height: crop_h }
                  )
                )
                text_w = crop_w
                text_h = crop_h
              end
              track.call(
                VipsGlue.operation(
                  "embed",
                  { in: text, x: (size - text_w) / 2, y: (size - text_h) / 2, width: size, height: size }
                )
              )
            end

          # blend = bg + (white - bg) * 0.8 * mask/255, one linear op.
          opacity = 204.0 / 255.0 # FFFFFFCC
          a = channels.map { |value| (255.0 - value) * opacity / 255.0 }
          blended = track.call(VipsGlue.operation("linear", { in: mask, a: a, b: channels.map(&:to_f) }))
          cast = track.call(VipsGlue.operation("cast", { in: blended, format: "uchar" }))
          srgb = track.call(VipsGlue.operation("copy", { in: cast, interpretation: "srgb" }))
          save_image(srgb, String(output), "png", 100)
        end
        true
      end

      private

      def monotime
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      def info(input_format, output_format, image, started)
        {
          input_format: input_format,
          output_format: output_format,
          width: VipsGlue.width(image),
          height: VipsGlue.height(image),
          duration_ms: monotime - started
        }
      end

      def normalized_format(ext)
        case ext.to_s.downcase
        when "jpg", "jpeg" then "jpg"
        when "png" then "png"
        when "webp" then "webp"
        when "gif" then "gif"
        when "heic", "heif" then "heic"
        when "avif" then "avif"
        when "jxl" then "jxl"
        end
      end

      def output_format!(format)
        normalized = normalized_format(String(format))
        raise UnsupportedFormatError, "unsupported output format" if normalized.nil? || normalized == "heic"
        normalized
      end

      def validate_quality!(quality)
        raise ArgumentError, "quality must be 1..100" unless (1..100).cover?(quality)
      end

      def load_image(track, path)
        format = normalized_format(File.extname(path).delete_prefix("."))
        raise UnsupportedFormatError, "unsupported input format" unless format

        case format
        when "gif"
          # libnsgif loader: first frame only (the n=1 default), matching the
          # [0] semantics of the ImageMagick compatibility backend.
          raise UnsupportedFormatError, "this libvips build has no GIF loader" unless VipsGlue.type_find?("gifload")
        when "jxl"
          raise UnsupportedFormatError, "this libvips build has no JPEG XL loader" unless VipsGlue.type_find?("jxlload")
        end

        image = track.call(
          VipsGlue.operation(LOADERS.fetch(format), { filename: path, access: "sequential", fail_on: "error" })
        )
        [image, format]
      end

      def check_pixels!(image, max_pixels)
        if max_pixels.nil?
          limit = DEFAULT_MAX_PIXELS
        else
          limit = Integer(max_pixels)
          raise ArgumentError, "max_pixels must be positive" if limit <= 0
        end
        width = VipsGlue.width(image)
        height = VipsGlue.height(image)
        raise InvalidImageError, "image dimensions are invalid" if width <= 0 || height <= 0
        pixels = width * height
        raise LimitError, "image has #{pixels} pixels, exceeds #{limit}" if pixels > limit
      end

      # libvips renamed the strip-metadata save option from "strip" to "keep"
      # (VIPS_FOREIGN_KEEP_NONE = 0) in 8.15; pick the spelling at runtime so
      # one gem build serves distro packages from 8.13 up.
      def strip_args
        @strip_args ||= (VipsGlue.version <=> [8, 15]) >= 0 ? { keep: 0 } : { strip: true }
      end

      def save_image(image, path, format, quality)
        case format
        when "jpg"
          VipsGlue.operation("jpegsave", { in: image, filename: path, Q: quality, interlace: false, **strip_args }, output: nil)
        when "png"
          VipsGlue.operation("pngsave", { in: image, filename: path, compression: 6, **strip_args }, output: nil)
        when "webp"
          VipsGlue.operation("webpsave", { in: image, filename: path, Q: quality, **strip_args }, output: nil)
        when "avif"
          VipsGlue.operation("heifsave", { in: image, filename: path, Q: quality, compression: "av1", **strip_args }, output: nil)
        when "gif"
          # cgif-backed saver; optional at libvips build time. GIF output is
          # palette-quantised and has no quality parameter.
          raise UnsupportedFormatError, "this libvips build cannot save GIF (cgif support missing)" unless VipsGlue.type_find?("gifsave")
          VipsGlue.operation("gifsave", { in: image, filename: path, **strip_args }, output: nil)
        when "jxl"
          raise UnsupportedFormatError, "this libvips build cannot save JPEG XL" unless VipsGlue.type_find?("jxlsave")
          VipsGlue.operation("jxlsave", { in: image, filename: path, Q: quality, **strip_args }, output: nil)
        else
          raise UnsupportedFormatError, "unsupported output format"
        end
      end
    end
  end
end
