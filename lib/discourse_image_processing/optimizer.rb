# frozen_string_literal: true

module DiscourseImageProcessing
  module Optimizer
    module_function

    MAX_PNGQUANT_SIZE = 500_000

    def optimize(path, mode: :lossless, strip_metadata: true, quality: nil, timeout: Runner::DEFAULT_TIMEOUT)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      raise UnsafePathError, "not a file: #{path}" unless path.file?

      ext = path.extname.delete_prefix(".").downcase
      ext = "jpg" if ext == "jpeg"

      before = File.size(path)
      tools = []

      case ext
      when "jpg"
        if Runner.available?("jpegoptim")
          argv = ["jpegoptim", "--quiet"]
          argv << (strip_metadata ? "--strip-all" : "--strip-none")
          argv << "--max=#{Integer(quality)}" if quality
          argv << path.to_s
          Runner.run!(argv, timeout: timeout)
          tools << "jpegoptim"
        end
      when "png"
        if mode.to_sym == :lossy && before < MAX_PNGQUANT_SIZE && Runner.available?("pngquant")
          tmp = path.sub_ext(".pngquant.png")
          FileUtils.rm_f(tmp)
          begin
            argv = ["pngquant", "--force", "--skip-if-larger", "--output", tmp.to_s]
            argv << "--quality=#{quality}" if quality # e.g. "65-90"
            argv << path.to_s
            Runner.run!(argv, timeout: timeout)
            if tmp.file? && File.size(tmp) < File.size(path)
              FileUtils.mv(tmp, path)
              tools << "pngquant"
            end
          ensure
            FileUtils.rm_f(tmp)
          end
        end

        if Runner.available?("oxipng")
          argv = ["oxipng", "--quiet", "-o", "3"]
          argv.concat(["--strip", strip_metadata ? "safe" : "none"])
          argv << path.to_s
          Runner.run!(argv, timeout: timeout)
          tools << "oxipng"
        end
      else
        raise UnsupportedFormatError, "unsupported optimize format: #{ext.inspect}"
      end

      after = File.size(path)
      {
        format: ext,
        before_bytes: before,
        after_bytes: after,
        saved_bytes: before - after,
        tools: tools
      }
    end
  end
end
