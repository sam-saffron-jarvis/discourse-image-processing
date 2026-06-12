# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tempfile"

module SafeImage
  # Compatibility-shaped API for the operations Discourse currently performs in
  # OptimizedImage, UploadCreator, ShrinkUploadedImage and FileHelper. The
  # backend is decided once by SafeImage.configure!; these methods only
  # dispatch to it.
  module DiscourseCompat
    module_function

    def resize(from, to, width, height, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      case SafeImage.config.backend
      when :vips
        vips_resize(from, to, width, height, quality: quality, optimize: optimize, max_pixels: max_pixels, chroma_subsampling: chroma_subsampling)
      when :imagemagick
        imagemagick_resize(from, to, width, height, quality: quality, optimize: optimize, max_pixels: max_pixels)
      end
    end

    def vips_resize(from, to, width, height, quality:, optimize:, max_pixels:, chroma_subsampling:)
      SafeImage.thumbnail(
        input: from,
        output: to,
        width: width,
        height: height,
        quality: quality || 85,
        optimize: optimize,
        max_pixels: max_pixels,
        chroma_subsampling: chroma_subsampling
      )
    end

    def imagemagick_resize(from, to, width, height, quality:, optimize:, max_pixels:)
      probe = compat_probe(from, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      info = ImageMagickBackend.thumbnail(
        input: probe.input,
        output: output,
        width: width,
        height: height,
        format: File.extname(output).delete_prefix(".").downcase,
        quality: quality
      )
      optimize_output(output, quality) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def crop(from, to, width, height, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      case SafeImage.config.backend
      when :vips
        vips_crop(from, to, width, height, quality: quality, optimize: optimize, max_pixels: max_pixels, chroma_subsampling: chroma_subsampling)
      when :imagemagick
        imagemagick_crop(from, to, width, height, quality: quality, optimize: optimize, max_pixels: max_pixels)
      end
    end

    def vips_crop(from, to, width, height, quality:, optimize:, max_pixels:, chroma_subsampling:)
      probe = compat_probe(from, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      format = File.extname(output).delete_prefix(".").downcase

      info =
        if use_jpegli_for_generated_jpeg?(format)
          with_temp_png(output) do |tmp_path|
            VipsBackend.crop_north(
              input: probe.input,
              output: tmp_path,
              width: width,
              height: height,
              format: "png",
              quality: 100,
              max_pixels: max_pixels
            )
            JpegliBackend.encode(
              input: tmp_path,
              output: output,
              quality: quality || JpegliBackend::DEFAULT_QUALITY,
              chroma_subsampling: JpegliBackend.validate_chroma_subsampling!(chroma_subsampling, input_format: probe.input_format),
              input_format: probe.input_format
            )
          end
        else
          VipsBackend.crop_north(
            input: probe.input,
            output: output,
            width: width,
            height: height,
            format: format,
            quality: quality || 85,
            max_pixels: max_pixels
          )
        end
      optimize_output(output, quality) if optimize
      result_from_info(probe.input, output, info, compat_backend_name(:vips, info))
    end

    def imagemagick_crop(from, to, width, height, quality:, optimize:, max_pixels:)
      probe = compat_probe(from, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      info = ImageMagickBackend.resize_like(
        input: probe.input,
        output: output,
        width: width,
        height: height,
        format: File.extname(output).delete_prefix(".").downcase,
        quality: quality,
        crop: :north
      )
      optimize_output(output, quality) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def downsize(from, to, dimensions, optimize: true, max_pixels: nil, quality: 85, chroma_subsampling: :auto)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      case SafeImage.config.backend
      when :vips
        vips_downsize(from, to, dimensions, quality: quality, optimize: optimize, max_pixels: max_pixels, chroma_subsampling: chroma_subsampling)
      when :imagemagick
        imagemagick_downsize(from, to, dimensions, optimize: optimize, max_pixels: max_pixels)
      end
    end

    def vips_downsize(from, to, dimensions, quality:, optimize:, max_pixels:, chroma_subsampling:)
      probe = compat_probe(from, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      format = File.extname(output).delete_prefix(".").downcase
      info =
        if use_jpegli_for_generated_jpeg?(format)
          with_temp_png(output) do |tmp_path|
            VipsBackend.downsize(
              input: probe.input,
              output: tmp_path,
              dimensions: dimensions,
              format: "png",
              quality: 100,
              max_pixels: max_pixels
            )
            JpegliBackend.encode(
              input: tmp_path,
              output: output,
              quality: quality,
              chroma_subsampling: JpegliBackend.validate_chroma_subsampling!(chroma_subsampling, input_format: probe.input_format),
              input_format: probe.input_format
            )
          end
        else
          VipsBackend.downsize(
            input: probe.input,
            output: output,
            dimensions: dimensions,
            format: format,
            quality: quality,
            max_pixels: max_pixels
          )
        end
      optimize_output(output, nil) if optimize
      result_from_info(probe.input, output, info, compat_backend_name(:vips, info))
    end

    def imagemagick_downsize(from, to, dimensions, optimize:, max_pixels:)
      probe = compat_probe(from, max_pixels: max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s
      info = ImageMagickBackend.downsize(
        input: probe.input,
        output: output,
        dimensions: dimensions,
        format: File.extname(output).delete_prefix(".").downcase
      )
      optimize_output(output, nil) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    # Post-processing applies only to the formats the optimizer tools
    # understand; other outputs (gif, jxl, ...) skip the pass.
    def optimize_output(output, quality)
      format = File.extname(output).delete_prefix(".").downcase
      format = "jpg" if format == "jpeg"
      return unless Processor::OPTIMIZABLE_OUTPUTS.include?(format)
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true, quality: quality, assume_upright: true)
    end

    # JPEG default when the caller passes no quality: matches what ImageMagick
    # uses for sources without quality tables, rather than libvips' Q75.
    NATIVE_CONVERT_DEFAULT_QUALITY = 92

    def convert(from, to, format:, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s

      case SafeImage.config.backend
      when :vips
        native_convert(from, output, format: format, quality: quality, optimize: optimize, max_pixels: max_pixels, chroma_subsampling: chroma_subsampling)
      when :imagemagick
        imagemagick_convert(from, output, format: format, quality: quality, optimize: optimize, max_pixels: max_pixels)
      end
    end

    def imagemagick_convert(from, output, format:, quality:, optimize:, max_pixels:)
      probe = compat_probe(from, max_pixels: max_pixels)
      normalized_format = format.to_s.downcase == "jpeg" ? "jpg" : format.to_s.downcase
      info = ImageMagickBackend.convert(input: probe.input, output: output, format: format, quality: quality)
      optimize_output(output, normalized_format == "jpg" ? quality : nil) if optimize
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def native_convert(from, output, format:, quality:, optimize:, max_pixels:, chroma_subsampling:)
      input = PathSafety.ensure_regular_file!(from).to_s
      normalized_format = format.to_s.downcase == "jpeg" ? "jpg" : format.to_s.downcase

      if use_jpegli_for_convert?(input, normalized_format)
        info = jpegli_convert_after_native_decode(
          input: input,
          output: output,
          quality: quality || JpegliBackend::DEFAULT_QUALITY,
          max_pixels: max_pixels,
          chroma_subsampling: chroma_subsampling
        )
        return result_from_info(input, output, info, compat_backend_name(:vips, info))
      end

      info = write_through_tempfile(output) do |tmp_path|
        Native.convert(input, tmp_path, normalized_format, quality || NATIVE_CONVERT_DEFAULT_QUALITY, max_pixels)
      end
      optimize_output(output, normalized_format == "jpg" ? quality : nil) if optimize
      result_from_info(input, output, info, "libvips-direct")
    end

    def jpegli_convert_after_native_decode(input:, output:, quality:, max_pixels:, chroma_subsampling:)
      with_temp_png(output) do |tmp_path|
        decoded = Native.convert(input, tmp_path, "png", 100, max_pixels)
        JpegliBackend.encode(
          input: tmp_path,
          output: output,
          quality: quality,
          chroma_subsampling: JpegliBackend.validate_chroma_subsampling!(chroma_subsampling, input_format: decoded.fetch(:input_format)),
          input_format: decoded.fetch(:input_format)
        )
      end
    end

    def use_jpegli_for_convert?(input, normalized_format)
      normalized_format == "jpg" && JpegliBackend.available? && JpegliBackend.suitable_direct_input?(input)
    end

    # cjpegli is an output-quality tool, not a configuration choice: installed
    # means used for JPEG output on the native path. It encodes only pixels
    # this gem already decoded, so it is not part of the untrusted-input
    # surface the backend choice controls.
    def use_jpegli_for_generated_jpeg?(format)
      normalized_format = format.to_s.downcase == "jpeg" ? "jpg" : format.to_s.downcase
      normalized_format == "jpg" && JpegliBackend.available?
    end

    def with_temp_png(output)
      output_path = Pathname.new(output)
      output_path.dirname.mkpath
      Tempfile.create([output_path.basename(".*").to_s, ".safe-image.png"], output_path.dirname.to_s) do |tmp|
        tmp_path = Pathname.new(tmp.path)
        tmp.close
        yield tmp_path
      ensure
        FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path
      end
    end

    def compat_backend_name(backend, info)
      base = backend.to_sym == :vips ? "libvips-direct" : "imagemagick"
      info[:encoder] == "cjpegli" ? "#{base}+cjpegli" : base
    end

    def convert_to_jpeg(from, to, quality: nil, optimize: true, max_pixels: nil, chroma_subsampling: :auto)
      convert(from, to, format: "jpg", quality: quality, optimize: optimize, max_pixels: max_pixels, chroma_subsampling: chroma_subsampling)
    end

    def fix_orientation(from, to = from, max_pixels: nil, quality: nil)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s

      case SafeImage.config.backend
      when :vips
        native_fix_orientation(from, output, max_pixels: max_pixels, quality: quality)
      when :imagemagick
        imagemagick_fix_orientation(from, output, max_pixels: max_pixels)
      end
    end

    def imagemagick_fix_orientation(from, output, max_pixels:)
      probe = compat_probe(from, max_pixels: max_pixels)
      info = ImageMagickBackend.fix_orientation(input: probe.input, output: output)
      result_from_info(probe.input, output, info, "imagemagick")
    end

    def native_fix_orientation(from, output, max_pixels:, quality:)
      input = PathSafety.ensure_regular_file!(from).to_s
      format = File.extname(input).delete_prefix(".").downcase
      format = "jpg" if format == "jpeg"
      # Validates the format against the native loader allowlist and enforces
      # the pixel cap before any pixel decode.
      orient = VipsBackend.orientation(input, max_pixels: max_pixels)

      # Lossless tier: jpegtran transforms JPEG DCT coefficients directly, so
      # there is no generation loss. -perfect refuses when the dimensions are
      # not MCU-aligned; fall through to the re-encode tier.
      if format == "jpg" && orient > 1 && Runner.available?("jpegtran")
        begin
          return jpegtran_fix_orientation(input, output, orient)
        rescue CommandError
          nil
        end
      end

      quality = quality.nil? ? 95 : Integer(quality)
      raise ArgumentError, "quality must be 1..100" unless (1..100).cover?(quality)
      info = write_through_tempfile(output) do |tmp_path|
        Native.resize(input, tmp_path, 1.0, format, quality, max_pixels)
      end
      result_from_info(input, output, info, "libvips-direct")
    end

    def jpegtran_fix_orientation(input, output, orient)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      info = write_through_tempfile(output) do |tmp_path|
        Runner.run!(["jpegtran", "-copy", "none", "-perfect", *Optimizer::JPEGTRAN_OPERATIONS.fetch(orient), "-outfile", tmp_path, input])
        Native.probe(tmp_path)
      end
      result_from_info(
        input,
        output,
        {
          input_format: "jpg",
          output_format: "jpg",
          width: info.fetch(:width),
          height: info.fetch(:height),
          duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        },
        "jpegtran"
      )
    end

    # Writes via a sibling tempfile and renames into place, so in-place calls
    # (to == from) never feed an output path that libvips is still reading
    # from as input.
    def write_through_tempfile(output)
      tmp_path = File.join(File.dirname(output), ".safe-image-#{Process.pid}-#{output.object_id}#{File.extname(output)}")
      PathSafety.ensure_safe_output_path!(tmp_path)
      result = yield tmp_path
      FileUtils.mv(tmp_path, output)
      result
    ensure
      FileUtils.rm_f(tmp_path)
    end

    def convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      output = PathSafety.ensure_safe_output_path!(to).to_s

      case SafeImage.config.backend
      when :vips
        # Pure-Ruby ICO parse; libvips only encodes the extracted pixels.
        info = Ico.convert_to_png(from, output, max_pixels: max_pixels)
        backend_name = "ico-ruby+libvips"
      when :imagemagick
        info = ImageMagickBackend.convert_ico_to_png(input: Pathname.new(from).expand_path.to_s, output: output)
        backend_name = "imagemagick"
      end
      Optimizer.optimize(output, mode: :lossless, strip_metadata: true) if optimize
      result_from_info(from, output, info, backend_name)
    end

    def frame_count(path, max_pixels: nil)
      max_pixels = SafeImage.resolved_max_pixels(max_pixels)
      # ico directories are counted by the pure-Ruby parser on either backend;
      # everything else is a header-only count.
      return Ico.frame_count(path, max_pixels: max_pixels) if File.extname(PathSafety.local_path(path)).downcase == ".ico"

      case SafeImage.config.backend
      when :vips
        VipsBackend.frame_count(path, max_pixels: max_pixels)
      when :imagemagick
        ImageMagickBackend.frame_count(path, max_pixels: max_pixels)
      end
    end

    def animated?(path, max_pixels: nil)
      frame_count(path, max_pixels: max_pixels).to_i > 1
    end

    def letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "DejaVu-Sans")
      output = PathSafety.ensure_safe_output_path!(output).to_s
      request = { output: output, size: size, background_rgb: background_rgb, letter: letter, pointsize: pointsize, font: font }

      info, backend_name =
        case SafeImage.config.backend
        when :vips
          [VipsBackend.letter_avatar(**request), "libvips-direct"]
        when :imagemagick
          [ImageMagickBackend.letter_avatar(**request), "imagemagick"]
        end

      result_from_info("generated", output, info, backend_name)
    end

    def optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil, strict: true)
      Optimizer.optimize(
        path,
        mode: allow_lossy_png ? :lossy : :lossless,
        strip_metadata: strip_metadata,
        quality: quality,
        strict: strict
      )
    end

    def compat_probe(path, max_pixels: nil)
      path = Pathname.new(path).expand_path.to_s
      if SafeImage.config.backend == :vips
        SafeImage.probe(path, max_pixels: max_pixels)
      else
        info = ImageMagickBackend.probe(path, max_pixels: max_pixels)
        Result.new(
          input: path,
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
