# frozen_string_literal: true

module DiscourseImageProcessing
  module ImageMagickBackend
    module_function

    DECODERS = {
      "jpg" => "jpeg",
      "jpeg" => "jpeg",
      "png" => "png",
      "webp" => "webp",
      "heic" => "heic",
      "heif" => "heic",
      "avif" => "heic"
    }.freeze

    def thumbnail(input:, output:, width:, height:, format:, quality:, timeout: Runner::DEFAULT_TIMEOUT)
      resize_like(input: input, output: output, width: width, height: height, format: format, quality: quality, crop: :centre, timeout: timeout)
    end

    def resize_like(input:, output:, width:, height:, format:, quality:, crop: false, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick not available" unless Runner.available?("magick")

      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }

      argv = ["magick", "#{decoder}:#{input}[0]", "-auto-orient"]
      if crop == :north
        argv.concat([
          "-gravity", "north",
          "-background", "transparent",
          "-thumbnail", "#{Integer(width)}x#{Integer(height)}^",
          "-crop", "#{Integer(width)}x#{Integer(height)}+0+0"
        ])
      else
        argv.concat([
          "-gravity", "center",
          "-background", "transparent",
          "-thumbnail", "#{Integer(width)}x#{Integer(height)}^",
          "-extent", "#{Integer(width)}x#{Integer(height)}"
        ])
      end
      argv.concat(["-interpolate", "catrom", "-unsharp", "2x0.5+0.7+0", "-interlace", "none"])
      argv.concat(["-quality", Integer(quality).to_s]) if quality
      argv << output

      run_image_command(argv, output, ext, format, timeout)
    end

    def downsize(input:, output:, dimensions:, format:, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick not available" unless Runner.available?("magick")

      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      argv = [
        "magick", "#{decoder}:#{input}[0]",
        "-auto-orient",
        "-gravity", "center",
        "-background", "transparent",
        "-interlace", "none",
        "-resize", dimensions.to_s,
        output
      ]
      run_image_command(argv, output, ext, format, timeout)
    end

    def convert_to_jpeg(input:, output:, quality: nil, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick not available" unless Runner.available?("magick")
      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS[ext]
      source = decoder ? "#{decoder}:#{input}[0]" : input
      argv = ["magick", source, "-auto-orient", "-background", "white", "-interlace", "none", "-flatten"]
      argv.concat(["-quality", Integer(quality).to_s]) if quality
      argv << output
      run_image_command(argv, output, ext, "jpg", timeout)
    end

    def fix_orientation(input:, output: input, timeout: Runner::DEFAULT_TIMEOUT)
      raise UnsupportedFormatError, "ImageMagick not available" unless Runner.available?("magick")
      input = PathSafety.ensure_imagemagick_safe!(input)
      output = PathSafety.ensure_imagemagick_safe!(output)
      ext = File.extname(input).delete_prefix(".").downcase
      decoder = DECODERS.fetch(ext) { raise UnsupportedFormatError, "unsupported ImageMagick input format: #{ext.inspect}" }
      argv = ["magick", "#{decoder}:#{input}[0]", "-auto-orient", output]
      run_image_command(argv, output, ext, ext, timeout)
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
