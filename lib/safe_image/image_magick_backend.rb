# frozen_string_literal: true

module SafeImage
  module ImageMagickBackend
    module_function

    DEFAULT_PROFILE = File.expand_path("RT_sRGB.icm", __dir__)
    DECODERS = {
      "jpg" => "jpeg",
      "jpeg" => "jpeg",
      "png" => "png",
      "gif" => "gif",
      "webp" => "webp",
      "heic" => "heic",
      "heif" => "heic",
      "avif" => "heic",
      "ico" => "ico",
      "jxl" => "jxl"
    }.freeze

    IMAGEMAGICK_LIMIT_ARGS = [
      "-limit", "memory", "256MiB",
      "-limit", "map", "512MiB",
      "-limit", "disk", "1GiB",
      "-limit", "area", "128MP",
      "-limit", "time", "20",
      "-limit", "thread", "2"
    ].freeze

    ALLOWED_FONTS = %w[NimbusSans-Regular DejaVu-Sans Liberation-Sans Arial Helvetica Adwaita-Sans].freeze

    def probe(path, timeout: Runner::DEFAULT_TIMEOUT, max_pixels: nil)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_input_file!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(["identify", *IMAGEMAGICK_LIMIT_ARGS, "-ping", "-format", "%m %w %h %n\n", "#{decoder}:#{path}"], timeout: timeout)
      _magick_format, width, height, frames = stdout.each_line.first.to_s.split
      width = width.to_i
      height = height.to_i
      if max_pixels && width * height > Integer(max_pixels)
        raise LimitError, "image has #{width * height} pixels, exceeds #{max_pixels}"
      end
      { input_format: ext == "jpeg" ? "jpg" : ext, width: width, height: height, frames: frames.to_i, duration_ms: 0.0 }
    end

    def thumbnail(input:, output:, width:, height:, format:, quality:, timeout: Runner::DEFAULT_TIMEOUT)
      resize_like(input: input, output: output, width: width, height: height, format: format, quality: quality, crop: :centre, timeout: timeout)
    end

    def resize_like(input:, output:, width:, height:, format:, quality:, crop: false, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command

      input = PathSafety.ensure_imagemagick_input_file!(input)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }

      quality = validate_quality!(quality)
      argv = [command, *IMAGEMAGICK_LIMIT_ARGS, "#{decoder}:#{input}[0]", "-auto-orient"]
      if crop == :north
        argv.concat([
          "-gravity", "north",
          "-background", "transparent",
          "-thumbnail", "#{Integer(width)}x#{Integer(height)}^",
          "-crop", "#{Integer(width)}x#{Integer(height)}+0+0",
          "-unsharp", "2x0.5+0.7+0",
          "-interlace", "none"
        ])
      else
        argv.concat([
          "-gravity", "center",
          "-background", "transparent",
          "-thumbnail", "#{Integer(width)}x#{Integer(height)}^",
          "-extent", "#{Integer(width)}x#{Integer(height)}",
          "-interpolate", "catrom",
          "-unsharp", "2x0.5+0.7+0",
          "-interlace", "none"
        ])
      end
      argv.concat(["-profile", DEFAULT_PROFILE]) if File.file?(DEFAULT_PROFILE)
      argv.concat(["-quality", quality.to_s]) if quality
      argv << output_spec(format, output)

      run_image_command(argv, output, ext, format, timeout)
    end

    def downsize(input:, output:, dimensions:, format:, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command

      input = PathSafety.ensure_imagemagick_input_file!(input)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      dimensions = validate_dimensions!(dimensions)
      argv = [
        command, *IMAGEMAGICK_LIMIT_ARGS, "#{decoder}:#{input}[0]",
        "-auto-orient",
        "-gravity", "center",
        "-background", "transparent",
        "-interlace", "none",
        "-resize", dimensions,
      ]
      argv.concat(["-profile", DEFAULT_PROFILE]) if File.file?(DEFAULT_PROFILE)
      argv << output_spec(format, output)
      run_image_command(argv, output, ext, format, timeout)
    end

    def convert(input:, output:, format:, quality: nil, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_input_file!(input)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      normalized_format = format.to_s.downcase
      normalized_format = "jpg" if normalized_format == "jpeg"
      output_arg = output_spec(normalized_format, output)
      quality = validate_quality!(quality)

      argv = [command, *IMAGEMAGICK_LIMIT_ARGS, "#{decoder}:#{input}[0]", "-auto-orient", "-interlace", "none"]
      argv.concat(["-background", "white", "-flatten"]) if normalized_format == "jpg"
      argv.concat(["-quality", quality.to_s]) if quality
      argv << output_arg
      run_image_command(argv, output, ext, normalized_format, timeout)
    end

    def convert_to_jpeg(input:, output:, quality: nil, timeout: Runner::DEFAULT_TIMEOUT)
      convert(input: input, output: output, format: "jpg", quality: quality, timeout: timeout)
    end

    def convert_ico_to_png(input:, output:, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_input_file!(input)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      argv = [command, *IMAGEMAGICK_LIMIT_ARGS, "ico:#{input}[-1]", "-auto-orient", "-background", "transparent", output_spec("png", output)]
      run_image_command(argv, output, "ico", "png", timeout)
    end

    def frame_count(path, timeout: Runner::DEFAULT_TIMEOUT, max_pixels: nil)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_input_file!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(["identify", *IMAGEMAGICK_LIMIT_ARGS, "-ping", "-format", "%w %h %n\n", "#{decoder}:#{path}"], timeout: timeout)
      width, height, frames = stdout.each_line.first.to_s.split.map(&:to_i)
      if max_pixels && width.to_i * height.to_i > Integer(max_pixels)
        raise LimitError, "image has #{width * height} pixels, exceeds #{max_pixels}"
      end
      frames.to_i
    end

    def orientation(path, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_input_file!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(
        ["identify", *IMAGEMAGICK_LIMIT_ARGS, "-ping", "-format", "%[EXIF:Orientation]", "#{decoder}:#{path}[0]"],
        timeout: timeout
      )
      value = stdout.to_s.strip
      value.empty? ? 1 : value.to_i
    rescue CommandError
      1
    end

    # Averages the whole image down to one pixel and reports it as an RRGGBB
    # hex string, mirroring Discourse's Upload#calculate_dominant_color!.
    def dominant_color(path, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      path = PathSafety.ensure_imagemagick_input_file!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(
        [
          command, *IMAGEMAGICK_LIMIT_ARGS, "#{decoder}:#{path}[0]",
          "-depth", "8",
          "-resize", "1x1",
          "-define", "histogram:unique-colors=true",
          "-format", "%c",
          "histogram:info:"
        ],
        timeout: timeout
      )

      # Typical output: `1: (110,116,93) #6F745E srgb(110,116,93)`. Alpha adds
      # two more hex digits; grayscale images report one channel (two digits,
      # four with alpha) instead of three.
      digits = stdout[/#(\h+)/, 1]
      hex =
        case digits&.length
        when 6, 8 then digits[0, 6]
        when 2, 4 then digits[0, 2] * 3
        end
      raise InvalidImageError, "could not parse dominant color from ImageMagick output: #{stdout.strip.inspect}" if hex.nil?
      hex.upcase
    end

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize:, font: "NimbusSans-Regular", timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      rgb = Array(background_rgb).map { |v| Integer(v) }
      raise ArgumentError, "background_rgb must have three channels" unless rgb.length == 3
      glyph = letter.to_s.each_grapheme_cluster.first.to_s.gsub("%", "%%")
      font_name = font.to_s
      raise ArgumentError, "unsupported font: #{font_name.inspect}" unless ALLOWED_FONTS.include?(font_name)

      argv = [
        command, *IMAGEMAGICK_LIMIT_ARGS,
        "-size", "#{Integer(size)}x#{Integer(size)}",
        "xc:rgb(#{rgb[0]},#{rgb[1]},#{rgb[2]})",
        "-pointsize", Integer(pointsize).to_s,
        "-fill", "#FFFFFFCC",
        "-font", font_name,
        "-gravity", "Center",
        "-annotate", "-0+34", glyph,
        "-depth", "8",
        output_spec("png", output)
      ]
      run_image_command(argv, output, "generated", "png", timeout)
    end

    def fix_orientation(input:, output: input, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_input_file!(input)
      output = PathSafety.ensure_safe_output_path!(output).to_s
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      argv = [command, *IMAGEMAGICK_LIMIT_ARGS, "#{decoder}:#{input}[0]", "-auto-orient", output_spec(ext, output)]
      run_image_command(argv, output, ext, ext, timeout)
    end

    def output_spec(format, output)
      ext = File.extname(output).delete_prefix(".").downcase
      ext = "jpg" if ext == "jpeg"
      normalized = format.to_s.downcase
      normalized = "jpg" if normalized == "jpeg"
      raise UnsupportedFormatError, "output extension #{ext.inspect} does not match format #{normalized.inspect}" unless ext == normalized

      coder = {
        "jpg" => "jpeg",
        "png" => "png",
        "gif" => "gif",
        "webp" => "webp",
        "avif" => "avif",
        "ico" => "ico",
        "jxl" => "jxl"
      }.fetch(normalized) { raise UnsupportedFormatError, "unsupported ImageMagick output format: #{normalized.inspect}" }
      "#{coder}:#{output}"
    end

    def validate_quality!(quality)
      return nil if quality.nil?
      quality = Integer(quality)
      raise ArgumentError, "quality must be 1..100" unless (1..100).cover?(quality)
      quality
    end

    def validate_dimensions!(dimensions)
      dimensions = dimensions.to_s
      patterns = [
        /\A\d+(?:\.\d+)?%\z/,
        /\A\d+x\d+[!<>^]?\z/,
        /\A\d+@\z/
      ]
      raise ArgumentError, "unsupported ImageMagick geometry: #{dimensions.inspect}" unless patterns.any? { |pattern| pattern.match?(dimensions) }
      dimensions
    end

    def convert_command
      Runner.available?("magick") ? "magick" : Runner.resolve_executable!("convert") && "convert"
    rescue UnsupportedFormatError
      raise UnsupportedFormatError, "ImageMagick convert/magick not available"
    end

    def run_image_command(argv, output, input_format, output_format, timeout)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Runner.run!(argv, timeout: timeout)
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

      info = Native.probe(output)
      {
        input_format: input_format == "jpeg" ? "jpg" : input_format,
        output_format: output_format == "jpeg" ? "jpg" : output_format,
        width: info.fetch(:width),
        height: info.fetch(:height),
        duration_ms: duration_ms
      }
    end
  end
end
