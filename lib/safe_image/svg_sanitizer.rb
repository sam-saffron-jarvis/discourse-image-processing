# frozen_string_literal: true

require "rexml/document"
require "rexml/formatters/default"
require "pathname"
require "tempfile"

module SafeImage
  module SvgSanitizer
    ALLOWED_ELEMENTS = %w[
      svg g defs title desc path rect circle ellipse line polyline polygon text tspan
      linearGradient radialGradient stop clipPath mask pattern use symbol
    ].freeze

    ALLOWED_ATTRIBUTES = %w[
      id class x y x1 y1 x2 y2 cx cy r rx ry d points width height viewBox
      fill stroke stroke-width stroke-linecap stroke-linejoin stroke-miterlimit
      fill-rule clip-rule opacity fill-opacity stroke-opacity transform
      gradientUnits gradientTransform offset stop-color stop-opacity clip-path
      mask href xlink:href xmlns xmlns:xlink version preserveAspectRatio
      font-family font-size font-weight text-anchor
    ].freeze

    module_function

    def sanitize!(path, max_pixels: nil)
      path = Pathname.new(SvgMetadata.safe_svg_path(path))
      begin
        SvgMetadata.dimensions(path.to_s, max_pixels: max_pixels)
      rescue InvalidImageError => e
        raise unless e.message.include?("dimensions are missing")
      end
      doc = SvgMetadata.parse(path.to_s)

      clean = REXML::Document.new
      clean.add_element(sanitize_element!(doc.root.deep_clone))

      out = +""
      formatter = REXML::Formatters::Default.new
      formatter.write(clean, out)
      atomic_write(path, out)
      { format: "svg", sanitized: true, filesize: File.size(path.to_s) }
    rescue REXML::ParseException => e
      raise InvalidImageError, "invalid SVG: #{e.message}"
    end

    def sanitize_element!(element)
      element.children.to_a.each do |child|
        case child
        when REXML::Element
          if ALLOWED_ELEMENTS.include?(child.name)
            sanitize_element!(child)
          else
            child.remove
          end
        when REXML::CData
          child.replace_with(REXML::Text.new(child.value.to_s))
        when REXML::Text
          # Text is serialized escaped by REXML::Formatters::Default.
        else
          child.remove
        end
      end

      attributes_to_delete = []
      element.attributes.each_attribute do |attr|
        name = attr.name.to_s
        value = attr.value.to_s
        allowed = ALLOWED_ATTRIBUTES.include?(name) || name.start_with?("aria-")
        if !allowed || name.downcase.start_with?("on") || dangerous_value?(value)
          attributes_to_delete << name
        end
      end
      attributes_to_delete.each { |name| element.delete_attribute(name) }

      %w[href xlink:href].each do |href|
        next unless element.attributes[href]
        element.delete_attribute(href) unless element.attributes[href].to_s.start_with?("#")
      end
      element
    end

    def dangerous_value?(value)
      normalized = value.to_s.gsub(/[\u0000-\u001f\u007f\s]+/, "")
      return true if normalized.match?(/(?:javascript|data):/i)

      normalized.scan(/url\(([^)]*)\)/i).any? do |match|
        inner = match.first.to_s.delete(%q{'"})
        !inner.match?(/\A#[A-Za-z][\w.-]*\z/)
      end
    end

    def atomic_write(path, content)
      Tempfile.create([path.basename.to_s, ".tmp"], path.dirname.to_s, binmode: false) do |tmp|
        tmp.write(content)
        tmp.flush
        tmp.fsync
        File.rename(tmp.path, path.to_s)
      end
    end
  end
end
