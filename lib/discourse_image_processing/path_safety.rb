# frozen_string_literal: true

module DiscourseImageProcessing
  module PathSafety
    SAFE_IMAGEMAGICK_PATH = %r{\A[\w\-\./]+\z}.freeze

    module_function

    def ensure_imagemagick_safe!(path)
      path = path.to_s
      raise UnsafePathError, "path contains NUL" if path.include?("\0")
      raise UnsafePathError, "path must be absolute" unless path.start_with?("/")
      unless SAFE_IMAGEMAGICK_PATH.match?(path)
        raise UnsafePathError, "path contains characters unsafe for ImageMagick pseudo-filename parsing"
      end
      path
    end
  end
end
