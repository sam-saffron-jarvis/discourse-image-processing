# frozen_string_literal: true

module DiscourseImageProcessing
  # Compatibility-shaped API for the operations Discourse currently performs in
  # OptimizedImage, UploadCreator, ShrinkUploadedImage and FileHelper.
  module DiscourseCompat
    module_function

    def resize(from, to, width, height, quality: nil, backend: :vips, optimize: true, max_pixels: nil)
      DiscourseImageProcessing.thumbnail(
        input: from,
        output: to,
        width: width,
        height: height,
        quality: quality || 85,
        backend: backend,
        optimize: optimize,
        max_pixels: max_pixels
      )
    end

    def crop(from, to, width, height, quality: nil, backend: :imagemagick, optimize: true, max_pixels: nil)
      if backend.to_sym == :vips
        # Native top-crop is not implemented yet; use exact centre crop rather than
        # pretending semantics match. Callers that require Discourse's historical
        # north crop should select the ImageMagick backend for now.
        return resize(from, to, width, height, quality: quality, backend: :vips, optimize: optimize, max_pixels: max_pixels)
      end

      probe = DiscourseImageProcessing.probe(from, max_pixels: max_pixels)
      info = ImageMagickBackend.resize_like(
        input: probe.input,
        output: Pathname.new(to).expand_path.to_s,
        width: width,
        height: height,
        format: File.extname(to).delete_prefix(".").downcase,
        quality: quality,
        crop: :north
      )
      Optimizer.optimize(to, mode: :lossless, strip_metadata: true, quality: quality) if optimize
      result_from_info(probe.input, to, info, "imagemagick")
    end

    def downsize(from, to, dimensions, backend: :imagemagick, optimize: true, max_pixels: nil)
      # ImageMagick remains the exact compatibility backend for dimensions like
      # "50%", "100x100>" and "4000000@". A native vips equivalent should parse
      # and implement this mini-language before becoming default.
      probe = DiscourseImageProcessing.probe(from, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.downsize(
        input: probe.input,
        output: output,
        dimensions: dimensions,
        format: File.extname(output).delete_prefix(".").downcase
      )
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def convert_to_jpeg(from, to, quality: nil, optimize: true, max_pixels: nil)
      probe = DiscourseImageProcessing.probe(from, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.convert_to_jpeg(input: probe.input, output: output, quality: quality)
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: quality) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def fix_orientation(from, to = from, max_pixels: nil)
      probe = DiscourseImageProcessing.probe(from, max_pixels: max_pixels)
      output = Pathname.new(to).expand_path.to_s
      info = ImageMagickBackend.fix_orientation(input: probe.input, output: output)
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil)
      Optimizer.optimize(
        path,
        mode: allow_lossy_png ? :lossy : :lossless,
        strip_metadata: strip_metadata,
        quality: quality
      )
    end

    def result_from_info(input, output, info, backend)
      Result.new(
        input: input.to_s,
        output: output.to_s,
        input_format: info.fetch(:input_format),
        output_format: info.fetch(:output_format),
        width: info.fetch(:width),
        height: info.fetch(:height),
        filesize: File.size(output),
        backend: backend,
        duration_ms: info.fetch(:duration_ms),
        optimizer: nil
      )
    end
  end
end
