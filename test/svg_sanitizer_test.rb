# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class SvgSanitizerTest < TestCase
    def test_rejects_non_svg_root
      path = write_tmp("not.svg", "<html><body>nope</body></html>")
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(path, id_namespace: :standalone) }
    end

    def test_strips_active_content_and_keeps_fragment_references
      path = write_tmp("bad.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="alert(1)">
          <script>alert(1)</script>
          <style>@import url(http://evil.example/x.css); rect { fill: red; }</style>
          <foreignObject><iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;"></iframe></foreignObject>
          <image href="http://evil.example/track.png"/>
          <animate attributeName="x" from="0" to="10"/>
          <rect width="10" height="10" fill="url(http://evil.example/x)" onclick="alert(1)" onmouseover="alert(1)"/>
          <a href="javascript:alert(1)"><text>bad</text></a>
          <use href="#safe"/>
          <circle id="safe" r="2" fill="url(#safe)"/>
          <!-- <script>alert(1)</script> -->
          <text><![CDATA[<script>alert(1)</script>&xss;]]></text>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      refute_match(/<script/i, cleaned, "kept script element")
      refute_match(/<style/i, cleaned, "kept style element")
      refute_match(/foreignObject/i, cleaned, "kept foreignObject")
      refute_match(/<(?:iframe|object|embed|image)\b/i, cleaned, "kept embedded content element")
      refute_match(/<animate/i, cleaned, "kept animation")
      refute_includes cleaned, "evil.example", "kept external URL"
      refute_includes cleaned, "onload", "kept onload handler"
      refute_includes cleaned, "onclick", "kept onclick handler"
      refute_includes cleaned, "onmouseover", "kept onmouseover handler"
      refute_match(/javascript/i, cleaned, "kept javascript href")
      refute_includes cleaned, "<!--", "kept comment"
      refute_includes cleaned, "CDATA", "kept CDATA section"

      assert cleaned.include?("href='#safe'") || cleaned.include?('href="#safe"'), "stripped fragment href"
      assert_includes cleaned, "url(#safe)", "stripped fragment url"
      assert_includes cleaned, "&lt;script&gt;", "failed to escape text content"
      assert_includes cleaned, "&amp;xss;", "failed to escape entity in text"
    end

    def test_strips_entity_encoded_external_urls
      path = write_tmp("encoded-url.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect width="10" height="10" fill="url(&#104;ttp://evil.example/x)"/>
          <a href="jav&#x61;script:alert(1)"><text>bad</text></a>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      refute_includes cleaned, "evil.example", "kept entity-encoded URL"
      refute_match(/javascript/i, cleaned, "kept entity-encoded javascript")
    end

    def test_sanitizes_style_attributes
      path = write_tmp("styled.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect width="10" height="10" style="fill:#ff0000;stroke:none"/>
          <circle r="4" style="fill: url(#grad) ;cursor:url(http://evil.example/c.cur),pointer"/>
          <path d="M0 0h10" style="fill:ur\\6c(http://evil.example/x)"/>
          <text style="@import url(http://evil.example/x.css);font-size:12px">hi</text>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, "fill:#ff0000;stroke:none", "lost benign style declarations"
      assert_includes cleaned, "style='fill:url(#grad)'", "lost fragment paint reference"
      assert_includes cleaned, "font-size:12px", "lost declaration following a dropped one"
      refute_includes cleaned, "evil.example", "kept external URL from style"
      refute_includes cleaned, "\\", "kept CSS escape"
      refute_match(/@import/i, cleaned, "kept @import")
      refute_includes cleaned, "cursor", "kept non-allowlisted property"
    end

    def test_drops_presentation_attributes_with_css_escapes
      path = write_tmp("escape-attr.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect width="10" height="10" fill="ur\\6c(http://evil.example/x)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      refute_includes cleaned, "evil.example", "kept escape-obfuscated external URL"
      refute_includes cleaned, "fill", "kept attribute containing a CSS escape"
    end

    def test_keeps_sanitized_style_elements
      path = write_tmp("illustrator.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <style type="text/css">
            .st0{fill:#FF0000;stroke:#000;}
            .st1, g > rect.st2 {fill:url(#grad);}
            .leak{fill:url(http://evil.example/x);}
            .hover-rule:hover{fill:red;}
          </style>
          <rect class="st0" width="10" height="10"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, ".st0{fill:#FF0000;stroke:#000}", "lost benign class rule"
      assert_includes cleaned, ".st1,g&gt;rect.st2{fill:url(#grad)}", "lost selector list with child combinator"
      refute_includes cleaned, "evil.example", "kept external URL from stylesheet"
      refute_includes cleaned, ":hover", "kept pseudo-class rule"
      refute_includes cleaned, ".leak", "kept rule whose declarations were all dropped"
      refute_includes cleaned, "text/css", "kept style element attributes"
    end

    def test_keeps_cdata_wrapped_stylesheets
      path = write_tmp("cdata-style.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <style><![CDATA[.a{fill:#0f0} .b{fill:ur\\6c(http://evil.example/x)}]]></style>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, ".a{fill:#0f0}", "lost CDATA-wrapped rule"
      refute_includes cleaned, "evil.example", "kept escape-obfuscated URL from CDATA"
      refute_includes cleaned, "CDATA", "kept CDATA section"
    end

    def test_removes_style_elements_that_fail_closed
      [
        "@import url(http://evil.example/x.css);",
        "@media (min-width: 1px) { .a{fill:red} }",
        "@font-face{src:url(http://evil.example/f.woff)}",
        ".a{fill:red} }"
      ].each do |css|
        path = write_tmp("bad-sheet.svg", <<~SVG)
          <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <style>#{css}</style>
          </svg>
        SVG

        SafeImage.sanitize_svg!(path, id_namespace: :standalone)
        cleaned = File.read(path)

        refute_match(/<style/i, cleaned, "kept style element for: #{css}")
        refute_includes cleaned, "evil.example", "kept external URL for: #{css}"
      end
    end

    # Real Inkscape 1.4 exports (round-tripped through the editor) as fixtures:
    # one in presentation-attribute form, one with GUI style="" packing. Both
    # must keep their styling and drop the editor's own namespaced cruft.
    def test_sanitizes_real_inkscape_attribute_export
      path = tmp_path("inkscape_attrs.svg")
      FileUtils.cp(File.join(FIXTURES, "inkscape_attrs.svg"), path)

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, "<marker", "dropped marker element"
      assert_includes cleaned, "marker-end='url(#arrow)'", "dropped fragment marker reference"
      assert_includes cleaned, "stroke-dasharray='6,3'", "dropped dash pattern"
      assert_includes cleaned, "vector-effect='non-scaling-stroke'", "dropped vector-effect"
      assert_includes cleaned, "fill='url(#g)'", "dropped gradient paint reference"
      refute_includes cleaned, "sodipodi", "kept editor namespace cruft"
      refute_includes cleaned, "inkscape:", "kept editor namespace cruft"
      refute_includes cleaned, "namedview", "kept editor-only element"
    end

    def test_sanitizes_real_inkscape_style_export
      path = tmp_path("inkscape_style.svg")
      FileUtils.cp(File.join(FIXTURES, "inkscape_style.svg"), path)

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      %w[stroke-dasharray:6,3 vector-effect:non-scaling-stroke display:inline
         font-style:italic letter-spacing:1px paint-order:stroke].each do |decl|
        assert_includes cleaned, decl, "dropped #{decl} from real Inkscape style"
      end
      refute_includes cleaned, "sodipodi", "kept editor namespace cruft"
    end

    def test_keeps_marker_elements_and_fragment_references
      path = write_tmp("markers.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
          <defs>
            <marker id="a" markerWidth="6" markerHeight="6" refX="3" refY="3" orient="auto">
              <path d="M0 0 L6 3 L0 6 z"/>
            </marker>
          </defs>
          <line x1="0" y1="0" x2="20" y2="20" stroke="#000" marker-end="url(#a)"/>
          <line x1="0" y1="20" x2="20" y2="0" stroke="#000" marker-end="url(http://evil.example/m)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, "<marker", "dropped marker element"
      assert_includes cleaned, "marker-end='url(#a)'", "dropped fragment marker reference"
      refute_includes cleaned, "evil.example", "kept external marker reference"
    end

    def test_id_namespace_is_required
      path = write_tmp("needs-choice.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>')
      error = assert_raises(ArgumentError) { SafeImage.sanitize_svg!(path) }
      assert_match(/id_namespace/, error.message)
      assert_match(/:standalone/, error.message)
      # explicit choices both work
      assert SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      assert SafeImage.sanitize_svg!(path, id_namespace: "u1")
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(path, id_namespace: "") }
      assert_raises(ArgumentError) { SafeImage.sanitize_svg!(path, id_namespace: nil) }
    end

    def test_id_namespace_makes_output_inline_safe
      path = write_tmp("inline.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
          <defs><linearGradient id="grad"><stop offset="0" stop-color="#0a0"/></linearGradient></defs>
          <style>#header{display:none} *{visibility:hidden} .box{fill:url(#grad)}</style>
          <rect id="header" class="box" width="40" height="40" fill="url(#grad)" style="stroke:url(#grad)"/>
          <use href="#header"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "up42")
      cleaned = File.read(path)

      # definitions and every reference move together
      assert_includes cleaned, "id='up42-grad'", "gradient id not namespaced"
      assert_includes cleaned, "fill='url(#up42-grad)'", "fill ref not namespaced"
      assert_includes cleaned, "stroke:url(#up42-grad)", "style-attr ref not namespaced"
      assert_includes cleaned, "id='up42-header'", "element id not namespaced"
      assert_includes cleaned, "href='#up42-header'", "use ref not namespaced"
      # host-affecting selectors are confined under the root scope class
      assert_includes cleaned, "class='up42-scope'", "root missing scope class"
      assert_includes cleaned, ".up42-scope *{visibility:hidden}", "universal selector not scoped"
      assert_includes cleaned, ".up42-scope #up42-header{display:none}", "id selector not scoped/namespaced"
      # nothing references the bare, host-colliding names anymore
      refute_match(/url\(#grad\)/, cleaned, "bare gradient ref leaked")
      refute_match(/(?<![\w-])#header\{/, cleaned, "bare #header selector leaked")
    end

    def test_namespaces_quoted_and_uppercase_url_references
      path = write_tmp("urlforms.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <defs><linearGradient id="g"/><clipPath id="c"/><marker id="arrow"/></defs>
          <rect fill="URL(#g)" clip-path="url('#c')"/>
          <line marker-end='url("#arrow")'/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      # every reference form is namespaced (and canonicalised to unquoted lowercase)
      assert_includes cleaned, "fill='url(#u1-g)'", "uppercase URL() not namespaced"
      assert_includes cleaned, "clip-path='url(#u1-c)'", "single-quoted url not namespaced"
      assert_includes cleaned, "marker-end='url(#u1-arrow)'", "double-quoted url not namespaced"
      # no bare reference survives
      refute_match(/url\(\s*['"]?#(?!u1-)/i, cleaned, "a bare fragment reference survived")
    end

    def test_drops_malformed_and_unterminated_url_references
      path = write_tmp("malformed.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <defs><linearGradient id="g"/></defs>
          <rect fill="url(http://evil.example/x"/>
          <rect fill="url(#g"/>
          <rect clip-path="url (#g)"/>
          <line marker-end="URL(http://evil.example/m"/>
          <rect fill="url(#g)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      refute_includes cleaned, "evil.example", "kept an unterminated external URL"
      assert_includes cleaned, "fill='url(#u1-g)'", "dropped the one valid reference"
      # no url( introducer survives except the complete, namespaced fragment form
      refute_match(/url\s*\(\s*['"]?#(?!u1-)/i, cleaned, "a bare/unnamespaced fragment survived")
      refute_match(/url\s*\(\s*['"]?[^#]/i, cleaned, "a non-fragment url( survived")
    end

    def test_namespaces_class_names_so_host_css_cannot_bind
      path = write_tmp("classes.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" class="modal fixed">
          <style>.st0{fill:red} .st0.active{stroke:blue}</style>
          <rect class="st0 btn-danger active" width="10" height="10"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      # every class token in every class attribute is namespaced (no bare token)
      cleaned.scan(/class='([^']*)'/).flatten.each do |attr|
        attr.split.each do |token|
          assert token.start_with?("u1-"), "bare class token #{token.inspect} survived"
        end
      end
      assert_includes cleaned, "class='u1-modal u1-fixed u1-scope'", "root classes not namespaced"
      assert_includes cleaned, "class='u1-st0 u1-btn-danger u1-active'", "element classes not namespaced"
      # internal class styling still matches: selector classes are prefixed the same way
      assert_includes cleaned, ".u1-scope .u1-st0{fill:red}", "class selector not namespaced to match"
      assert_includes cleaned, ".u1-scope .u1-st0.u1-active{stroke:blue}", "compound class selector not namespaced"
    end

    def test_rejects_host_reaching_css_functions
      path = write_tmp("var.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <rect fill="var(--host-fill)" stroke="env(safe-area-inset-top)" opacity="attr(data-o)"/>
          <rect fill="#0a0" style="fill:var(--x);stroke:#00f"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      refute_match(/var\s*\(/i, cleaned, "var() survived")
      refute_match(/env\s*\(/i, cleaned, "env() survived")
      refute_match(/attr\s*\(/i, cleaned, "attr() survived")
      assert_includes cleaned, "fill='#0a0'", "dropped a safe presentation attribute"
      assert_includes cleaned, "stroke:#00f", "dropped the safe half of a style declaration"
    end

    def test_namespaces_xlink_href_without_duplicating
      path = write_tmp("xlink.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">
          <defs><rect id="shape" width="4" height="4"/></defs>
          <use xlink:href="#shape"/>
          <use href="#shape"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      assert_includes cleaned, "id='u1-shape'", "definition id not namespaced"
      assert_includes cleaned, "xlink:href='#u1-shape'", "xlink:href not namespaced"
      # the xlink:href <use> must not gain a synthesized plain href
      assert_equal 1, cleaned.scan("xlink:href='#u1-shape'").length
      assert_equal 1, cleaned.scan(/(?<!:)href='#u1-shape'/).length, "an extra plain href was synthesized"
    end

    def test_namespaces_aria_idref_references
      path = write_tmp("aria.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <title id="title">label</title>
          <desc id="desc">described</desc>
          <rect aria-labelledby="header title" aria-describedby="desc" aria-label="plain text" aria-controls="a b"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      cleaned = File.read(path)

      assert_includes cleaned, "aria-labelledby='u1-header u1-title'", "IDREFS list not namespaced"
      assert_includes cleaned, "aria-describedby='u1-desc'", "single IDREF not namespaced"
      assert_includes cleaned, "aria-controls='u1-a u1-b'", "IDREFS not namespaced"
      assert_includes cleaned, "aria-label='plain text'", "free-text aria attribute was mangled"
      # every token in every aria IDREF attribute is namespaced
      %w[aria-labelledby aria-describedby aria-controls].each do |aria|
        cleaned[/#{aria}='([^']*)'/, 1].to_s.split.each do |ref|
          assert ref.start_with?("u1-"), "bare aria id reference #{ref.inspect} survived in #{aria}"
        end
      end
    end

    def test_standalone_leaves_aria_idrefs_bare
      path = write_tmp("aria-standalone.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <title id="title">label</title>
          <rect aria-labelledby="title"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)
      assert_includes cleaned, "id='title'", "standalone namespaced an id"
      assert_includes cleaned, "aria-labelledby='title'", "standalone namespaced an aria reference"
    end

    def test_inline_mode_clips_root_overflow
      svg = <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" overflow="visible" style="overflow:visible;fill:red">
          <marker id="m" style="overflow:visible"/>
          <rect width="9999" height="9999"/>
        </svg>
      SVG

      inline = write_tmp("ov-inline.svg", svg)
      SafeImage.sanitize_svg!(inline, id_namespace: "u1")
      out = File.read(inline)
      root_open = out[/<svg[^>]*>/]
      refute_match(/overflow/, root_open, "root overflow not neutralized in inline mode")
      assert_match(/fill:red/, root_open, "other root style declarations were lost")
      assert_includes out, "<marker id='u1-m' style='overflow:visible'", "inner overflow was stripped"

      standalone = write_tmp("ov-standalone.svg", svg)
      SafeImage.sanitize_svg!(standalone, id_namespace: :standalone)
      assert_match(/overflow/, File.read(standalone)[/<svg[^>]*>/], "standalone root overflow changed")
    end

    def test_id_namespace_rejects_malformed_tokens
      path = write_tmp("ns.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>')
      ["tenant/1", "1abc", "!!!", "a b", "a.b"].each do |bad|
        assert_raises(ArgumentError, "accepted malformed namespace #{bad.inspect}") do
          SafeImage.sanitize_svg!(path, id_namespace: bad)
        end
      end
      # valid tokens are accepted verbatim (never coerced)
      assert SafeImage.sanitize_svg!(path, id_namespace: "u_1-x")
    end

    def test_id_namespace_is_idempotent
      svg = <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
          <defs><linearGradient id="g"><stop offset="0" stop-color="#00f"/></linearGradient></defs>
          <style>*{opacity:.9}</style>
          <rect id="r" width="20" height="20" fill="url(#g)"/>
        </svg>
      SVG
      path = write_tmp("idem.svg", svg)
      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      once = File.read(path)
      SafeImage.sanitize_svg!(path, id_namespace: "u1")
      assert_equal once, File.read(path), "namespaced sanitize is not a fixed point"
    end

    def test_without_namespace_ids_and_styles_stay_bare
      path = write_tmp("bare.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
          <defs><linearGradient id="g"><stop offset="0" stop-color="#00f"/></linearGradient></defs>
          <rect id="r" width="20" height="20" fill="url(#g)"/>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      cleaned = File.read(path)

      assert_includes cleaned, "id='g'", "id was namespaced without id_namespace"
      assert_includes cleaned, "fill='url(#g)'", "ref was namespaced without id_namespace"
      refute_includes cleaned, "-scope", "scope class added without id_namespace"
    end

    def test_rejects_dtd_entity_payloads
      path = write_tmp("dtd-entity.svg", <<~SVG)
        <?xml version="1.0"?>
        <!DOCTYPE svg [ <!ENTITY xss "<script>alert(1)</script>"> ]>
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
          <text>&xss;</text>
        </svg>
      SVG

      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(path, id_namespace: :standalone) }
    end

    def test_rejects_huge_dimensions
      path = write_tmp("huge.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"></svg>')
      assert_raises(LimitError) { SafeImage.sanitize_svg!(path, id_namespace: :standalone) }
    end

    # A UTF-16 DOCTYPE slips past the ASCII byte-level DOCTYPE guard, so the
    # sanitizer must reject non-UTF-8 input outright rather than hand it to REXML.
    def test_rejects_utf16_encoded_payload
      src = <<~SVG
        <?xml version="1.0"?>
        <!DOCTYPE svg [ <!ENTITY xss "<script>alert(1)</script>"> ]>
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&xss;</svg>
      SVG
      path = tmp_path("utf16-payload.svg")
      File.binwrite(path, ("﻿".encode(Encoding::UTF_16LE) + src.encode(Encoding::UTF_16LE)).b)
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(path, id_namespace: :standalone) }
    end
  end
end
