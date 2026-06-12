# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # Regression tests for vulnerability classes seen in public SVG sanitizer and
  # renderer advisories (DOMPurify mXSS/nesting, Loofah data-SVG URLs,
  # enshrined/svg-sanitize mixed-case href, ImageTragick/librsvg external
  # resource/XInclude risks). The sanitizer's posture is stricter than many
  # libraries: no active content, no external/data URLs, no animation, no foreign
  # namespaces, and only same-document fragment references survive.
  class SvgCveRegressionTest < TestCase
    SVG_XMLNS = "http://www.w3.org/2000/svg"
    XLINK_XMLNS = "http://www.w3.org/1999/xlink"
    XHTML_XMLNS = "http://www.w3.org/1999/xhtml"
    XI_XMLNS = "http://www.w3.org/2001/XInclude"

    def test_mixed_case_href_and_xlink_href_are_not_resource_references
      out = sanitize(<<~SVG, id_namespace: "u1")
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <defs><g id="safe"/></defs>
          <use hReF="javascript:alert(1)"/>
          <use xlink:hReF="javascript:alert(2)"/>
          <use XLINK:href="javascript:alert(3)" xmlns:XLINK="#{XLINK_XMLNS}"/>
          <use xlink:href="#safe"/>
        </svg>
      SVG

      assert_includes out, 'xlink:href="#u1-safe"', "safe lowercase xlink fragment was lost"
      refute_match(/hReF|XLINK:href|javascript|alert/, out, "mixed-case href bypass survived")
    end

    def test_xlink_namespace_alias_or_rebinding_does_not_create_href_bypass
      out = sanitize(<<~SVG, id_namespace: "u1")
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="urn:not-xlink" xmlns:xl="#{XLINK_XMLNS}" width="10" height="10">
          <defs><g id="safe"/></defs>
          <use xl:href="javascript:alert(1)"/>
          <use xlink:href="#evil"/>
          <use href="#safe"/>
        </svg>
      SVG

      assert_includes out, 'href="#u1-safe"', "safe plain href fragment was lost"
      refute_match(/xl:href|xlink:href|javascript|evil/i, out, "namespace alias/rebinding href bypass survived")
    end

    def test_namespace_resets_and_non_svg_prefixes_are_pruned
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:evil="urn:evil" width="10" height="10">
          <g xmlns=""><rect width="10" height="10"/></g>
          <evil:rect width="10" height="10"/>
        </svg>
      SVG

      assert_includes out, "<g", "safe local-name child was dropped"
      refute_match(/xmlns=''|xmlns=""|evil:/, out, "namespace reset or non-SVG prefix survived")
    end

    def test_data_svg_payloads_in_use_or_links_are_removed
      payload = "data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9YWxlcnQoMSk+PC9zdmc+#x"
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <use href="#{payload}"/>
          <use xlink:href="#{payload}"/>
          <a href="#{payload}"><text>click</text></a>
        </svg>
      SVG

      refute_match(/data:image|base64|onload|alert|<a\b|href=/i, out, "data-SVG URL payload survived")
    end

    def test_foreign_content_mathml_and_html_namespace_mxss_shapes_are_removed
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:html="#{XHTML_XMLNS}" width="10" height="10">
          <foreignObject><html:div><html:img src="x" onerror="alert(1)"/></html:div></foreignObject>
          <math xmlns="http://www.w3.org/1998/Math/MathML"><mtext><svg><script>alert(2)</script></svg></mtext></math>
          <desc><![CDATA[</desc><script>alert(3)</script><desc>]]></desc>
          <rect width="10" height="10"/>
        </svg>
      SVG

      assert_includes out, "<rect", "safe sibling was dropped"
      refute_match(/foreignObject|html:|math|mtext|<script|onerror/i, out, "foreign-content/mXSS shape survived as markup")
      assert_includes out, "&lt;script&gt;", "CDATA text was not escaped as text"
    end

    def test_animation_cannot_mutate_safe_output_into_active_attributes
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <rect id="r" width="10" height="10">
            <animate attributeName="href" values="#ok;javascript:alert(1)"/>
            <set attributeName="onload" to="alert(2)"/>
            <animateTransform attributeName="transform" from="0" to="360"/>
          </rect>
        </svg>
      SVG

      assert_includes out, "<rect", "safe animated target element was dropped"
      refute_match(/animate|set|javascript|onload|alert/i, out, "SMIL/animation active mutation survived")
    end

    def test_xinclude_and_renderer_external_resource_elements_are_removed
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:xi="#{XI_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <xi:include href="file:///etc/passwd"/>
          <filter id="f"><feImage xlink:href="http://169.254.169.254/latest/meta-data/"/></filter>
          <image href="https://evil.example/pixel.png"/>
          <rect filter="url(#f)" fill="url(http://169.254.169.254/x)" width="10" height="10"/>
          <rect fill="url(#safe)" width="10" height="10"/>
        </svg>
      SVG

      assert_includes out, 'fill="url(#safe)"', "safe fragment paint server was lost"
      refute_match(/<xi:include\b|file:|<filter\b|<feImage\b|<image\b|169\.254|evil\.example/i, out,
                   "XInclude/renderer external resource survived")
      assert_no_active_or_fetching_attribute_values(out)
    end

    def test_imagetragick_style_pseudo_protocols_do_not_survive_svg_sanitization
      out = sanitize(<<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <image href="https://example.com/poc.mvg"/>
          <rect fill="url(msl:/tmp/poc)" stroke="url(label:@/etc/passwd)"/>
          <rect style="fill:url(ephemeral:/tmp/x);stroke:#000"/>
        </svg>
      SVG

      refute_match(/<image\b|mvg|msl:|label:|ephemeral:|etc\/passwd/i, out,
                   "ImageMagick pseudo-protocol/resource reference survived")
      assert_no_active_or_fetching_attribute_values(out)
    end

    # The "use bomb": a chain of groups that each <use> the previous one twice
    # fans a few dozen source nodes out to 2^n instantiated nodes at render time.
    # The source-document caps don't see this, so the sanitizer must bound the
    # expanded render tree and reject.
    def test_use_reference_expansion_bomb_is_rejected
      levels = 30
      defs = (1..levels).map do |i|
        %(<g id="l#{i}"><use href="#l#{i - 1}"/><use href="#l#{i - 1}"/></g>)
      end.join
      bomb = write_tmp("use-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <defs><g id="l0"><rect width="1" height="1"/></g>#{defs}</defs>
          <use href="#l#{levels}"/>
        </svg>
      SVG
      assert_raises(LimitError) { SafeImage.sanitize_svg!(bomb, id_namespace: "u1") }
    end

    # A <marker> is drawn once per vertex of every path/line/polyline/polygon
    # that references it, so (vertex count) x (marker subtree size) draws. A
    # dense `d` (~200k vertices in 1 MB) times a non-trivial marker is a
    # linear-but-huge render bomb that no node/byte/element cap can see; the
    # render-units accounting must charge it and reject.
    def test_marker_per_vertex_render_bomb_is_rejected
      marker = %(<marker id="m" markerWidth="2" markerHeight="2">#{'<rect width="1" height="1"/>' * 50}</marker>)
      segments = "L9,9 " * 180_000
      bomb = write_tmp("marker-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>#{marker}</defs>
          <path marker-mid="url(#m)" d="M0,0 #{segments}"/>
        </svg>
      SVG
      assert_raises(LimitError) { SafeImage.sanitize_svg!(bomb, id_namespace: "u1") }
    end

    # The marker reference can hide in a style="" twin of the marker-* attribute;
    # it must be charged the same way, and a points-based polyline counts too.
    def test_marker_render_bomb_via_style_and_points_is_rejected
      marker = %(<marker id="m" markerWidth="2" markerHeight="2">#{'<rect width="1" height="1"/>' * 50}</marker>)
      styled = write_tmp("marker-style-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>#{marker}</defs>
          <path style="marker-mid:url(#m)" d="M0,0 #{'L9,9 ' * 180_000}"/>
        </svg>
      SVG
      assert_raises(LimitError) { SafeImage.sanitize_svg!(styled, id_namespace: "u1") }

      points = write_tmp("marker-points-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>#{marker}</defs>
          <polyline marker-mid="url(#m)" points="#{'1,1 ' * 100_000}"/>
        </svg>
      SVG
      assert_raises(LimitError) { SafeImage.sanitize_svg!(points, id_namespace: "u1") }
    end

    def test_marker_render_bomb_via_line_vertices_is_rejected
      marker = %(<marker id="m" markerWidth="2" markerHeight="2">#{'<rect width="1" height="1"/>' * 1200}</marker>)
      lines = (1..1200).map { |i| %(<line x1="0" y1="#{i}" x2="1" y2="#{i}" marker-end="url(#m)"/>) }.join
      bomb = write_tmp("marker-line-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>#{marker}</defs>
          #{lines}
        </svg>
      SVG

      assert_raises(LimitError) { SafeImage.sanitize_svg!(bomb, id_namespace: "u1") }
    end

    def test_marker_render_bomb_via_stylesheet_rule_is_rejected
      marker = %(<marker id="m" markerWidth="2" markerHeight="2">#{'<rect width="1" height="1"/>' * 1200}</marker>)
      lines = (1..1200).map { |i| %(<polyline points="0,#{i} 1,#{i}"/>) }.join
      bomb = write_tmp("marker-css-bomb.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>#{marker}</defs>
          <style>polyline{marker-end:url(#m)}</style>
          #{lines}
        </svg>
      SVG

      assert_raises(LimitError) { SafeImage.sanitize_svg!(bomb, id_namespace: "u1") }
    end

    # A marker whose own content is itself a marked dense path: the multipliers
    # compose through the shared id resolution, so a pair of moderate factors
    # that each pass alone must be rejected when nested.
    def test_marker_composition_multiplies_through_nested_references
      composed = write_tmp("marker-compose.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs>
            <marker id="inner" markerWidth="2" markerHeight="2"><circle r="1"/></marker>
            <marker id="outer" markerWidth="2" markerHeight="2">
              <path marker-mid="url(#inner)" d="M0,0 #{'L9,9 ' * 2000}"/>
            </marker>
          </defs>
          <path marker-mid="url(#outer)" d="M0,0 #{'L9,9 ' * 2000}"/>
        </svg>
      SVG
      assert_raises(LimitError) { SafeImage.sanitize_svg!(composed, id_namespace: "u1") }
    end

    # A real marker diagram — a handful of arrows on short lines — must survive.
    # A single dense path with no marker reference (vertices but no multiplier)
    # must also survive: the bound charges replication, not geometry detail.
    def test_legitimate_marker_diagrams_and_dense_paths_are_preserved
      arrows = (1..20).map { |i| %(<line x1="0" y1="#{i}" x2="10" y2="#{i}" marker-end="url(#a)"/>) }.join
      diagram = sanitize(<<~SVG, id_namespace: "u1")
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <defs><marker id="a" markerWidth="6" markerHeight="6"><path d="M0,0 L6,3 L0,6 Z"/></marker></defs>
          #{arrows}
        </svg>
      SVG
      assert_equal 20, diagram.scan(/<line\b/).length, "legitimate arrow diagram was rejected/mangled"

      dense = write_tmp("dense-path.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="100" height="100">
          <path fill="none" stroke="#000" d="M0,0 #{'L9,9 ' * 150_000}"/>
        </svg>
      SVG
      assert SafeImage.sanitize_svg!(dense, id_namespace: "u1"), "dense marker-free path was wrongly rejected"
    end

    def test_use_reference_cycle_is_rejected
      direct = write_tmp("use-cycle.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <g id="a"><use href="#a"/></g>
          <use href="#a"/>
        </svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(direct, id_namespace: "u1") }

      mutual = write_tmp("use-cycle-mutual.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <g id="a"><use href="#b"/></g>
          <g id="b"><use href="#a"/></g>
          <use href="#a"/>
        </svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(mutual, id_namespace: "u1") }
    end

    def test_legitimate_use_and_symbol_references_are_preserved
      out = sanitize(<<~SVG, id_namespace: "u1")
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <defs><symbol id="s"><rect width="4" height="4"/></symbol><g id="g"><rect width="2" height="2"/></g></defs>
          <use href="#s"/>
          <use href="#g"/>
        </svg>
      SVG

      assert_includes out, '<symbol id="u1-s"', "legitimate symbol definition was dropped"
      assert_equal 2, out.scan(/<use\b/).length, "legitimate use references were dropped"
    end

    def test_doctype_external_entity_and_xml_stylesheet_are_rejected_before_dom_parse
      doctype = write_tmp("cve-xxe.svg", <<~SVG)
        <!DOCTYPE svg [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10"><text>&xxe;</text></svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(doctype, id_namespace: :standalone) }

      stylesheet = write_tmp("cve-pi.svg", <<~SVG)
        <?xml version="1.0"?>
        <?xml-stylesheet href="http://evil.example/x.css"?>
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10"/>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(stylesheet, id_namespace: :standalone) }
    end

    private

    def assert_no_active_or_fetching_attribute_values(svg)
      doc = REXML::Document.new(svg)
      walk(doc.root) do |element|
        element.attributes.each_attribute do |attr|
          next if attr.expanded_name == "xmlns" || attr.prefix.to_s == "xmlns"

          refute_match(/(?:https?|ftp|file|data|javascript|msl|label|ephemeral):/i, attr.value.to_s,
                       "fetching/active protocol survived in #{attr.expanded_name}=#{attr.value.inspect}")
        end
      end
    end

    def walk(element, &block)
      yield element
      element.children.each { |child| walk(child, &block) if child.is_a?(REXML::Element) }
    end

    def sanitize(svg, id_namespace: :standalone)
      path = write_tmp("cve-regression.svg", svg)
      SafeImage.sanitize_svg!(path, id_namespace: id_namespace)
      File.read(path)
    end
  end
end
