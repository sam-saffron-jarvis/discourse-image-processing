# frozen_string_literal: true

require_relative "safe_image/version"

module SafeImage
  class Error < StandardError; end
  class UnsupportedFormatError < Error; end

  # Raised when libvips cannot be loaded at runtime. Subclasses
  # UnsupportedFormatError so the :auto backend routing treats a missing
  # libvips like any other missing capability and falls back to the
  # ImageMagick compatibility paths; explicit backend: :vips calls fail
  # closed with this error.
  class VipsUnavailableError < UnsupportedFormatError; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end

  # Default decompression-bomb ceiling for the libvips processing path when the
  # caller does not pass an explicit max_pixels. Mirrored in the native
  # extension (SAFE_IMAGE_DEFAULT_MAX_PIXELS) and aligned with the 128MP area
  # limit on the ImageMagick path. Pass max_pixels to raise or lower it.
  DEFAULT_MAX_PIXELS = 128 * 1024 * 1024
end

require_relative "safe_image/native"
require_relative "safe_image/result"
require_relative "safe_image/runner"
require_relative "safe_image/sandbox"
require_relative "safe_image/path_safety"
require_relative "safe_image/optimizer"
require_relative "safe_image/svg_metadata"
require_relative "safe_image/svg_sanitizer"
require_relative "safe_image/remote"
require_relative "safe_image/ico"
require_relative "safe_image/image_magick_backend"
require_relative "safe_image/jpegli_backend"
require_relative "safe_image/vips_backend"
require_relative "safe_image/processor"
require_relative "safe_image/discourse_compat"

