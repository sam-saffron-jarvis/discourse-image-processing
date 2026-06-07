# frozen_string_literal: true

require_relative "discourse_image_processing/version"

module DiscourseImageProcessing
  class Error < StandardError; end
  class UnsupportedFormatError < Error; end
  class UnsafePathError < Error; end
  class InvalidImageError < Error; end
  class LimitError < Error; end
end

require_relative "discourse_image_processing/native"
require_relative "discourse_image_processing/result"
require_relative "discourse_image_processing/runner"
require_relative "discourse_image_processing/path_safety"
require_relative "discourse_image_processing/optimizer"
require_relative "discourse_image_processing/image_magick_backend"
require_relative "discourse_image_processing/processor"
require_relative "discourse_image_processing/discourse_compat"

module DiscourseImageProcessing
  module_function

  def probe(path, max_pixels: nil)
    Processor.new(max_pixels: max_pixels).probe(path)
  end

  def thumbnail(input:, output:, width:, height:, format: nil, quality: 85, max_pixels: nil, backend: :vips, optimize: false, optimize_mode: :lossless)
    Processor.new(max_pixels: max_pixels, backend: backend).thumbnail(
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

  def optimize(path, mode: :lossless, strip_metadata: true, quality: nil)
    Optimizer.optimize(path, mode: mode, strip_metadata: strip_metadata, quality: quality)
  end

  def resize(...) = DiscourseCompat.resize(...)
  def crop(...) = DiscourseCompat.crop(...)
  def downsize(...) = DiscourseCompat.downsize(...)
  def convert_to_jpeg(...) = DiscourseCompat.convert_to_jpeg(...)
  def fix_orientation(...) = DiscourseCompat.fix_orientation(...)
  def optimize_image!(...) = DiscourseCompat.optimize_image!(...)
end
