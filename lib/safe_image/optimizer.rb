# frozen_string_literal: true

require "tempfile"

module SafeImage
  module Optimizer
    module_function

    MAX_PNGQUANT_SIZE = 500_000

    def optimize(path, mode: :lossless, strip_metadata: true, quality: nil, timeout: Runner::DEFAULT_TIMEOUT, strict: true)
      path = Pathname.new(PathSafety.local_path(path)).expand_path
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
        else
          raise Error, "jpegoptim is required for strict JPEG optimisation" if strict
        end
      when "png"
        if mode.to_sym == :lossy && before < MAX_PNGQUANT_SIZE
          if Runner.available?("pngquant")
            tmp = Tempfile.new([path.basename(".*").to_s, ".pngquant.png"], path.dirname.to_s)
            tmp_path = Pathname.new(tmp.path)
            tmp.close
            begin
              argv = ["pngquant", "--force", "--skip-if-larger", "--output", tmp_path.to_s]
              argv << "--quality=#{quality}" if quality # e.g. "65-90"
              argv << path.to_s
              Runner.run!(argv, timeout: timeout)
              if tmp_path.file? && File.size(tmp_path) < File.size(path)
                FileUtils.mv(tmp_path, path)
                tools << "pngquant"
              end
            ensure
              FileUtils.rm_f(tmp_path)
            end
          elsif strict
            raise Error, "pngquant is required for strict lossy PNG optimisation"
          end
        end

        if Runner.available?("oxipng")
          argv = ["oxipng", "--quiet", "-o", "3"]
          argv.concat(["--strip", strip_metadata ? "safe" : "none"])
          argv << path.to_s
          Runner.run!(argv, timeout: timeout)
          tools << "oxipng"
        else
          raise Error, "oxipng is required for strict PNG optimisation" if strict
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
