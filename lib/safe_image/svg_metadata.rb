# frozen_string_literal: true

require "pathname"
require "rexml/document"

module SafeImage
  module SvgMetadata
    module_function

    MAX_SVG_BYTES = 1 * 1024 * 1024
    MAX_SVG_DEPTH = 64
    MAX_SVG_ELEMENTS = 10_000
    MAX_SVG_ATTRIBUTES = 50_000
    MAX_SVG_DIMENSION = 100_000
    MAX_SVG_PIXELS = 100_000_000

    LENGTH_PATTERN = /\A\s*([+]?(?:\d+(?:\.\d+)?|\.\d+))(?:px)?\s*\z/i.freeze
    VIEWBOX_SPLIT = /[\s,]+/.freeze

    def probe(path, max_pixels: nil, max_bytes: MAX_SVG_BYTES)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      path = safe_svg_path(path)
      width, height = dimensions(path, max_pixels: max_pixels, max_bytes: max_bytes)
      {
        input_format: "svg",
        width: width,
        height: height,
        frames: 1,
        duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      }
    end

    def dimensions(path, max_pixels: nil, max_bytes: MAX_SVG_BYTES)
      path = safe_svg_path(path)
      doc = parse(path, max_bytes: max_bytes)
      root = doc.root
      width = parse_length(root.attributes["width"])
      height = parse_length(root.attributes["height"])

      unless width && height
        view_box = parse_view_box(root.attributes["viewBox"])
        width ||= view_box&.fetch(2)
        height ||= view_box&.fetch(3)
      end

      validate_dimensions!(width, height, max_pixels: max_pixels)
    end

    def parse(path, max_bytes: MAX_SVG_BYTES)
      path = safe_svg_path(path)
      size = File.size(path)
      raise LimitError, "SVG exceeds #{max_bytes} bytes" if size > max_bytes

      xml = File.binread(path, max_bytes + 1)
      raise LimitError, "SVG exceeds #{max_bytes} bytes" if xml.bytesize > max_bytes
      reject_unsafe_xml!(xml)
      doc = REXML::Document.new(xml)
      raise InvalidImageError, "SVG root required" unless doc.root&.name == "svg"

      validate_tree!(doc.root)
      doc
    rescue REXML::ParseException => e
      raise InvalidImageError, "invalid SVG: #{e.message}"
    end

    def safe_svg_path(path)
      path = Pathname.new(PathSafety.local_path(path)).expand_path
      raise UnsafePathError, "path contains NUL" if path.to_s.include?("\0")
      raise UnsafePathError, "not a file: #{path}" unless path.file?
      raise UnsupportedFormatError, "not an SVG file: #{path}" unless File.extname(path.to_s).downcase == ".svg"
      path.to_s
    end

    def reject_unsafe_xml!(xml)
      raise InvalidImageError, "doctype is not allowed in SVG" if xml.match?(/<!DOCTYPE/i)
      raise InvalidImageError, "XML processing instructions are not allowed in SVG" if xml.match?(/<\?(?!xml\s)/i)
    end

    def parse_length(value)
      value = value.to_s
      match = LENGTH_PATTERN.match(value)
      return nil unless match

      number = Float(match[1])
      return nil unless number.finite? && number.positive?

      number
    rescue ArgumentError
      nil
    end

    def parse_view_box(value)
      parts = value.to_s.strip.split(VIEWBOX_SPLIT)
      return nil unless parts.length == 4

      numbers = parts.map { |part| Float(part) }
      return nil unless numbers.all?(&:finite?) && numbers[2].positive? && numbers[3].positive?

      numbers
    rescue ArgumentError
      nil
    end

    def validate_dimensions!(width, height, max_pixels: nil)
      raise InvalidImageError, "SVG dimensions are missing or invalid" unless width&.positive? && height&.positive?
      raise LimitError, "SVG dimensions exceed #{MAX_SVG_DIMENSION}px" if width > MAX_SVG_DIMENSION || height > MAX_SVG_DIMENSION

      pixels = width * height
      limit = max_pixels || MAX_SVG_PIXELS
      raise LimitError, "SVG has #{pixels.to_i} pixels, exceeds #{limit}" if pixels > limit

      [width.ceil, height.ceil]
    end

    def validate_tree!(root)
      counters = { elements: 0, attributes: 0 }
      validate_element!(root, depth: 0, counters: counters)
    end

    def validate_element!(element, depth:, counters:)
      raise LimitError, "SVG nesting exceeds #{MAX_SVG_DEPTH}" if depth > MAX_SVG_DEPTH

      counters[:elements] += 1
      raise LimitError, "SVG has too many elements" if counters[:elements] > MAX_SVG_ELEMENTS

      counters[:attributes] += element.attributes.length
      raise LimitError, "SVG has too many attributes" if counters[:attributes] > MAX_SVG_ATTRIBUTES

      element.elements.each do |child|
        validate_element!(child, depth: depth + 1, counters: counters)
      end
    end
  end
end