module SafeImage
  module_function

  @sandbox_enabled = false

  def enable_sandbox!
    raise Error, "landlock sandbox requested but unavailable" unless Sandbox.available?
    @sandbox_enabled = true
  end

  def disable_sandbox!
    @sandbox_enabled = false
  end

  def sandbox_enabled?
    @sandbox_enabled && ENV["SAFE_IMAGE_SANDBOX_CHILD"] != "1"
  end

  def with_sandbox_disabled
    previous = @sandbox_enabled
    @sandbox_enabled = false
    yield
  ensure
    @sandbox_enabled = previous
  end

  def sandbox_available? = Sandbox.available?

  def sandbox_call(operation, args: [], kwargs: {})
    Sandbox.public_call!(operation, args: args, kwargs: kwargs)
  end

  def maybe_sandbox(operation, args: [], kwargs: {})
    return yield unless sandbox_enabled?

    sandbox_call(operation, args: args, kwargs: kwargs)
  end

  def probe(path, max_pixels: nil)
    maybe_sandbox(:probe, args: [path], kwargs: { max_pixels: max_pixels }) do
      path = PathSafety.local_path(path)

      if File.extname(path).downcase == ".svg"
        info = SvgMetadata.probe(path, max_pixels: max_pixels)
        Result.new(
          input: File.expand_path(path),
          output: nil,
          input_format: "svg",
          output_format: nil,
          width: info.fetch(:width),
          height: info.fetch(:height),
          filesize: File.size(path),
          backend: "svg-metadata",
          duration_ms: info.fetch(:duration_ms),
          optimizer: nil
        )
      elsif File.extname(path).downcase == ".ico"
        # Pure-Ruby directory parse; reports the largest entry's dimensions.
        info = Ico.probe(path, max_pixels: max_pixels)
        Result.new(
          input: File.expand_path(path),
          output: nil,
          input_format: "ico",
          output_format: nil,
          width: info.fetch(:width),
          height: info.fetch(:height),
          filesize: File.size(path),
          backend: "ico-metadata",
          duration_ms: info.fetch(:duration_ms),
          optimizer: nil
        )
      else
        begin
          Processor.new(max_pixels: max_pixels).probe(path)
        rescue UnsupportedFormatError
          info = ImageMagickBackend.probe(path, max_pixels: max_pixels)
          Result.new(
            input: File.expand_path(path),
            output: nil,
            input_format: info.fetch(:input_format),
            output_format: nil,
            width: info.fetch(:width),
            height: info.fetch(:height),
            filesize: File.size(path),
            backend: "imagemagick",
            duration_ms: info.fetch(:duration_ms),
            optimizer: nil
          )
        end
      end
    end
  end

  def type(path, max_pixels: nil)
    maybe_sandbox(:type, args: [path], kwargs: { max_pixels: max_pixels }) do
      fastimage_type(probe(path, max_pixels: max_pixels).input_format)
    end
  end

  def size(path, max_pixels: nil)
    maybe_sandbox(:size, args: [path], kwargs: { max_pixels: max_pixels }) do
      result = probe(path, max_pixels: max_pixels)
      [result.width, result.height]
    end
  end

  def dimensions(path, max_pixels: nil)
    size(path, max_pixels: max_pixels)
  end

  def info(path, max_pixels: nil, animated: false, orientation: false)
    maybe_sandbox(:info, args: [path], kwargs: { max_pixels: max_pixels, animated: animated, orientation: orientation }) do
      result = probe(path, max_pixels: max_pixels)
      type = fastimage_type(result.input_format)
      Info.new(
        path: result.input,
        type: type,
        width: result.width,
        height: result.height,
        size: [result.width, result.height],
        animated: animated ? animated?(path, max_pixels: max_pixels) : nil,
        orientation: orientation ? orientation(path, max_pixels: max_pixels) : nil
      )
    end
  end

  def orientation(path, max_pixels: nil)
    maybe_sandbox(:orientation, args: [path], kwargs: { max_pixels: max_pixels }) do
      case File.extname(PathSafety.local_path(path)).downcase
      when ".svg", ".ico"
        # No EXIF orientation in either format; upright by definition.
        1
      else
        # Header-only native read; ImageMagick identify remains the fallback
        # for formats outside the native loader allowlist.
        begin
          VipsBackend.orientation(path, max_pixels: max_pixels)
        rescue UnsupportedFormatError
          probe(path, max_pixels: max_pixels) if max_pixels
          ImageMagickBackend.orientation(path)
        end
      end
    end
  end

  def dominant_color(path, max_pixels: nil, backend: :auto)
    maybe_sandbox(:dominant_color, args: [path], kwargs: { max_pixels: max_pixels, backend: backend }) do
      case backend.to_sym
      when :vips
        VipsBackend.dominant_color(path, max_pixels: max_pixels)
      when :imagemagick, :magick
        imagemagick_dominant_color(path, max_pixels: max_pixels)
      when :auto
        # Format routing, mirroring probe: the native vips path handles every
        # format it can decode; ico goes through the pure-Ruby ICO decoder.
        # Decode failures raise InvalidImageError and are never retried on
        # another backend.
        begin
          VipsBackend.dominant_color(path, max_pixels: max_pixels)
        rescue UnsupportedFormatError
          begin
            raise unless File.extname(PathSafety.local_path(path)).downcase == ".ico"
            Ico.dominant_color(path, max_pixels: max_pixels)
          rescue UnsupportedFormatError
            imagemagick_dominant_color(path, max_pixels: max_pixels)
          end
        end
      else
        raise ArgumentError, "unknown backend: #{backend.inspect}"
      end
    end
  end

  def imagemagick_dominant_color(path, max_pixels:)
    # Probe first: rejects undecodable files and enforces the pixel cap
    # before ImageMagick fully decodes the image to average it.
    probe(path, max_pixels: max_pixels)
    ImageMagickBackend.dominant_color(path)
  end

  def fastimage_type(format)
    format.to_s == "jpg" ? :jpeg : format.to_s.to_sym
  end

  def remote_info(url, **kwargs)
    Remote.info(url, **kwargs)
  end

  def remote_size(url, **kwargs)
    Remote.size(url, **kwargs)
  end

  def remote_dimensions(url, **kwargs)
    remote_size(url, **kwargs)
  end

  def remote_type(url, **kwargs)
    Remote.type(url, **kwargs)
  end

  def remote_animated?(url, **kwargs)
    Remote.animated?(url, **kwargs)
  end

  def remote_dominant_color(url, **kwargs)
    Remote.dominant_color(url, **kwargs)
  end

  def fetch_remote(url, **kwargs, &block)
    Remote.fetch(url, **kwargs, &block)
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil, backend: :auto, optimize: false, optimize_mode: :lossless, execution: :inline, encoder: :auto, chroma_subsampling: :auto)
    maybe_sandbox(
      :thumbnail,
      kwargs: {
        input: input,
        output: output,
        width: width,
        height: height,
        format: format,
        quality: quality,
        max_pixels: max_pixels,
        backend: backend,
        optimize: optimize,
        optimize_mode: optimize_mode,
        execution: :inline,
        encoder: encoder,
        chroma_subsampling: chroma_subsampling
      }
    ) do
      Processor.new(max_pixels: max_pixels, backend: backend, execution: execution, encoder: encoder, chroma_subsampling: chroma_subsampling).thumbnail(
        input: input,
        output: output,
        width: width,
        height: height,
        format: format,
        quality: quality,
        optimize: optimize,
        optimize_mode: optimize_mode
      )
    end
  end

  def optimize(path, mode: :lossless, strip_metadata: true, quality: nil, strict: true)
    maybe_sandbox(:optimize, args: [path], kwargs: { mode: mode, strip_metadata: strip_metadata, quality: quality, strict: strict }) do
      Optimizer.optimize(path, mode: mode, strip_metadata: strip_metadata, quality: quality, strict: strict)
    end
  end

  def resize(*args, **kwargs)
    maybe_sandbox(:resize, args: args, kwargs: kwargs) { DiscourseCompat.resize(*args, **kwargs) }
  end

  def crop(*args, **kwargs)
    maybe_sandbox(:crop, args: args, kwargs: kwargs) { DiscourseCompat.crop(*args, **kwargs) }
  end

  def downsize(*args, **kwargs)
    maybe_sandbox(:downsize, args: args, kwargs: kwargs) { DiscourseCompat.downsize(*args, **kwargs) }
  end

  def convert(*args, **kwargs)
    maybe_sandbox(:convert, args: args, kwargs: kwargs) { DiscourseCompat.convert(*args, **kwargs) }
  end

  def convert_to_jpeg(*args, **kwargs)
    maybe_sandbox(:convert_to_jpeg, args: args, kwargs: kwargs) { DiscourseCompat.convert_to_jpeg(*args, **kwargs) }
  end

  def fix_orientation(*args, **kwargs)
    maybe_sandbox(:fix_orientation, args: args, kwargs: kwargs) { DiscourseCompat.fix_orientation(*args, **kwargs) }
  end

  def convert_favicon_to_png(*args, **kwargs)
    maybe_sandbox(:convert_favicon_to_png, args: args, kwargs: kwargs) { DiscourseCompat.convert_favicon_to_png(*args, **kwargs) }
  end

  def frame_count(*args, **kwargs)
    maybe_sandbox(:frame_count, args: args, kwargs: kwargs) { DiscourseCompat.frame_count(*args, **kwargs) }
  end

  def animated?(*args, **kwargs)
    path = args.first
    return false if path && File.extname(PathSafety.local_path(path)).downcase == ".svg"

    maybe_sandbox(:animated?, args: args, kwargs: kwargs) { DiscourseCompat.animated?(*args, **kwargs) }
  end

  def letter_avatar(*args, **kwargs)
    maybe_sandbox(:letter_avatar, args: args, kwargs: kwargs) { DiscourseCompat.letter_avatar(*args, **kwargs) }
  end

  def optimize_image!(*args, **kwargs)
    maybe_sandbox(:optimize_image!, args: args, kwargs: kwargs) { DiscourseCompat.optimize_image!(*args, **kwargs) }
  end

  def sanitize_svg!(*args, **kwargs)
    maybe_sandbox(:sanitize_svg!, args: args, kwargs: kwargs) { SvgSanitizer.sanitize!(*args, **kwargs) }
  end
end
