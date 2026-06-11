# frozen_string_literal: true

require "rexml/document"
require "rexml/formatters/default"
require "pathname"
require "tempfile"
require_relative "svg_css"

module SafeImage
  module SvgSanitizer
    ALLOWED_ELEMENTS = %w[
      svg g defs title desc path rect circle ellipse line polyline polygon text tspan
      linearGradient radialGradient stop clipPath mask pattern use symbol style
      marker
    ].freeze

    # Presentation attributes. The CSS-property names here are mirrored by
    # SvgCss::ALLOWED_PROPERTIES (a test asserts the subset relationship) so a
    # style="" / <style> declaration and its attribute twin are treated alike.
    # Attribute values that may carry url() (fill, stroke, clip-path, mask,
    # marker*) are constrained to #fragment references by dangerous_value?.
    ALLOWED_ATTRIBUTES = %w[
      id class x y x1 y1 x2 y2 cx cy r rx ry d points width height viewBox
      fill stroke stroke-width stroke-linecap stroke-linejoin stroke-miterlimit
      fill-rule clip-rule opacity fill-opacity stroke-opacity transform
      gradientUnits gradientTransform offset stop-color stop-opacity clip-path
      mask href xlink:href xmlns xmlns:xlink version preserveAspectRatio
      font-family font-size font-weight text-anchor style
      color stroke-dasharray stroke-dashoffset vector-effect
      marker marker-start marker-mid marker-end
      markerWidth markerHeight refX refY orient markerUnits
      display visibility overflow paint-order mix-blend-mode isolation
      shape-rendering image-rendering color-interpolation
      font-style font-variant font-stretch text-decoration
      letter-spacing word-spacing dominant-baseline baseline-shift
      writing-mode direction
    ].freeze

    # Caller namespace tokens must already be valid id/class idents so the
    # prefixed ids and the scope class are well-formed; rejected, not coerced,
    # so two distinct tokens can never collapse to one.
    NAMESPACE_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]*\z/.freeze

    # A url() referencing a same-document fragment, with optional matching
    # quotes, any case, surrounding whitespace allowed. This is the ONLY url()
    # form dangerous_value? keeps in a presentation attribute, and exactly the
    # form the namespace rewrite targets (capturing the fragment name) — so the
    # validation and rewrite paths cannot disagree and leave a reference bare.
    URL_FRAGMENT_REF = /url\(\s*(['"]?)#([A-Za-z][\w.-]*)\1\s*\)/i.freeze

    # ARIA attributes whose values are an id or a space-separated list of ids.
    # They are references like href/url(#…) and must move into the namespace too,
    # or they bind to a host element (or dangle) when the SVG is inlined.
    ARIA_IDREF_ATTRIBUTES = %w[
      aria-activedescendant aria-controls aria-describedby aria-details
      aria-errormessage aria-flowto aria-labelledby aria-owns
    ].freeze

    # Sentinel marking id_namespace as unsupplied, so omitting it raises an
    # instructive error rather than silently picking a safety posture.
    NAMESPACE_REQUIRED = Object.new.freeze

    module_function

    # Sanitizes an SVG in place to the element/attribute/CSS allowlists above.
    #
    # id_namespace is required and forces a deliberate choice of where the
    # output may be used — there is no silently-wrong default:
    #
    # * a stable, per-document String (e.g. the upload sha) makes the output safe
    #   to inline into an HTML DOM: every id and every reference to it (href,
    #   url(#...), CSS) is prefixed with the namespace, and every <style> selector
    #   is scoped under the root, so a preserved <style> cannot reach the host
    #   page's cascade and ids cannot clobber host ids. Re-sanitising with the
    #   same namespace is a fixed point.
    # * :standalone produces document-safe output (no namespacing) for SVGs that
    #   are only ever served as an external `<img src>`, CSS url(...), or their
    #   own file — never spliced into an HTML DOM.
    def sanitize!(path, max_pixels: nil, id_namespace: NAMESPACE_REQUIRED)
      namespace = resolve_namespace(id_namespace)
      path = Pathname.new(SvgMetadata.safe_svg_path(path))
      begin
        SvgMetadata.dimensions(path.to_s, max_pixels: max_pixels)
      rescue InvalidImageError => e
        raise unless e.message.include?("dimensions are missing")
      end
      doc = SvgMetadata.parse(path.to_s)

      root = sanitize_element!(doc.root.deep_clone, namespace)
      if namespace
        neutralize_root_overflow!(root)
        apply_scope_class!(root, namespace) if contains_style?(root)
      end

      clean = REXML::Document.new
      clean.add_element(root)

      out = +""
      formatter = REXML::Formatters::Default.new
      formatter.write(clean, out)
      atomic_write(path, out)
      { format: "svg", sanitized: true, filesize: File.size(path.to_s) }
    rescue REXML::ParseException => e
      raise InvalidImageError, "invalid SVG: #{e.message}"
    end

    def sanitize_element!(element, namespace = nil)
      element.children.to_a.each do |child|
        case child
        when REXML::Element
          if child.name == "style"
            sanitize_style_element!(child, namespace)
          elsif ALLOWED_ELEMENTS.include?(child.name)
            sanitize_element!(child, namespace)
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

      # style is the one attribute whose value is CSS: it is rewritten to the
      # sanitized subset (or dropped) rather than kept verbatim, before the
      # allowlist pass below sees it.
      if (style = element.attributes["style"])
        sanitized_style = SvgCss.sanitize_declarations(style, namespace: namespace)
        if sanitized_style
          element.add_attribute("style", sanitized_style)
        else
          element.delete_attribute("style")
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

      namespace_references!(element, namespace) if namespace
      element
    end

    # A <style> element collapses to a single text node holding the sanitized
    # stylesheet, or is removed when nothing survives. Attributes (type,
    # media) are dropped: the sanitized output is plain CSS.
    def sanitize_style_element!(element, namespace = nil)
      css = element.children.grep(REXML::Text).map(&:value).join
      sanitized = SvgCss.sanitize_stylesheet(css, namespace: namespace)
      if sanitized.nil?
        element.remove
        return
      end

      element.children.to_a.each(&:remove)
      attribute_names = []
      element.attributes.each_attribute { |attr| attribute_names << attr.expanded_name }
      attribute_names.each { |name| element.delete_attribute(name) }
      element.add_text(sanitized)
    end

    # Prefixes this element's own id and every same-document reference it makes
    # (href/xlink:href fragments and url(#...) in any attribute) with the
    # namespace, keeping definitions and references consistent. The style
    # attribute's url()s are already namespaced by SvgCss above.
    def namespace_references!(element, namespace)
      if (id = element.attributes["id"])
        element.add_attribute("id", SvgCss.apply_namespace(namespace, id))
      end

      # Class names are attacker-chosen references into the host stylesheet:
      # inlined, a bare class="modal fixed" would pick up the page's framework
      # CSS (an overlay/UI-redress vector). Namespace each token — paired with the
      # matching rewrite of `.class` selectors — so internal class styling still
      # matches while host selectors never do.
      if (klass = element.attributes["class"])
        tokens = klass.to_s.split(/\s+/).reject(&:empty?)
        element.add_attribute("class", tokens.map { |t| SvgCss.apply_namespace(namespace, t) }.join(" ")) unless tokens.empty?
      end

      # REXML stores xlink:href with local name "href", so a name lookup aliases
      # the two; iterate the actual attributes and rewrite each by its real
      # (possibly prefixed) name so we never synthesize a duplicate plain href.
      href_rewrites = []
      element.attributes.each_attribute do |attr|
        next unless attr.name == "href"
        value = attr.value.to_s
        next unless value.start_with?("#")
        href_rewrites << [attr.expanded_name, "##{SvgCss.apply_namespace(namespace, value[1..])}"]
      end
      href_rewrites.each { |name, value| element.add_attribute(name, value) }

      ARIA_IDREF_ATTRIBUTES.each do |aria|
        value = element.attributes[aria]&.to_s
        ids = value.to_s.split(/\s+/).reject(&:empty?)
        next if ids.empty?
        element.add_attribute(aria, ids.map { |ref| SvgCss.apply_namespace(namespace, ref) }.join(" "))
      end

      rewrites = []
      element.attributes.each_attribute do |attr|
        name = attr.name.to_s
        next if name == "style"
        value = attr.value.to_s
        next unless value.match?(/url\(/i)
        rewritten = value.gsub(URL_FRAGMENT_REF) { "url(##{SvgCss.apply_namespace(namespace, Regexp.last_match(2))})" }
        rewrites << [name, rewritten] if rewritten != value
      end
      rewrites.each { |name, value| element.add_attribute(name, value) }
    end

    # Maps the required id_namespace argument to a namespace token, or nil for an
    # explicit standalone document. Forces the caller to decide, and rejects (does
    # not coerce) malformed tokens so two distinct callers' values can never
    # collapse to the same namespace.
    def resolve_namespace(id_namespace)
      case id_namespace
      when :standalone
        nil
      when String
        return id_namespace if id_namespace.match?(NAMESPACE_PATTERN)
        raise ArgumentError,
              "id_namespace: #{id_namespace.inspect} is not a valid namespace. It must be a letter " \
              "followed by letters/digits/_/- (e.g. prefix a sha like \"u<sha>\")."
      else
        raise ArgumentError,
              "id_namespace: is required. Pass a stable, per-document String (e.g. the upload sha) " \
              "to make the output safe to inline into HTML, or :standalone if it is only ever served " \
              "as an <img>/CSS-url/file and never spliced into a page's DOM."
      end
    end

    # Anchors a namespaced document's scoped <style> selectors: they target
    # `.<ns>-scope <selector>`, so the root must carry that class for them to
    # match its own content (and nothing else). Idempotent.
    def apply_scope_class!(root, namespace)
      scope = "#{namespace}-scope"
      classes = root.attributes["class"].to_s.split(/\s+/)
      return if classes.include?(scope)
      root.add_attribute("class", (classes << scope).join(" ").strip)
    end

    def contains_style?(element)
      return true if element.name == "style"
      element.children.any? { |child| child.is_a?(REXML::Element) && contains_style?(child) }
    end

    # In inline (namespaced) mode the root <svg> must clip to its own box, or a
    # tiny declared viewport with oversized content becomes a full-page overlay.
    # Drop any overflow the SVG set on the root so it falls back to the
    # outermost-svg default (hidden); inner elements keep overflow (markers need
    # it) and the root clip bounds them all. Standalone output is untouched — an
    # <img>/CSS-url resource is already clipped by its own element box.
    def neutralize_root_overflow!(root)
      root.delete_attribute("overflow")
      style = root.attributes["style"]
      return unless style

      kept = style.split(";").reject { |declaration| declaration.start_with?("overflow:") }
      if kept.empty?
        root.delete_attribute("style")
      else
        root.add_attribute("style", kept.join(";"))
      end
    end

    def dangerous_value?(value)
      # Presentation attributes are fed to browsers' CSS value parsers, where
      # escapes re-form tokens after the pattern checks below (\6c is "l", so
      # ur\6c( becomes url(). No allowlisted attribute legitimately contains
      # a backslash; reject outright.
      return true if value.to_s.include?("\\")

      normalized = value.to_s.gsub(/[\u0000-\u0020\u007f]+/, "")
      return true if normalized.match?(/(?:javascript|data):/i)

      # var()/env()/attr() resolve against the host page or element context, so an
      # inlined SVG could pull in host-controlled values the sanitizer never saw
      # — including a url() the namespace rewrite missed. They are inert in
      # standalone output anyway (no custom properties survive sanitisation), so
      # reject them in every mode.
      return true if normalized.match?(/(?:var|env|attr)\s*\(/i)

      # Every url(...) must be a same-document fragment in the canonical form the
      # namespace rewrite handles. Strip those, then fail closed if any url(
      # introducer remains: this catches external URLs, mismatched quotes, AND
      # unterminated/malformed url( that a complete-match scan would miss and
      # browsers may still parse leniently. Keeps validation and the rewrite in
      # lockstep, so no bare reference can survive in namespaced output.
      value.to_s.gsub(URL_FRAGMENT_REF, "").match?(/url\s*\(/i)
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
