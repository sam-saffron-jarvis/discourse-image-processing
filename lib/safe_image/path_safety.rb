# frozen_string_literal: true

module SafeImage
  module PathSafety
    SAFE_IMAGEMAGICK_PATH = %r{\A[\w\-\./]+\z}.freeze

    module_function

    def local_path(value)
      if value.respond_to?(:path) && value.path
        value.path.to_s
      else
        value.to_s
      end
    end

    def ensure_imagemagick_safe!(path)
      path = local_path(path)
      raise UnsafePathError, "path contains NUL" if path.include?("\0")
      raise UnsafePathError, "path must be absolute" unless path.start_with?("/")
      unless SAFE_IMAGEMAGICK_PATH.match?(path)
        raise UnsafePathError, "path contains characters unsafe for ImageMagick pseudo-filename parsing"
      end
      path
    end
  end
end
