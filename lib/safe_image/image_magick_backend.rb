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
      "ico" => "ico"
    }.freeze

    def probe(path, timeout: Runner::DEFAULT_TIMEOUT, max_pixels: nil)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_safe!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(["identify", "-ping", "-format", "%m %w %h %n\n", "#{decoder}:#{path}"], timeout: timeout)
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

      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }

      argv = [command, "#{decoder}:#{input}[0]", "-auto-orient"]
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
      argv.concat(["-quality", Integer(quality).to_s]) if quality
      argv << output

      run_image_command(argv, output, ext, format, timeout)
    end

    def downsize(input:, output:, dimensions:, format:, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command

      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      argv = [
        command, "#{decoder}:#{input}[0]",
        "-auto-orient",
        "-gravity", "center",
        "-background", "transparent",
        "-interlace", "none",
        "-resize", dimensions.to_s,
      ]
      argv.concat(["-profile", DEFAULT_PROFILE]) if File.file?(DEFAULT_PROFILE)
      argv << output
      run_image_command(argv, output, ext, format, timeout)
    end

    def convert_to_jpeg(input:, output:, quality: nil, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      source = "#{decoder}:#{input}[0]"
      argv = [command, source, "-auto-orient", "-background", "white", "-interlace", "none", "-flatten"]
      argv.concat(["-quality", Integer(quality).to_s]) if quality
      argv << output
      run_image_command(argv, output, ext, "jpg", timeout)
    end

    def convert_ico_to_png(input:, output:, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      argv = [command, "ico:#{input}[-1]", "-auto-orient", "-background", "transparent", output]
      run_image_command(argv, output, "ico", "png", timeout)
    end

    def frame_count(path, timeout: Runner::DEFAULT_TIMEOUT, max_pixels: nil)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_safe!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(["identify", "-ping", "-format", "%w %h %n\n", "#{decoder}:#{path}"], timeout: timeout)
      width, height, frames = stdout.each_line.first.to_s.split.map(&:to_i)
      if max_pixels && width.to_i * height.to_i > Integer(max_pixels)
        raise LimitError, "image has #{width * height} pixels, exceeds #{max_pixels}"
      end
      frames.to_i
    end

    def orientation(path, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick identify not available" unless Runner.available?("identify")
      path = PathSafety.ensure_imagemagick_safe!(path)
      ext = File.extname(path).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      stdout, = Runner.run!(
        ["identify", "-ping", "-format", "%[EXIF:Orientation]", "#{decoder}:#{path}[0]"],
        timeout: timeout
      )
      value = stdout.to_s.strip
      value.empty? ? 1 : value.to_i
    rescue CommandError
      1
    end

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize:, font: "NimbusSans-Regular", timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      output = PathSafety.ensure_imagemagick_safe!(output)
      rgb = Array(background_rgb).map { |v| Integer(v) }
      raise ArgumentError, "background_rgb must have three channels" unless rgb.length == 3
      glyph = letter.to_s.each_grapheme_cluster.first.to_s.gsub("%", "%%")
      font_name = font.to_s
      raise ArgumentError, "font contains NUL" if font_name.include?("\0")

      argv = [
        command,
        "-size", "#{Integer(size)}x#{Integer(size)}",
        "xc:rgb(#{rgb[0]},#{rgb[1]},#{rgb[2]})",
        "-pointsize", Integer(pointsize).to_s,
        "-fill", "#FFFFFFCC",
        "-font", font_name,
        "-gravity", "Center",
        "-annotate", "-0+34", glyph,
        "-depth", "8",
        output
      ]
      run_image_command(argv, output, "generated", "png", timeout)
    end

    def fix_orientation(input:, output: input, timeout: Runner::DEFAULT_TIMEOUT)
      command = convert_command
      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      argv = [command, "#{decoder}:#{input}[0]", "-auto-orient", output]
      run_image_command(argv, output, ext, ext, timeout)
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
