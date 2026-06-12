# frozen_string_literal: true

require_relative "safe_image/version"

module SafeImage
  class Error < StandardError; end

  # Raised when any operation is attempted before SafeImage.configure!.
  class NotConfiguredError < Error; end

  class UnsupportedFormatError < Error; end

  # Raised when libvips cannot be loaded at runtime. configure!(backend: :vips)
  # surfaces this at boot; operations never fall back to ImageMagick.
  class VipsUnavailableError < UnsupportedFormatError; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end

  # Default decompression-bomb ceiling when configure! is not given an explicit
  # max_pixels. Mirrored in the native binding (SAFE_IMAGE_DEFAULT_MAX_PIXELS)
  # and aligned with the 128MP area limit on the ImageMagick path. Per-call
  # max_pixels: overrides the configured value.
  DEFAULT_MAX_PIXELS = 128 * 1024 * 1024

  BACKENDS = %i[vips imagemagick].freeze

  # Process-wide configuration. configure! builds a frozen instance and swaps
  # it in with a single assignment, so readers never observe a half-applied
  # config.
  Config = Data.define(:backend, :landlock, :max_pixels)
end

require_relative "safe_image/native"
require_relative "safe_image/result"
require_relative "safe_image/runner"
require_relative "safe_image/sandbox"
require_relative "safe_image/zygote"
require_relative "safe_image/path_safety"
require_relative "safe_image/optimizer"
require_relative "safe_image/svg_metadata"
require_relative "safe_image/svg_css"
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

  @config = nil

  # Decides, in one place, everything that varies by host: which backend
  # decodes untrusted bytes, whether operations run inside the Landlock
  # sandbox, and the default decompression-bomb ceiling. Must be called before
  # any operation; calling it again replaces the configuration.
  #
  # Validation is eager so a misconfigured host fails at boot rather than on
  # the first request.
  def configure!(backend:, landlock:, max_pixels: DEFAULT_MAX_PIXELS)
    backend = backend.to_sym
    unless BACKENDS.include?(backend)
      raise ArgumentError, "unknown backend: #{backend.inspect} (expected :vips or :imagemagick)"
    end
    unless [true, false].include?(landlock)
      raise ArgumentError, "landlock must be true or false, got: #{landlock.inspect}"
    end
    max_pixels = Integer(max_pixels)
    raise ArgumentError, "max_pixels must be positive" if max_pixels <= 0

    case backend
    when :vips
      begin
        VipsGlue.init!
      rescue VipsUnavailableError => e
        raise Error, "backend: :vips requested but libvips is unavailable: #{e.message}"
      end
    when :imagemagick
      unless Runner.available?("magick") || Runner.available?("convert")
        raise Error, "backend: :imagemagick requested but no magick/convert executable was found"
      end
    end
    if landlock && !Sandbox.available?
      raise Error, "landlock: true requested but the Landlock sandbox is unavailable on this host"
    end

    # The zygote bakes the backend and max_pixels in at boot; a reconfigure
    # must not serve from a stale one.
    Zygote.shutdown!

    @config = Config.new(backend: backend, landlock: landlock, max_pixels: max_pixels)
  end

  def config
    @config || raise(NotConfiguredError, "call SafeImage.configure!(backend: :vips | :imagemagick, landlock: true | false) before using SafeImage")
  end

  def configured? = !@config.nil?

  def sandbox_available? = Sandbox.available?

  # Internal: whether operations must route through the sandbox worker. False
  # before configure! (so configure!'s own availability probes can run
  # commands) and inside worker children (so sandboxed operations never nest).
  def sandbox?
    !!@config&.landlock && ENV["SAFE_IMAGE_SANDBOX_CHILD"] != "1"
  end

  # Internal: per-call max_pixels overrides the configured default.
  def resolved_max_pixels(max_pixels)
    max_pixels.nil? ? config.max_pixels : max_pixels
  end

  def maybe_sandbox(operation, args: [], kwargs: {})
    config
    return yield unless sandbox?

    Sandbox.public_call!(operation, args: args, kwargs: kwargs)
  end

  def probe(path, max_pixels: nil)
    maybe_sandbox(:probe, args: [path], kwargs: { max_pixels: max_pixels }) do
      path = PathSafety.local_path(path)
      max_pixels = resolved_max_pixels(max_pixels)

      case File.extname(path).downcase
      when ".svg"
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
      when ".ico"
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
        case config.backend
        when :vips
          Processor.new(max_pixels: max_pixels).probe(path)
        when :imagemagick
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
        max_pixels = resolved_max_pixels(max_pixels)
        case config.backend
        when :vips
          # Header-only native read.
          VipsBackend.orientation(path, max_pixels: max_pixels)
        when :imagemagick
          # Probe first: rejects undecodable files and enforces the pixel cap.
          ImageMagickBackend.probe(path, max_pixels: max_pixels)
          ImageMagickBackend.orientation(path)
        end
      end
    end
  end

  def dominant_color(path, max_pixels: nil)
    maybe_sandbox(:dominant_color, args: [path], kwargs: { max_pixels: max_pixels }) do
      max_pixels = resolved_max_pixels(max_pixels)
      case config.backend
      when :vips
        if File.extname(PathSafety.local_path(path)).downcase == ".ico"
          # Pure-Ruby ICO decode; vips only averages the decoded pixels.
          Ico.dominant_color(path, max_pixels: max_pixels)
        else
          VipsBackend.dominant_color(path, max_pixels: max_pixels)
        end
      when :imagemagick
        imagemagick_dominant_color(path, max_pixels: max_pixels)
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
    config
    Remote.info(url, **kwargs)
  end

  def remote_size(url, **kwargs)
    config
    Remote.size(url, **kwargs)
  end

  def remote_dimensions(url, **kwargs)
    remote_size(url, **kwargs)
  end

  def remote_type(url, **kwargs)
    config
    Remote.type(url, **kwargs)
  end

  def remote_animated?(url, **kwargs)
    config
    Remote.animated?(url, **kwargs)
  end

  def remote_dominant_color(url, **kwargs)
    config
    Remote.dominant_color(url, **kwargs)
  end

  def fetch_remote(url, **kwargs, &block)
    config
    Remote.fetch(url, **kwargs, &block)
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil, optimize: false, optimize_mode: :lossless, chroma_subsampling: :auto)
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
        optimize: optimize,
        optimize_mode: optimize_mode,
        chroma_subsampling: chroma_subsampling
      }
    ) do
      Processor.new(max_pixels: resolved_max_pixels(max_pixels), chroma_subsampling: chroma_subsampling).thumbnail(
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
    config
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
    # Validate the required id_namespace in the parent (after the configured
    # check) so omitting/malformed values raise ArgumentError consistently —
    # otherwise, under the sandbox, the worker raises and it surfaces as a
    # sandbox CommandError instead of the documented ArgumentError.
    config
    SvgSanitizer.resolve_namespace(kwargs.fetch(:id_namespace, SvgSanitizer::NAMESPACE_REQUIRED))
    kwargs = kwargs.merge(max_pixels: resolved_max_pixels(kwargs[:max_pixels]))
    maybe_sandbox(:sanitize_svg!, args: args, kwargs: kwargs) { SvgSanitizer.sanitize!(*args, **kwargs) }
  end
end
