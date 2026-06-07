# frozen_string_literal: true

require "fileutils"
require "pathname"

module DiscourseImageProcessing
  class Processor
    SUPPORTED_INPUTS = %w[jpg jpeg png webp heic heif avif].freeze
    SUPPORTED_OUTPUTS = %w[jpg jpeg png webp avif].freeze

    def initialize(max_pixels: nil, backend: :vips)
      @max_pixels = max_pixels
      @backend = backend.to_sym
    end

    def probe(path)
      input = safe_existing_file!(path)
      info = Native.probe(input.to_s)
      validate_pixels!(info.fetch(:width), info.fetch(:height))
      Result.new(
        input: input.to_s,
        output: nil,
        input_format: info.fetch(:format),
        output_format: nil,
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(input),
        backend: "libvips-direct",
        duration_ms: info.fetch(:duration_ms),
        optimizer: nil
      )
    end

    def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, optimize: false, optimize_mode: :lossless)
      input = safe_existing_file!(input)
      output = safe_output_path!(output)
      width = Integer(width)
      height = Integer(height)
      quality = Integer(quality)
      raise ArgumentError, "width and height must be positive" if width <= 0 || height <= 0
      raise ArgumentError, "quality must be 1..100" unless (1..100).cover?(quality)

      out_format = (format || output.extname.delete_prefix(".")).downcase
      out_format = "jpg" if out_format == "jpeg"
      unless SUPPORTED_OUTPUTS.include?(out_format)
        raise UnsupportedFormatError, "unsupported output format: #{out_format.inspect}"
      end

      output.dirname.mkpath
      info =
        case @backend
        when :vips
          Native.thumbnail(input.to_s, output.to_s, width, height, out_format, quality, @max_pixels)
        when :imagemagick, :magick
          probe_info = Native.probe(input.to_s)
          validate_pixels!(probe_info.fetch(:width), probe_info.fetch(:height))
          ImageMagickBackend.thumbnail(
            input: input.to_s,
            output: output.to_s,
            width: width,
            height: height,
            format: out_format,
            quality: quality
          )
        else
          raise ArgumentError, "unknown backend: #{@backend.inspect}"
        end

      opt_info = nil
      if optimize
        opt_info = Optimizer.optimize(output, mode: optimize_mode, strip_metadata: true, quality: out_format == "jpg" ? quality : nil)
      end

      Result.new(
        input: input.to_s,
        output: output.to_s,
        input_format: info.fetch(:input_format),
        output_format: info.fetch(:output_format),
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(output),
        backend: @backend == :vips ? "libvips-direct" : "imagemagick",
        duration_ms: info.fetch(:duration_ms),
        optimizer: opt_info&.fetch(:tools, nil)
      )
    end

    private

    def safe_existing_file!(path)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      raise UnsafePathError, "not a file: #{path}" unless path.file?
      ext = path.extname.delete_prefix(".").downcase
      ext = "jpg" if ext == "jpeg"
      raise UnsupportedFormatError, "unsupported input format: #{ext.inspect}" unless SUPPORTED_INPUTS.include?(ext)
      path
    end

    def safe_output_path!(path)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      path
    end

    def validate_pixels!(width, height)
      return unless @max_pixels
      pixels = Integer(width) * Integer(height)
      raise LimitError, "image has #{pixels} pixels, exceeds #{@max_pixels}" if pixels > @max_pixels
    end
  end
end
