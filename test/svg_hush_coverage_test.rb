# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # Regression coverage for the public svg-hush test corpus in
  # ~/Source/svg-hush (tests/test.xml, tests/tests.rs, and the #[test]
  # vectors in src/lib.rs). safe_image intentionally has a stricter posture than
  # svg-hush: remote/relative/data URLs and embedded images are dropped instead
  # of rewritten or kept. These tests keep the same adversarial inputs and assert
  # safe_image's equivalent invariants.
  # Coverage map:
  # - tests/tests.rs::ns -> test_svg_hush_namespace_idempotence_case
  # - src/lib.rs::urlfunc -> test_svg_hush_urlfunc_vectors_in_presentation_attributes
  # - src/lib.rs::css -> test_svg_hush_css_declaration_vectors
  # - src/lib.rs::url_filter -> test_svg_hush_href_url_filter_vectors_are_fragment_only
  # - src/lib.rs::data_url_filter -> test_svg_hush_data_url_vectors_are_neutralized
  # - tests/test.xml -> presentation URL, style, mixed element/attribute, PI/DOCTYPE tests below
  # - fuzz/url.rs and fuzz/idempotent.rs -> covered here plus test/svg_css_fuzz_test.rb invariants
  class SvgHushCoverageTest < TestCase
    SVG_XMLNS = "http://www.w3.org/2000/svg"
    XLINK_XMLNS = "http://www.w3.org/1999/xlink"

    SVG_HUSH_URLFUNC_VALUES = [
      ["hello, url(world)", false],
      ["hello, world", true],
      ["hello, url(http://evil.com)", false],
      ["hello, url( http://evil.com )", false],
      ["hello, url( //evil.com )", false],
      ["url( /okay ), (), bye", false],
      ["hello, url( unclosed", false],
      ["hello, url( ) url(    ) bork", false],
      ["hello, url('1' )url(  2  ) bork", false],
      ["hello, url('(' )", false],
      ["aurl(burl(", false],
      ["uurl()rl(", false]
    ].freeze

    SVG_HUSH_CSS_DECLARATION_VECTORS = {
      "ok:url(data:text/plain;base64,AAA)" => nil,
      "color: red; background: URL(X); huh" => "color:red",
      "@import 'foo'; FONT-size: 1em;" => "font-size:1em",
      "u;url(data:x);rl(hack)" => nil,
      "u;\\;rl(hack)" => nil,
      "u;\\,rl(hack)" => nil,
      "u;\\url(hack)" => nil,
      "font-size: 1em; @Import 'foo';" => "font-size:1em",
      "@\\69MporT 'foo';" => nil,
      "color: red; background: URL( url(); huh)" => "color:red",
      "color: red; background: URL(//x/rel);" => "color:red",
      "color: red; background: URL(data:xx);" => "color:red",
      "color: red; background: UR\\L(x); border: blue" => "color:red",
      "prop: url (it is not);" => nil
    }.freeze

    SVG_HUSH_PRESENTATION_URL_VECTORS = [
      [%q{urL ('//spacecase.invalid/url.svg#p1')}, nil],
      [%q{url(./test.gif)}, nil],
      [%q{url(#p1)}, "u1-p1"],
      [%q{url(url.svg#p1)}, nil],
      [%q{url(//test.invalid/url.svg#p1)}, nil],
      [%q{url('//quotes.invalid/url.svg#p2')}, nil],
      [%q{url( &quot; //dquotes.invalid/url.svg#p3&quot;)}, nil],
      [%q{URL('//uppercase.invalid/url.svg#p4')}, nil],
      [%q{Url('//titlecase.invalid/url.svg#p5')}, nil],
      [%q{url(//innerparen.invalid/url.svg(\)#p6)}, nil],
      [%q{url('//innerparenq.invalid/url.svg()#p7')}, nil],
      [%q{ur\l('//backslash.invalid/url.svg()#p8')}, nil],
      [%q{url('http://x.example.com/test.svg')}, nil],
      [%q{url('https://x.example.com/test.svg')}, nil],
      [%q{  url(  ' https://x.example.com/test.svg '  ) }, nil],
      [%q{url('ftp://192.168.2.1/test.svg')}, nil],
      [%q{url('//x.example.com/test.svg')}, nil],
      [%q{url&#40;'//x.example.com/test.svg')}, nil],
      [%q{url(&quot;/test.svg&quot;)}, nil],
      [%q{ur&#108;('#test.svg')}, "u1-test.svg"]
    ].freeze

    SVG_HUSH_URL_FILTER_VECTORS = [
      ["http://test.com/a.jpg", nil],
      ["https://test.com:123/.././a/b/c.jpg", nil],
      ["/hello world.jpg", nil],
      ["b.jpg", nil],
      ["./x/", nil],
      ["#hash", nil],
      ["?q s", nil],
      ["//host/PAth", nil],
      ["//host/%2fpath", nil],
      ["//host%%%/path", nil],
      ["//host///path", nil],
      ["data:text/html,xx", nil],
      ["blob:123", nil],
      ["javascript:alert(1)", nil],
      ["jAvascript: alert(1)", nil],
      ["  jAvascript: alert(1) //http://", nil]
    ].freeze

    def test_svg_hush_namespace_idempotence_case
      path = write_tmp("svg-hush-ns.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" xmlns:svg="#{SVG_XMLNS}" xmlns:vector="#{SVG_XMLNS}" width="300" height="300">
          <rect height="300" width="300"/>
          <svg:rect height="200" width="200">
            <title>Test</title>
          </svg:rect>
          <vector:rect height="100" width="100"/>
          <svg:text xml:space="preserve">  Hallo World  </svg:text>
        </svg>
      SVG

      SafeImage.sanitize_svg!(path, id_namespace: :standalone)
      once = File.read(path)
      SafeImage.sanitize_svg!(path, id_namespace: :standalone)

      assert_equal once, File.read(path), "svg-hush namespace case is not idempotent"
      # svg:, vector:, and the default prefix are all bound to the SVG namespace,
      # so those elements are the same as <rect>/<text>; the allowlist-rebuild
      # emits them in canonical unprefixed form. Assert the elements survive by
      # local name rather than prefix spelling.
      root = REXML::Document.new(once).root
      names = []
      root.each_recursive { |e| names << e.name }
      assert_equal 3, names.count("rect"), "dropped an SVG rect (prefixed or not)"
      assert_includes names, "text", "dropped prefixed SVG text element"
      assert_includes once, "Hallo World", "lost text content from prefixed text element"
      refute_includes once, "xml:space", "kept non-allowlisted xml:space attribute"
    end

    def test_svg_hush_urlfunc_vectors_in_presentation_attributes
      SVG_HUSH_URLFUNC_VALUES.each_with_index do |(value, should_keep), index|
        tag = sanitize_single_element(%(<rect fill="#{xml_attr(value)}"/>), id_namespace: "u1", name: "urlfunc-#{index}.svg")

        if should_keep
          assert_includes tag, "fill=", "dropped harmless non-url fill value #{value.inspect}"
        else
          refute_match(/\bfill=/, tag, "kept unsafe or malformed url() fill value #{value.inspect}")
        end
        assert_no_fetching_url(tag, value)
      end
    end

    def test_svg_hush_css_declaration_vectors
      SVG_HUSH_CSS_DECLARATION_VECTORS.each do |css, expected|
        if expected.nil?
          assert_nil SvgCss.sanitize_declarations(css), "unexpected sanitization for #{css.inspect}"
        else
          assert_equal expected, SvgCss.sanitize_declarations(css), "unexpected sanitization for #{css.inspect}"
        end
      end

      assert_nil SvgCss.sanitize_stylesheet("sel, sel\\2 { bg: url(data:x); ba\\d; }"),
                 "kept svg-hush escaped selector/declaration vector"
    end

    def test_svg_hush_presentation_url_vectors_are_fragment_only
      SVG_HUSH_PRESENTATION_URL_VECTORS.each_with_index do |(value, expected_fragment), index|
        tag = sanitize_single_element(%(<rect fill="#{value}"/>), id_namespace: "u1", name: "paint-url-#{index}.svg")

        if expected_fragment
          assert_includes tag, "fill=\"url(##{expected_fragment})\"", "lost safe fragment reference #{value.inspect}"
        else
          refute_match(/\bfill=/, tag, "kept non-fragment url() paint value #{value.inspect}")
        end
        assert_no_fetching_url(tag, value)
      end
    end

    def test_svg_hush_href_url_filter_vectors_are_fragment_only
      SVG_HUSH_URL_FILTER_VECTORS.each_with_index do |(href, expected_fragment), index|
        tag = sanitize_single_element(%(<use href="#{xml_attr(href)}"/>), id_namespace: "u1", name: "href-url-#{index}.svg")

        if expected_fragment
          assert_includes tag, "href=\"##{expected_fragment}\"", "lost safe fragment href #{href.inspect}"
        else
          refute_match(/\bhref=/, tag, "kept non-fragment href #{href.inspect}")
        end
        assert_no_fetching_url(tag, href)
      end
    end

    def test_svg_hush_xlink_href_vectors_are_fragment_only
      out = sanitize_svg(<<~SVG, id_namespace: "u1", name: "xlink-vectors.svg")
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <defs><g id="safe"/></defs>
          <use xlink:href="javascript:alert(2)"/>
          <use xlink:href="data:image/svg+xml,%3Csvg%20onload='alert(88)'%3E"/>
          <use xlink:href="defs.svg#icon-1"/>
          <use xlink:href="#safe"/>
        </svg>
      SVG

      assert_includes out, 'xlink:href="#u1-safe"', "lost safe xlink fragment"
      refute_match(/javascript|data:image|defs\.svg|icon-1/i, out, "kept unsafe xlink href")
      refute_match(/xlink:href='(?!#u1-safe)/, out, "kept a non-fragment xlink href")
    end

    def test_svg_hush_data_url_vectors_are_neutralized
      out = sanitize_svg(<<~SVG, name: "data-url-vectors.svg")
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <rect fill="url(data:text/plain;base64,AAA)"/>
          <rect fill="url(data:text/plain,meh)"/>
          <image href="data:image/gif,GIF89a"/>
          <image href="data:image/svg,&lt;svg&gt;"/>
          <use href="data://wat"/>
          <use href="data:text/plain,meh"/>
          <use href="data:text/plain,hello%20test"/>
          <use href="data:text/html;base64,aGk#frag"/>
          <use href="data:image/gif,GIF89a"/>
          <use xlink:href="data:image/svg+xml,%3Csvg xmlns='#{SVG_XMLNS}' onload='alert(88)'%3E%3C/svg%3E"/>
          <a href="data:data:image/svg+xml,%3Csvg xmlns='#{SVG_XMLNS}' onload='alert(88)'%3E%3C/svg%3E">test</a>
        </svg>
      SVG

      refute_match(/data:/i, out, "kept data URL from svg-hush corpus")
      refute_match(/<image\b|<a\b/i, out, "kept embedded image/link element from data URL corpus")
      refute_match(/onload|alert/i, out, "kept decoded active data URL payload")
    end

    def test_svg_hush_style_element_vectors_are_removed_or_reduced
      out = sanitize_svg(<<~SVG, name: "style-vectors.svg")
        <svg xmlns="#{SVG_XMLNS}" xmlns:svg="#{SVG_XMLNS}" width="10" height="10">
          <style>@font-face {font-family: FontyFont;src: url(data:font/woff2;base64,d09GMgABAAAAABIkAA4AAAAAIAgAABHRAAEAAAAAAAAAAAA);}</style>
          <style>@font-face {font-family: FontyFont;src: url&#40;data:font/woff2;base64,d09GMgABAAAAABIkAA4AAAAAIAgAABHRAAEAAAAAAAAAAAA<!-- -->)<!-- -->;}</style>
          <style>@font-face {font-family: FontyFont;src: ur<![CDATA[l]]>(data:font/woff2;base64,d09GMgABAAAAABIkAA4AAAAAIAgAABHRAAEAAAAAAAAAAAA);}</style>
          <style><!-- @import "//example1.invalid/foo.css"; // this is parsed --></style>
          <style>@\\69MporT "//example2.invalid/foo.css";<!-- yeah, this is valid --></style>
          <style href="//x">xz {x:u<surprise>y</surprise>rl(http<surprise>y</surprise>://x/hello)}</style>
          <svg:style>@import "//example6.invalid/foo.css";</svg:style>
          <svg:style>honk {honk: honk;}</svg:style>
        </svg>
      SVG

      refute_match(/<style|<svg:style/i, out, "kept a svg-hush bad style element")
      refute_match(/@|font-face|import|data:|example\d?\.invalid|honk|surprise/i, out,
                   "kept unsafe stylesheet content from svg-hush corpus")
    end

    def test_svg_hush_mixed_element_and_attribute_corpus_is_neutralized
      out = sanitize_svg(<<~SVG, id_namespace: "u1", name: "mixed-corpus.svg")
        <svg version="1.1" xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" xml:space="preserve" the="1&quot; worst=&quot;" width="20" height="20">
          <img rdf:nodeID="abc" xmlns:rdf="urn:the-rdf-uri" />
          <image href="test.gif" x="333" y="444"/>
          <image src="//x.example.com/" />
          <image href="data:x" x="333" y="444"/>
          <image href="//test.invalid/x" x="333" y="444"/>
          <img href="test.gif" x="222" y="333"/>
          <img src="test.gif" x="222" y="333"/>
          <a href="/">link</a>
          <rect href="/" data-name="iris" class="eye" />
          <defs>
            <pattern id="p1" xmlns:x="#{XLINK_XMLNS}" patternUnits="userSpaceOnUse" width="32" height="32">
              <image x:href="test.gif" href="test.gif" width="32" height="32" />
            </pattern>
            <marker id="ok" markerWidth="2" markerHeight="2"><path d="M0 0 L2 1 L0 2 z"/></marker>
          </defs>
          <g id="righteye" class="eye" xml:space="preserve">
            <path style="fill:red; @\\import 'boo';" id="lid" data-name="lid" d="M0 0h10"/>
          </g>
          <metadata><link rel="canonical" href="/"/></metadata>
          <foreignObject x="2" y="2" width="16" height="16"><html xmlns="http://www.w3.org/1999/xhtml"><script>alert(1)</script></html></foreignObject>
          <line onload="alert(2)" xmlns:x="http://www.w3.org/1999/xhtml" x:onload="alert(5)" fill="none" stroke="#000000" stroke-miterlimit="10" x1="119" y1="84.5" x2="454" y2="84.5"/>
          <line marker-start="url(http://evil.example.com/../http://evil.example.com/)" style="fill:url(http://example3.invalid)" fill="none" stroke="#000000" stroke-miterlimit="10" x1="111.212" y1="102.852" x2="112.032" y2="476.623"/>
          <line style="background:url(//example4.invalid)" fill="none" stroke="#000000" stroke-miterlimit="10" x1="198.917" y1="510.229" x2="486.622" y2="501.213"/>
          <line xmlns:xhtml="http://www.w3.org/1999/xhtml" xhtml:style="background:url(http://example5.invalid)" fill="none" stroke="#000000" stroke-miterlimit="10" x1="484.163" y1="442.196" x2="89.901" y2="60.229"/>
          <line fill="none" stroke="#000000" stroke-miterlimit="10" x1="101.376" y1="478.262" x2="443.18" y2="75.803" marker-end="url(http://evil.example.com/?#remote)" marker-start="url(/abspath)" />
          <line fill="none" stroke="#000000" stroke-miterlimit="10" x1="457.114" y1="126.623" x2="458.753" y2="363.508" marker-end="url(#ok)" marker-start="url(//relpath///oops)"/>
          <bad><svg><script>alert(0);</script></svg></bad>
          <bad />
          <this>shouldn't be here</this>
          <script>alert(1);</script>
          <hax:script xmlns:hax="#{SVG_XMLNS}">alert(3);</hax:script>
          <html:script xmlns:html="http://www.w3.org/1999/xhtml">alert(4);</html:script>
          <g xmlns="nope"><script>alert(5);</script></g>
          <s:line xmlns:s="#{SVG_XMLNS}" fill="none" stroke="#000000" stroke-miterlimit="10" x1="1" y1="2" x2="3" y2="4"/>
        </svg>
      SVG

      refute_match(/<\/?(?:img|image|a|metadata|link|foreignObject|html|bad|this|script)\b/i, out,
                   "kept non-allowlisted element from svg-hush corpus")
      refute_match(/(?:onload|alert|javascript|data-name|xml:space|rdf:|the=|worst=|xmlns:rdf|xmlns:hax|xmlns:html|xmlns:x=|xmlns:xhtml|xhtml:|nope|evil|example\d?\.invalid|test\.invalid|background|@import)/i,
                   out, "kept non-allowlisted attribute/namespace or active payload")
      refute_match(/\bhref='\//, out, "kept root-relative href from svg-hush corpus")
      refute_match(/marker-start|url\(http|url\(\//i, out, "kept unsafe marker/url reference from svg-hush corpus")
      assert_includes out, 'style="fill:red"', "dropped safe declaration before escaped @import"
      assert_includes out, 'marker-end="url(#u1-ok)"', "dropped safe marker fragment while removing unsafe neighbors"
      assert_includes out, "<line", "dropped safe line after removing event handlers"
      # The s:-prefixed line is SVG-namespaced, so it is emitted canonically as
      # <line>; assert the final s:line (x1="1") survived rather than its prefix.
      assert_match(/<line[^>]*x1="1"/, out, "dropped safe SVG element using alternate prefix")
      assert_includes out, 'class="u1-eye"', "did not namespace surviving class token"
    end

    def test_svg_hush_doctype_and_processing_instruction_vectors_are_rejected
      doctype = write_tmp("svg-hush-doctype.svg", <<~SVG)
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10"/>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(doctype, id_namespace: :standalone) }

      pi = write_tmp("svg-hush-pi.svg", <<~SVG)
        <svg xmlns="#{SVG_XMLNS}" width="10" height="10">
          <?woop ?>
        </svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(pi, id_namespace: :standalone) }
    end

    private

    def sanitize_single_element(element, id_namespace: :standalone, name: "single.svg")
      out = sanitize_svg(<<~SVG, id_namespace: id_namespace, name: name)
        <svg xmlns="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" width="10" height="10">
          <defs><linearGradient id="p1"/><linearGradient id="test.svg"/></defs>
          #{element}
        </svg>
      SVG
      out[/<#{Regexp.escape(element[/\A<([\w:.-]+)/, 1])}\b[^>]*>/] || ""
    end

    def sanitize_svg(svg, id_namespace: :standalone, name: "svg-hush.svg")
      path = write_tmp(name, svg)
      SafeImage.sanitize_svg!(path, id_namespace: id_namespace)
      File.read(path)
    end

    def xml_attr(value)
      value.to_s.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def assert_no_fetching_url(output, context)
      refute_match(%r{(?:https?:|ftp:|data:|blob:|javascript:|//|(?:^|[\s'\"])/(?!>)|\.\.?/) }ix, output,
                   "kept fetching URL from #{context.inspect}: #{output}")
      refute_match(/(?:evil|invalid|example\.com|test\.gif|url\.svg|defs\.svg)/i, output,
                   "kept external test host/path from #{context.inspect}: #{output}")
    end
  end
end
