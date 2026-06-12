# frozen_string_literal: true

require "pathname"
require "tempfile"
require_relative "svg_css"

module SafeImage
  # Allowlist SVG sanitizer. Parses untrusted SVG with Nokogiri (libxml2) and
  # builds a *fresh* output tree containing only allowlisted elements,
  # attributes, and namespaces — the svg-hush model. Nothing the attacker
  # declared is ever carried over: there is no "remove the bad parts" step
  # because only explicitly allowed content is ever added, so the output's
  # element/attribute/namespace sets are a closed allowlist by construction. A
  # bug therefore tends to drop legitimate content (fails closed, visible)
  # rather than leak attacker content (fails open, silent).
  #
  # The structural caps and the byte-level encoding/DOCTYPE/PI rejection run
  # first, in SvgMetadata, on the raw bytes — libxml2 only ever sees input that
  # already passed those gates, so its default internal-entity expansion is
  # unreachable (a DOCTYPE is rejected before parsing).
  module SvgSanitizer
    ALLOWED_ELEMENTS = %w[
      svg g defs title desc path rect circle ellipse line polyline polygon text tspan textPath
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

    SVG_NAMESPACE = "http://www.w3.org/2000/svg"
    XLINK_NAMESPACE = "http://www.w3.org/1999/xlink"

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

    # Elements that instantiate a referenced <marker> once per vertex, and the
    # attributes that carry the marker reference. Used by the render-expansion
    # bound.
    REPLICATING_ELEMENTS = %w[path line polyline polygon].freeze
    MARKER_ATTRIBUTES = %w[marker marker-start marker-mid marker-end].freeze

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
      require "nokogiri"

      namespace = resolve_namespace(id_namespace)
      path = Pathname.new(SvgMetadata.safe_svg_path(path))

      # Byte-level encoding/DOCTYPE/PI rejection and the streaming structural caps
      # run on the raw bytes before any DOM parse, so libxml2 only ever sees input
      # those gates already accepted.
      xml = SvgMetadata.read_svg(path.to_s)
      _root_name, root_attributes = SvgMetadata.scan_svg!(xml)
      begin
        SvgMetadata.dimensions_from_attributes(root_attributes, max_pixels: max_pixels)
      rescue InvalidImageError => e
        raise unless e.message.include?("dimensions are missing")
      end

      in_doc = parse(xml)
      in_root = in_doc.root
      raise InvalidImageError, "SVG root required" unless in_root && allowed_element?(in_root)

      out_doc = Nokogiri::XML::Document.new
      # Establish the output root before building anything under it: the root
      # carries the only namespace declarations we ever emit (svg always, xlink
      # lazily), and the recursive build references out_doc.root when an
      # xlink:href survives, so it must exist first.
      out_root = out_doc.create_element(in_root.name)
      out_doc.root = out_root
      out_root.namespace = svg_namespace(out_doc, out_root)
      populate_element(in_root, out_root, out_doc, namespace)

      # Reference namespacing runs as one pass over the fully-assembled tree, not
      # during the build: an attribute's namespace only resolves once its element
      # is attached under the root that declares the prefix, so href/url rewrites
      # must happen after the whole tree exists.
      if namespace
        namespace_tree!(out_root, namespace)
        drop_external_references!(out_root)
      end

      reject_render_expansion!(out_root)

      if namespace
        neutralize_root_overflow!(out_root)
        apply_scope_class!(out_root, namespace) if contains_style?(out_root)
      end

      atomic_write(path, serialize(out_root))
      { format: "svg", sanitized: true, filesize: File.size(path.to_s) }
    end

    # Hardened parse: no network, no external DTD load. DOCTYPE is already
    # rejected upstream, so entity expansion is unreachable; NONET is set
    # defensively regardless.
    def parse(xml)
      Nokogiri::XML(xml) do |config|
        config.options = Nokogiri::XML::ParseOptions::NONET
      end
    rescue Nokogiri::XML::SyntaxError => e
      raise InvalidImageError, "invalid SVG: #{e.message}"
    end

    # Builds the sanitized counterpart of an allowed input element as a child of
    # out_parent: the node is created, bound to the SVG namespace, and attached
    # *before* it is populated, so attribute namespaces (xlink) resolve against
    # the root's declarations during the build rather than on a detached node.
    def build_element(in_element, out_parent, out_doc, namespace)
      out = out_doc.create_element(in_element.name)
      out.namespace = svg_namespace(out_doc, out)
      out_parent.add_child(out)
      populate_element(in_element, out, out_doc, namespace)
      out
    end

    # Fills an already-created, already-attached output node from its input
    # counterpart: sanitized attributes, then sanitized children. <style>
    # collapses to its sanitized stylesheet text; CDATA becomes escaped text;
    # disallowed children are simply never created. Reference namespacing is NOT
    # done here — it is a separate post-build pass over the assembled tree.
    def populate_element(in_element, out, out_doc, namespace)
      if in_element.name == "style"
        build_style_element(in_element, out, namespace)
        return
      end

      copy_attributes(in_element, out, out_doc, namespace)

      in_element.children.each do |child|
        case child
        when Nokogiri::XML::CDATA, Nokogiri::XML::Text
          out.add_child(out_doc.create_text_node(child.content.to_s))
        when Nokogiri::XML::Element
          build_element(child, out, out_doc, namespace) if allowed_element?(child)
        end
      end
    end

    # A <style> element collapses to a single text node holding the sanitized
    # stylesheet. When nothing survives, the element itself is removed from the
    # output entirely (not left as an empty <style/>), matching the policy that a
    # stylesheet which fails closed leaves no trace. Element attributes (type,
    # media) are never copied: the output is plain CSS.
    def build_style_element(in_element, out, namespace)
      css = in_element.children.select { |c| c.text? || c.cdata? }.map(&:content).join
      sanitized = SvgCss.sanitize_stylesheet(css, namespace: namespace)
      if sanitized
        out.add_child(out.document.create_text_node(sanitized))
      else
        out.unlink
      end
    end

    # Copies only the attributes the policy allows, applying the same value
    # checks regardless of how the attribute is named. The style="" attribute is
    # the one whose value is CSS: it is rewritten to the sanitized subset (or
    # dropped). Reference namespacing happens later, over the assembled tree.
    def copy_attributes(in_element, out, out_doc, namespace)
      style_value = nil

      in_element.attribute_nodes.each do |attr|
        next if namespace_declaration?(attr)

        value = attr.value.to_s

        if attr_expanded_name(attr) == "style"
          sanitized = SvgCss.sanitize_declarations(value, namespace: namespace)
          sanitized = remove_marker_declarations(sanitized) unless replicating_element?(in_element)
          style_value = sanitized if sanitized
          next
        end

        next unless allowed_attribute?(attr)
        next if event_attribute?(attr)
        next if marker_attribute?(attr) && !replicating_element?(in_element)
        next if dangerous_value?(value)
        next if invalid_href?(attr)

        set_attribute(out, out_doc, attr, value)
      end

      out["style"] = style_value if style_value
    end

    # Applies reference namespacing to every element in the assembled output
    # tree. Done after the build so each attribute's namespace has resolved.
    def namespace_tree!(element, namespace)
      namespace_references!(element, namespace)
      element.children.each do |child|
        namespace_tree!(child, namespace) if child.is_a?(Nokogiri::XML::Element)
      end
    end

    # Inline-safe output must not bind to the host document (or another inlined
    # SVG) through a dangling fragment. After namespacing, every same-document
    # href, ARIA IDREF and url(#...) must resolve inside this sanitized tree; if
    # it does not, drop the reference-bearing attribute/declaration/rule.
    def drop_external_references!(root)
      id_map = {}
      collect_ids(root, id_map)
      drop_unresolved_references!(root, id_map)
    end

    def drop_unresolved_references!(element, id_map)
      if element.name.to_s == "style"
        filtered = filter_unresolved_stylesheet(element.text.to_s, id_map)
        if filtered
          element.children.remove
          element.add_child(element.document.create_text_node(filtered))
        else
          element.unlink
        end
        return
      end

      element.attribute_nodes.each do |attr|
        next unless href_attribute?(attr)

        value = attr.value.to_s
        attr.remove if value.start_with?("#") && !id_map.key?(value[1..])
      end

      ARIA_IDREF_ATTRIBUTES.each do |aria|
        value = element[aria]
        next unless value

        refs = value.split(/\s+/).select { |ref| id_map.key?(ref) }
        if refs.empty?
          element.remove_attribute(aria)
        else
          element[aria] = refs.join(" ")
        end
      end

      element.attribute_nodes.each do |attr|
        next if href_attribute?(attr)

        if attr.name.to_s == "style"
          filtered = filter_unresolved_declarations(attr.value.to_s, id_map)
          filtered ? attr.value = filtered : attr.remove
          next
        end

        value = attr.value.to_s
        next unless value.match?(/url\(/i)
        attr.remove if unresolved_url_fragment?(value, id_map)
      end

      element.children.each do |child|
        drop_unresolved_references!(child, id_map) if child.is_a?(Nokogiri::XML::Element)
      end
    end

    def filter_unresolved_stylesheet(css, id_map)
      rules = []
      css.to_s.scan(/([^{}]+)\{([^{}]*)\}/) do |selectors, body|
        declarations = filter_unresolved_declarations(body, id_map)
        rules << "#{selectors}{#{declarations}}" if declarations
      end
      rules.empty? ? nil : rules.join
    end

    def filter_unresolved_declarations(declarations, id_map)
      kept = declarations.to_s.split(";").reject { |declaration| unresolved_url_fragment?(declaration, id_map) }
      kept.empty? ? nil : kept.join(";")
    end

    def unresolved_url_fragment?(value, id_map)
      value.to_s.scan(URL_FRAGMENT_REF).any? { !id_map.key?(Regexp.last_match(2)) }
    end

    # Sets an attribute on the output node, preserving the xlink namespace for
    # xlink:href and writing everything else as a plain (no-namespace) attribute.
    # The xlink prefix is declared lazily on the output root the first time an
    # xlink:href actually survives, so we never emit an unused xmlns:xlink.
    def set_attribute(out, out_doc, attr, value)
      if href_attribute?(attr) && attr.namespace&.href == XLINK_NAMESPACE
        ensure_xlink(out_doc)
        out["xlink:href"] = value
      else
        out[attr.name.to_s] = value
      end
    end

    def ensure_xlink(out_doc)
      root = out_doc.root
      return if root.namespace_definitions.any? { |n| n.prefix == "xlink" }

      root.add_namespace_definition("xlink", XLINK_NAMESPACE)
    end

    def svg_namespace(out_doc, out)
      root = out_doc.root
      existing = root&.namespace_definitions&.find { |n| n.prefix.nil? && n.href == SVG_NAMESPACE }
      existing || out.add_namespace_definition(nil, SVG_NAMESPACE)
    end

    # --- policy predicates against Nokogiri's attribute/namespace model ---

    def allowed_element?(element)
      href = element.namespace&.href.to_s
      ALLOWED_ELEMENTS.include?(element.name.to_s) && (href.empty? || href == SVG_NAMESPACE)
    end

    # An attribute is allowed when it is a recognised href (plain or xlink) or a
    # no-namespace attribute on the allowlist (or an aria-* attribute). A prefixed
    # attribute in any other namespace is never copied.
    def allowed_attribute?(attr)
      return true if href_attribute?(attr)
      return false unless attr.namespace.nil?

      name = attr.name.to_s
      ALLOWED_ATTRIBUTES.include?(name) || name.start_with?("aria-")
    end

    def namespace_declaration?(attr)
      # Nokogiri does not surface xmlns declarations through attribute_nodes, but
      # guard defensively in case a libxml2 build does.
      name = attr.name.to_s
      name == "xmlns" || attr.namespace&.prefix == "xmlns" || name.start_with?("xmlns")
    end

    def event_attribute?(attr)
      attr.name.to_s.downcase.start_with?("on")
    end

    def marker_attribute?(attr)
      attr.namespace.nil? && MARKER_ATTRIBUTES.include?(attr.name.to_s)
    end

    def replicating_element?(element)
      REPLICATING_ELEMENTS.include?(element.name.to_s)
    end

    def remove_marker_declarations(style)
      return nil unless style

      kept = style.split(";").reject do |declaration|
        property = declaration.split(":", 2).first.to_s
        MARKER_ATTRIBUTES.include?(property)
      end
      kept.empty? ? nil : kept.join(";")
    end

    def href_attribute?(attr)
      name = attr.name.to_s
      return true if name == "href" && attr.namespace.nil?

      name == "href" && attr.namespace&.href == XLINK_NAMESPACE
    end

    def invalid_href?(attr)
      href_attribute?(attr) && !attr.value.to_s.start_with?("#")
    end

    def attr_expanded_name(attr)
      prefix = attr.namespace&.prefix
      prefix ? "#{prefix}:#{attr.name}" : attr.name.to_s
    end

    # Prefixes this element's own id and every same-document reference it makes
    # (href/xlink:href fragments, ARIA IDREFs, and url(#...) in any attribute)
    # with the namespace, keeping definitions and references consistent. The
    # style attribute's url()s are already namespaced by SvgCss.
    def namespace_references!(element, namespace)
      if (id = element["id"])
        element["id"] = SvgCss.apply_namespace(namespace, id)
      end

      # Class names are attacker-chosen references into the host stylesheet:
      # inlined, a bare class="modal fixed" would pick up the page's framework
      # CSS (an overlay/UI-redress vector). Namespace each token — paired with the
      # matching rewrite of `.class` selectors — so internal class styling still
      # matches while host selectors never do.
      if (klass = element["class"])
        tokens = klass.split(/\s+/).reject(&:empty?)
        element["class"] = tokens.map { |t| SvgCss.apply_namespace(namespace, t) }.join(" ") unless tokens.empty?
      end

      element.attribute_nodes.each do |attr|
        next unless href_attribute?(attr)
        value = attr.value.to_s
        next unless value.start_with?("#")
        attr.value = "##{SvgCss.apply_namespace(namespace, value[1..])}"
      end

      ARIA_IDREF_ATTRIBUTES.each do |aria|
        value = element[aria]
        next unless value
        ids = value.split(/\s+/).reject(&:empty?)
        next if ids.empty?
        element[aria] = ids.map { |ref| SvgCss.apply_namespace(namespace, ref) }.join(" ")
      end

      element.attribute_nodes.each do |attr|
        name = attr.name.to_s
        next if name == "style"
        value = attr.value.to_s
        next unless value.match?(/url\(/i)
        rewritten = value.gsub(URL_FRAGMENT_REF) { "url(##{SvgCss.apply_namespace(namespace, Regexp.last_match(2))})" }
        attr.value = rewritten if rewritten != value
      end
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
      classes = root["class"].to_s.split(/\s+/)
      return if classes.include?(scope)
      root["class"] = (classes << scope).join(" ").strip
    end

    def contains_style?(element)
      return true if element.name == "style"
      element.children.any? { |child| child.is_a?(Nokogiri::XML::Element) && contains_style?(child) }
    end

    # In inline (namespaced) mode the root <svg> must clip to its own box, or a
    # tiny declared viewport with oversized content becomes a full-page overlay.
    # Drop any overflow the SVG set on the root so it falls back to the
    # outermost-svg default (hidden); inner elements keep overflow (markers need
    # it) and the root clip bounds them all. Standalone output is untouched — an
    # <img>/CSS-url resource is already clipped by its own element box.
    def neutralize_root_overflow!(root)
      root.remove_attribute("overflow")
      style = root["style"]
      return unless style

      kept = style.split(";").reject { |declaration| declaration.start_with?("overflow:") }
      if kept.empty?
        root.remove_attribute("style")
      else
        root["style"] = kept.join(";")
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

    # Bounds the render tree the document instantiates. The structural caps in
    # SvgMetadata bound the *source* document, but several features replicate
    # referenced content at render time, so the sanitized output is walked once
    # and the instantiated render cost is accumulated against a single budget:
    #
    #   * a <use href="#id"> charges a deep copy of its target subtree — a chain
    #     of doubling groups fans a few dozen source nodes into billions (the
    #     "use bomb"), and a cyclic reference expands forever.
    #   * a path/line/polyline/polygon that references a <marker> charges
    #     (vertex count) x (referenced marker subtree cost): a marker is drawn
    #     once per vertex, so a dense `d` (~200k vertices in 1 MB) times a
    #     non-trivial marker is a linear-but-huge "draw bomb" the node/byte/
    #     element caps cannot see.
    #
    # The walk is memoised on subtree cost so it cannot itself blow up, with an
    # active-path set so a reference cycle is caught rather than recursed into.
    # Marker references are resolved against the same id map as <use>, so a marker
    # that contains <use> (or another marked path) composes naturally.
    def reject_render_expansion!(root)
      id_map = {}
      collect_ids(root, id_map)
      stylesheet_markers = stylesheet_marker_targets(root, id_map)
      subtree_render_cost(root, id_map, {}, {}, stylesheet_markers)
    end

    def collect_ids(element, id_map)
      id = element["id"]
      id_map[id.to_s] = element if id && !id_map.key?(id.to_s)
      element.children.each do |child|
        collect_ids(child, id_map) if child.is_a?(Nokogiri::XML::Element)
      end
    end

    def subtree_render_cost(element, id_map, memo, active, stylesheet_markers)
      key = element.object_id
      cached = memo[key]
      return cached if cached
      raise InvalidImageError, "SVG reference cycle" if active[key]

      active[key] = true
      cost = 1
      element.children.each do |child|
        next unless child.is_a?(Nokogiri::XML::Element)

        cost += subtree_render_cost(child, id_map, memo, active, stylesheet_markers)
        check_render_expansion!(cost)
      end

      if use_element?(element) && (target = use_target(element, id_map))
        cost += subtree_render_cost(target, id_map, memo, active, stylesheet_markers)
        check_render_expansion!(cost)
      end

      cost += marker_render_cost(element, id_map, memo, active, stylesheet_markers)
      check_render_expansion!(cost)

      active.delete(key)
      memo[key] = cost
    end

    # A marked path instantiates each referenced marker once per vertex. Charge
    # (vertex count) x (sum of distinct referenced marker subtree costs). The
    # marker subtree cost goes through subtree_render_cost too, so the active-path
    # set still catches a marker that references itself, and a marker containing a
    # <use> bomb is counted. Vertices are over-counted (see path_vertex_count),
    # which only makes the bound more conservative.
    def marker_render_cost(element, id_map, memo, active, stylesheet_markers)
      return 0 unless replicating_element?(element)

      markers = referenced_markers(element, id_map, stylesheet_markers)
      return 0 if markers.empty?

      vertices = path_vertex_count(element)
      return 0 if vertices.zero?

      per_vertex = markers.sum { |marker| subtree_render_cost(marker, id_map, memo, active, stylesheet_markers) }
      vertices * per_vertex
    end

    def stylesheet_marker_targets(root, id_map)
      targets = REPLICATING_ELEMENTS.to_h { |name| [name, []] }
      collect_stylesheet_marker_targets(root, id_map, targets)
      targets.transform_values(&:uniq)
    end

    def collect_stylesheet_marker_targets(element, id_map, targets)
      if element.name.to_s == "style"
        stylesheet_marker_rules(element.text.to_s).each do |element_names, refs|
          marker_targets = refs.filter_map { |ref| id_map[ref] }
          next if marker_targets.empty?

          element_names.each { |name| targets[name].concat(marker_targets) }
        end
      end

      element.children.each do |child|
        collect_stylesheet_marker_targets(child, id_map, targets) if child.is_a?(Nokogiri::XML::Element)
      end
    end

    def stylesheet_marker_rules(css)
      rules = []
      css.to_s.scan(/([^{}]+)\{([^{}]*)\}/) do |selectors, body|
        refs = []
        body.to_s.split(";").each do |declaration|
          property, value = declaration.split(":", 2)
          next unless MARKER_ATTRIBUTES.include?(property.to_s.strip)

          value.to_s.scan(URL_FRAGMENT_REF) { refs << Regexp.last_match(2) }
        end
        rules << [selector_replicating_element_names(selectors), refs.uniq] unless refs.empty?
      end
      rules
    end

    def selector_replicating_element_names(selectors)
      names = []
      selectors.to_s.split(",").each do |selector|
        selector_names = []
        selector.scan(/(?:\A|[\s>])(\*|path|line|polyline|polygon)(?=[\s>.#]|\z)/i) do |match|
          token = match.first.downcase
          return REPLICATING_ELEMENTS if token == "*"

          selector_names << token
        end
        # A pure class/id selector may match any geometry element.
        return REPLICATING_ELEMENTS if selector_names.empty?

        names.concat(selector_names)
      end
      names.empty? ? REPLICATING_ELEMENTS : names.uniq
    end

    # Collects the distinct marker subtrees a geometry element references, via
    # the marker-* presentation attributes or their style="" twins. Only the
    # canonical url(#fragment) form survives sanitisation, so one regex over the
    # marker attributes and the style attribute finds every reference.
    def referenced_markers(element, id_map, stylesheet_markers)
      sources = MARKER_ATTRIBUTES.map { |name| element[name].to_s }
      sources << element["style"].to_s
      targets = []
      sources.each do |value|
        value.scan(URL_FRAGMENT_REF) { targets << id_map[Regexp.last_match(2)] }
      end
      targets.concat(stylesheet_markers.fetch(element.name.to_s, []))
      targets.compact.uniq
    end

    # A deliberate upper bound on the vertices a geometry element renders, never
    # an exact parse: every run of digits in `d`/`points` is counted as a
    # coordinate, so the result is >= the real vertex count. Over-counting only
    # tightens the bound; under-counting would be the bug, so we never try to be
    # precise about path command grammar.
    def path_vertex_count(element)
      return 2 if element.name.to_s == "line"

      geometry = "#{element['d']} #{element['points']}"
      count = geometry.scan(/\d+(?:\.\d+)?/).length
      count.zero? ? 0 : count + 1
    end

    def check_render_expansion!(cost)
      return if cost <= SvgMetadata::MAX_SVG_RENDER_UNITS

      raise LimitError, "SVG render expansion exceeds #{SvgMetadata::MAX_SVG_RENDER_UNITS} rendered nodes"
    end

    def use_element?(element)
      element.name.to_s == "use" && (element.namespace&.href.to_s.empty? || element.namespace&.href == SVG_NAMESPACE)
    end

    def use_target(element, id_map)
      ref = nil
      element.attribute_nodes.each do |attr|
        next unless href_attribute?(attr)

        ref = attr.value.to_s
        break
      end
      return unless ref&.start_with?("#")

      id_map[ref[1..]]
    end

    def serialize(root)
      options = Nokogiri::XML::Node::SaveOptions::AS_XML |
                Nokogiri::XML::Node::SaveOptions::NO_DECLARATION
      xml = root.to_xml(save_with: options)
      xml = xml.sub(%( xmlns:xlink="#{XLINK_NAMESPACE}"), "") unless xlink_used?(root)
      xml
    end

    def xlink_used?(element)
      element.attribute_nodes.any? { |attr| href_attribute?(attr) && attr.namespace&.href == XLINK_NAMESPACE } ||
        element.children.any? { |child| child.is_a?(Nokogiri::XML::Element) && xlink_used?(child) }
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
