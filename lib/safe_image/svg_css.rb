# frozen_string_literal: true

require "strscan"

module SafeImage
  # Allowlist sanitizer for the small CSS subset SVG files legitimately use
  # (Inkscape writes style="" attributes, Illustrator writes class rules in
  # <style> elements). Output is constructed from validated tokens, never
  # echoed from the input, so nothing outside the vocabulary below can appear
  # in it. Anything the grammar does not recognise — escapes, quotes,
  # at-rules, comments, unknown properties or functions, non-fragment url() —
  # drops the declaration rather than being decoded.
  module SvgCss
    NO_FUNCTIONS = [].freeze
    URL_FUNCTIONS = %w[url].freeze
    COLOR_FUNCTIONS = %w[rgb rgba hsl hsla].freeze
    PAINT_FUNCTIONS = (COLOR_FUNCTIONS + URL_FUNCTIONS).freeze
    # Lowercase: function names are matched and emitted case-insensitively.
    TRANSFORM_FUNCTIONS = %w[matrix translate translatex translatey scale rotate skewx skewy].freeze

    # A CSS property is allowed exactly when its presentation-attribute twin is
    # in SvgSanitizer::ALLOWED_ATTRIBUTES (a test asserts this); the value is the
    # list of functions that property's values may call. The only functions that
    # reach a resource are url(...) — and those are constrained to same-document
    # #fragment references — so the URL surface is exactly the url()-bearing
    # rows below (paint servers, clip/mask, and markers), all fragment-only.
    ALLOWED_PROPERTIES = {
      # Paint and color. url() = paint-server reference (gradient/pattern).
      "fill" => PAINT_FUNCTIONS,
      "stroke" => PAINT_FUNCTIONS,
      "stop-color" => COLOR_FUNCTIONS,
      "color" => COLOR_FUNCTIONS,  # currentColor resolution; Inkscape/Illustrator
      "opacity" => NO_FUNCTIONS,
      "fill-opacity" => NO_FUNCTIONS,
      "stroke-opacity" => NO_FUNCTIONS,
      "stop-opacity" => NO_FUNCTIONS,
      "fill-rule" => NO_FUNCTIONS,
      "clip-rule" => NO_FUNCTIONS,
      # Stroke geometry. stroke-dasharray/dashoffset are how every dashed line
      # is expressed; vector-effect:non-scaling-stroke is an Inkscape default.
      "stroke-width" => NO_FUNCTIONS,
      "stroke-linecap" => NO_FUNCTIONS,
      "stroke-linejoin" => NO_FUNCTIONS,
      "stroke-miterlimit" => NO_FUNCTIONS,
      "stroke-dasharray" => NO_FUNCTIONS,
      "stroke-dashoffset" => NO_FUNCTIONS,
      "vector-effect" => NO_FUNCTIONS,
      # Geometry references. url() = clipPath/mask/marker element by #id.
      "clip-path" => URL_FUNCTIONS,
      "mask" => URL_FUNCTIONS,
      "marker" => URL_FUNCTIONS,
      "marker-start" => URL_FUNCTIONS,
      "marker-mid" => URL_FUNCTIONS,
      "marker-end" => URL_FUNCTIONS,
      "transform" => TRANSFORM_FUNCTIONS,
      # Visibility and rendering hints. Keywords/numbers only.
      "display" => NO_FUNCTIONS,
      "visibility" => NO_FUNCTIONS,
      "overflow" => NO_FUNCTIONS,
      "paint-order" => NO_FUNCTIONS,
      "mix-blend-mode" => NO_FUNCTIONS,
      "isolation" => NO_FUNCTIONS,
      "shape-rendering" => NO_FUNCTIONS,
      "image-rendering" => NO_FUNCTIONS,
      "color-interpolation" => NO_FUNCTIONS,
      # Text. Keywords/lengths only; no url() anywhere in text styling.
      "font-family" => NO_FUNCTIONS,
      "font-size" => NO_FUNCTIONS,
      "font-weight" => NO_FUNCTIONS,
      "font-style" => NO_FUNCTIONS,
      "font-variant" => NO_FUNCTIONS,
      "font-stretch" => NO_FUNCTIONS,
      "text-anchor" => NO_FUNCTIONS,
      "text-decoration" => NO_FUNCTIONS,
      "letter-spacing" => NO_FUNCTIONS,
      "word-spacing" => NO_FUNCTIONS,
      "dominant-baseline" => NO_FUNCTIONS,
      "baseline-shift" => NO_FUNCTIONS,
      "writing-mode" => NO_FUNCTIONS,
      "direction" => NO_FUNCTIONS
    }.freeze

    # Every character a declaration may contain. The exclusions do the work:
    # no backslash (CSS escapes re-form tokens after any pattern check), no
    # quotes (no strings, so no string-URL functions), no "@" (no at-rules),
    # no "*" — which keeps CSS comments (/* */) structurally impossible even
    # though "/" is admitted for modern color alpha (rgb(R G B / A)). A "/"
    # survives to output only via the color-function parser below; anywhere
    # else it fails tokenisation and the declaration drops.
    DECLARATION_CHARSET = %r{\A[a-zA-Z0-9 #%+.,()/:-]*\z}.freeze

    # CSS priority flag. Parsed out of the value structurally and re-emitted
    # canonically, so "!" never enters the value tokeniser.
    IMPORTANT = /\s*!\s*important\s*\z/i.freeze

    # url() may only reference the current document; same fragment shape
    # SvgSanitizer.dangerous_value? accepts.
    FRAGMENT = /#[A-Za-z][\w.-]*/.freeze

    HEX_COLOR = /#\h{3,8}/.freeze
    NUMBER = /[+-]?(?:\d+\.\d+|\.\d+|\d+)(?:%|px|pt|pc|em|rem|ex|ch|cm|mm|in|deg|rad|grad|turn)?/.freeze
    IDENT = /[a-zA-Z][a-zA-Z0-9-]*/.freeze
    FUNCTION_NAME = /[a-zA-Z][a-zA-Z0-9-]*(?=\()/.freeze
    SEPARATOR = /\s*,\s*|\s+/.freeze

    # Selectors: type/.class/#id compounds joined by descendant or child
    # combinators, in comma lists. The charset shuts out pseudo-classes (:),
    # attribute selectors ([), and everything the declaration charset already
    # excludes.
    SELECTOR_CHARSET = /\A[a-zA-Z0-9_ #.,*>-]*\z/.freeze
    SELECTOR_TYPE = /\*|[a-zA-Z][a-zA-Z0-9-]*/.freeze
    SELECTOR_QUALIFIER = /[.#][A-Za-z_][\w-]*/.freeze
    COMBINATOR = /\s*>\s*|\s+/.freeze

    module_function

    # Prefixes a bare id/fragment name with the document namespace, unless it is
    # already prefixed (so re-sanitising is a fixed point). A nil namespace is a
    # no-op, preserving the document-scoped (non-inline) behaviour.
    def apply_namespace(namespace, name)
      return name if namespace.nil? || name.start_with?("#{namespace}-")

      "#{namespace}-#{name}"
    end

    # Sanitizes a style="" declaration list. When a namespace is given, url(#id)
    # references are rewritten to url(#namespace-id) so they keep pointing at the
    # namespaced ids in the same document. Returns the constructed declaration
    # list, or nil when no declaration survives.
    def sanitize_declarations(css, namespace: nil)
      declarations = normalize(css).split(";").filter_map { |declaration| sanitize_declaration(declaration, namespace) }
      declarations.empty? ? nil : declarations.join(";")
    end

    # Sanitizes a <style> element's stylesheet. The structure scan accepts
    # only a flat list of "selectors { declarations }" rules — at-rules,
    # nested blocks, and unbalanced braces fail the whole sheet closed rather
    # than surviving in degraded form. Within a well-formed sheet, individual
    # selectors and declarations drop independently. Returns the constructed
    # stylesheet, or nil when no rule survives.
    def sanitize_stylesheet(css, namespace: nil)
      css = normalize(css)
      # At-rules (@import, @media, @font-face, @keyframes, ...) have no place in
      # the allowed subset, and "@" appears nowhere else in it. Rejecting it up
      # front fails the whole element closed — the rule-by-rule scan below would
      # otherwise drop only the at-rule and keep later rules, which contradicts
      # the documented guarantee and risks parser edge cases at the boundary.
      return nil if css.include?("@")

      scanner = StringScanner.new(css)
      rules = []
      until scanner.eos?
        scanner.skip(/\s+/)
        break if scanner.eos?

        selectors_src = scanner.scan(/[^{}]+/)
        return nil unless selectors_src && scanner.skip(/\{/)

        body = scanner.scan(/[^{}]*/)
        return nil unless scanner.skip(/\}/)

        selectors = sanitize_selectors(selectors_src, namespace)
        declarations = sanitize_declarations(body, namespace: namespace)
        rules << "#{selectors}{#{declarations}}" if selectors && declarations
      end
      rules.empty? ? nil : rules.join
    end

    def sanitize_selectors(src, namespace = nil)
      selectors = src.split(",").filter_map { |selector| sanitize_selector(selector.strip, namespace) }
      selectors.empty? ? nil : selectors.join(",")
    end

    def sanitize_selector(selector, namespace = nil)
      return nil if selector.empty? || !selector.match?(SELECTOR_CHARSET)

      scanner = StringScanner.new(selector)
      out = +""
      loop do
        compound = scan_compound(scanner, namespace)
        return nil unless compound

        out << compound
        break if scanner.eos?

        combinator = scanner.scan(COMBINATOR)
        return nil if combinator.nil? || scanner.eos?

        out << (combinator.include?(">") ? ">" : " ")
      end
      scope_selector(namespace, out)
    end

    # Confines a selector to the namespaced document by anchoring it under the
    # root's scope class, so a preserved <style> cannot reach a host page if the
    # SVG is inlined. Universal/type/class selectors that would otherwise match
    # host elements only match descendants of this document's root. Idempotent:
    # an already-scoped selector is returned unchanged.
    def scope_selector(namespace, selector)
      return selector if namespace.nil?

      scope = ".#{namespace}-scope"
      selector.start_with?("#{scope} ") ? selector : "#{scope} #{selector}"
    end

    def scan_compound(scanner, namespace = nil)
      out = +""
      if (type = scanner.scan(SELECTOR_TYPE))
        out << type
      end
      while (qualifier = scanner.scan(SELECTOR_QUALIFIER))
        out << namespace_qualifier(namespace, qualifier)
      end
      out.empty? ? nil : out
    end

    # Prefix an id (#x) or class (.x) selector's name with the namespace so it
    # matches only this document's namespaced ids/classes, never a host element's.
    # Type and universal selectors are left alone (they are confined by the root
    # scope class instead). Idempotent via apply_namespace.
    def namespace_qualifier(namespace, qualifier)
      return qualifier if namespace.nil?

      "#{qualifier[0]}#{apply_namespace(namespace, qualifier[1..])}"
    end

    def normalize(css)
      css.to_s.tr("\t\r\n\f\v", " ")
    end

    def sanitize_declaration(declaration, namespace = nil)
      important = ""
      if declaration.match?(IMPORTANT)
        declaration = declaration.sub(IMPORTANT, "")
        important = "!important"
      end
      return nil unless declaration.match?(DECLARATION_CHARSET)

      property, value = declaration.split(":", 2)
      return nil if value.nil?

      property = property.strip.downcase
      functions = ALLOWED_PROPERTIES[property]
      return nil unless functions

      value = sanitize_value(value.strip, functions, namespace)
      value && "#{property}:#{value}#{important}"
    end

    # A value is a comma- or space-separated list of tokens: keywords, numbers
    # with an allowlisted unit, hex colors, and allowlisted functions. The
    # output is reassembled from the matched tokens.
    def sanitize_value(value, functions, namespace = nil)
      scanner = StringScanner.new(value)
      out = +""
      loop do
        token = scan_token(scanner, functions, namespace)
        return nil unless token

        out << token
        break if scanner.eos?

        separator = scanner.scan(SEPARATOR)
        return nil if separator.nil? || scanner.eos?

        out << (separator.include?(",") ? "," : " ")
      end
      out
    end

    def scan_token(scanner, functions, namespace = nil)
      if (name = scanner.scan(FUNCTION_NAME))
        scan_function(scanner, name.downcase, functions, namespace)
      else
        scanner.scan(HEX_COLOR) || scanner.scan(NUMBER) || scanner.scan(IDENT)
      end
    end

    # The scanner is positioned at the "(". url() takes exactly one
    # same-document fragment; every other allowed function takes numbers.
    def scan_function(scanner, name, functions, namespace = nil)
      return nil unless functions.include?(name)

      scanner.skip(/\(\s*/)
      if name == "url"
        fragment = scanner.scan(FRAGMENT)
        return nil unless fragment && scanner.skip(/\s*\)/)

        "url(##{apply_namespace(namespace, fragment[1..])})"
      else
        args = []
        loop do
          arg = scanner.scan(NUMBER)
          return nil unless arg

          args << arg
          break if scanner.skip(/\s*\)/)
          # Modern color syntax: rgb(R G B / A). The slash separates the alpha,
          # and is accepted only here, only for color functions — the single
          # path by which "/" can reach output. Re-emitted in the space form
          # (mixing commas with "/" is invalid CSS), so the result is valid.
          if COLOR_FUNCTIONS.include?(name) && scanner.skip(%r{\s*/\s*})
            alpha = scanner.scan(NUMBER)
            return nil unless alpha && scanner.skip(/\s*\)/)

            return "#{name}(#{args.join(" ")} / #{alpha})"
          end
          return nil unless scanner.skip(SEPARATOR)
        end
        "#{name}(#{args.join(",")})"
      end
    end
  end
end
