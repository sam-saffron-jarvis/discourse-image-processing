# frozen_string_literal: true

require "rexml/document"
require "rexml/formatters/default"

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

    def sanitize!(path)
      path = Pathname.new(path).expand_path
      raise UnsafePathError, "not a file: #{path}" unless path.file?

      xml = File.read(path.to_s)
      raise InvalidImageError, "doctype is not allowed in SVG" if xml.match?(/<!DOCTYPE/i)
      doc = REXML::Document.new(xml)
      sanitize_element!(doc.root)

      out = +""
      formatter = REXML::Formatters::Default.new
      formatter.write(doc, out)
      File.write(path.to_s, out)
      { format: "svg", sanitized: true, filesize: File.size(path.to_s) }
    rescue REXML::ParseException => e
      raise InvalidImageError, "invalid SVG: #{e.message}"
    end

    def sanitize_element!(element)
      return unless element

      element.elements.to_a.each do |child|
        if ALLOWED_ELEMENTS.include?(child.name)
          sanitize_element!(child)
        else
          element.delete_element(child)
        end
      end

      attributes_to_delete = []
      element.attributes.each_attribute do |attr|
        name = attr.name.to_s
        value = attr.value.to_s
        allowed = ALLOWED_ATTRIBUTES.include?(name) || name.start_with?("aria-")
        normalized_value = value.gsub(/[\u0000-\u001f\u007f\s]+/, "")
        dangerous_value = normalized_value.match?(/(?:javascript|data):/i) || (normalized_value.include?("url(") && normalized_value.match?(/https?:/i))
        if !allowed || name.downcase.start_with?("on") || dangerous_value
          attributes_to_delete << name
        end
      end
      attributes_to_delete.each { |name| element.delete_attribute(name) }

      %w[href xlink:href].each do |href|
        next unless element.attributes[href]
        element.delete_attribute(href) unless element.attributes[href].to_s.start_with?("#")
      end
    end
  end
end
