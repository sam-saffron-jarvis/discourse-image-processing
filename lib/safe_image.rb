# frozen_string_literal: true

require_relative "safe_image/version"

module SafeImage
  class Error < StandardError; end
  class UnsupportedFormatError < Error; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end
end

require_relative "safe_image/native"
require_relative "safe_image/result"
require_relative "safe_image/runner"
require_relative "safe_image/sandbox"
require_relative "safe_image/path_safety"
require_relative "safe_image/optimizer"
require_relative "safe_image/svg_sanitizer"
require_relative "safe_image/remote"
require_relative "safe_image/image_magick_backend"
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
      begin
        Processor.new(max_pixels: max_pixels).probe(path)
      rescue UnsupportedFormatError
        path = PathSafety.local_path(path)
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
      probe(path, max_pixels: max_pixels) if max_pixels
      ImageMagickBackend.orientation(path)
    end
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

  def fetch_remote(url, **kwargs, &block)
    Remote.fetch(url, **kwargs, &block)
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil, backend: :vips, optimize: false, optimize_mode: :lossless, execution: :inline)
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
        execution: :inline
      }
    ) do
      Processor.new(max_pixels: max_pixels, backend: backend, execution: execution).thumbnail(
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
