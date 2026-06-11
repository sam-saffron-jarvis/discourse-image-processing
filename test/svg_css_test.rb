# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  class SvgCssTest < TestCase
    def test_keeps_inkscape_style_declarations
      css = "fill:#ff0000;stroke:none;stroke-width:2.5;fill-opacity:.5"
      assert_equal css, SvgCss.sanitize_declarations(css)
    end

    def test_canonicalizes_case_whitespace_and_separators
      assert_equal "fill:rgb(255,0,0);transform:translate(3,4) rotate(45deg)",
                   SvgCss.sanitize_declarations("FILL: rgb(255, 0, 0) ; transform: translate(3 4)  rotate(45deg)")
    end

    def test_keeps_fragment_urls_only
      assert_equal "fill:url(#grad)", SvgCss.sanitize_declarations("fill:url( #grad )")
      assert_nil SvgCss.sanitize_declarations("fill:url(http://evil.example/x)")
      assert_nil SvgCss.sanitize_declarations("fill:url(//evil.example/x)")
      assert_nil SvgCss.sanitize_declarations("fill:url(data:text/html,x)")
      assert_nil SvgCss.sanitize_declarations("fill:url(grad)")
      assert_nil SvgCss.sanitize_declarations("clip-path:url(#default#time2)")
    end

    def test_rejects_escape_and_encoding_obfuscation
      assert_nil SvgCss.sanitize_declarations("fill:ur\\6c(#a)")
      assert_nil SvgCss.sanitize_declarations("fill:u\u0000rl(#a)")
      assert_nil SvgCss.sanitize_declarations("fill:red\u00A0")
    end

    def test_drops_unknown_at_rule_and_quoted_declarations_individually
      kept = SvgCss.sanitize_declarations(
        "@import url(#x);fill:red;font-family:'Comic Sans';background:red;cursor:pointer"
      )
      assert_equal "fill:red", kept
    end

    def test_blocks_custom_property_laundering
      assert_nil SvgCss.sanitize_declarations("--x:url(#f);fill:var(--x)")
    end

    def test_blocks_string_url_functions
      assert_nil SvgCss.sanitize_declarations('fill:image-set("http://evil.example/x.png" 1x)')
      assert_nil SvgCss.sanitize_declarations("fill:image-set(#x 1x)")
    end

    def test_restricts_functions_per_property
      # url() is a paint-server reference, not an opacity or transform value.
      assert_nil SvgCss.sanitize_declarations("opacity:url(#x)")
      assert_nil SvgCss.sanitize_declarations("transform:url(#x)")
      assert_nil SvgCss.sanitize_declarations("stop-color:url(#x)")
      assert_equal "transform:matrix(1,0,0,1,10,-10)", SvgCss.sanitize_declarations("transform:matrix(1 0 0 1 10 -10)")
    end

    def test_handles_empty_and_malformed_input
      assert_nil SvgCss.sanitize_declarations("")
      assert_nil SvgCss.sanitize_declarations(";;")
      assert_nil SvgCss.sanitize_declarations("fill")
      assert_nil SvgCss.sanitize_declarations("fill:")
      assert_nil SvgCss.sanitize_declarations("fill:red,")
      assert_nil SvgCss.sanitize_declarations("fill:rgb(1,)")
      assert_nil SvgCss.sanitize_declarations("stroke-width:2.")
      assert_nil SvgCss.sanitize_declarations("stroke-width:1e3")
    end

    def test_rejects_unlisted_units
      assert_nil SvgCss.sanitize_declarations("stroke-width:5evil")
      assert_equal "font-size:12px", SvgCss.sanitize_declarations("font-size:12px")
    end

    def test_keeps_unquoted_font_stacks
      assert_equal "font-family:DejaVu Sans,sans-serif",
                   SvgCss.sanitize_declarations("font-family:DejaVu Sans, sans-serif")
    end

    def test_keeps_extended_presentation_properties
      {
        "stroke-dasharray:6,3" => "stroke-dasharray:6,3",
        "stroke-dashoffset:0" => "stroke-dashoffset:0",
        "vector-effect:non-scaling-stroke" => "vector-effect:non-scaling-stroke",
        "display:none" => "display:none",
        "visibility:hidden" => "visibility:hidden",
        "color:#333" => "color:#333",
        "marker-end:url( #arrow )" => "marker-end:url(#arrow)",
        "paint-order:stroke fill markers" => "paint-order:stroke fill markers",
        "letter-spacing:1px" => "letter-spacing:1px",
        "font-style:italic" => "font-style:italic"
      }.each do |input, expected|
        assert_equal expected, SvgCss.sanitize_declarations(input), input
      end
    end

    def test_keeps_important_flag
      assert_equal "fill:red!important", SvgCss.sanitize_declarations("fill:red !important")
      assert_equal "fill:red!important", SvgCss.sanitize_declarations("fill: red ! IMPORTANT")
      assert_equal "fill:url(#g)!important", SvgCss.sanitize_declarations("fill:url(#g) !important")
      assert_equal "fill:red!important;stroke:none",
                   SvgCss.sanitize_declarations("fill:red !important; stroke:none")
    end

    def test_important_flag_does_not_open_a_hole
      assert_nil SvgCss.sanitize_declarations("fill:red !importantX")        # not the keyword
      assert_nil SvgCss.sanitize_declarations("fill:red !important !important") # only trailing one stripped
      assert_nil SvgCss.sanitize_declarations("fill:ur\\6c(#x) !important")   # escape still caught
      assert_nil SvgCss.sanitize_declarations("fill:red !important@import")   # at-rule junk
    end

    def test_keeps_modern_color_alpha
      assert_equal "fill:rgb(255 0 0 / 0.5)", SvgCss.sanitize_declarations("fill:rgb(255 0 0 / 0.5)")
      assert_equal "fill:rgb(255 0 0 / 50%)", SvgCss.sanitize_declarations("fill:rgb(255 0 0 / 50%)")
      assert_equal "stop-color:hsl(120 50% 50% / .3)", SvgCss.sanitize_declarations("stop-color:hsl(120 50% 50% / .3)")
      assert_equal "fill:rgb(255,0,0)", SvgCss.sanitize_declarations("fill:rgb(255,0,0)") # legacy form unchanged
    end

    # The slash relaxation must not let comments or non-color slashes survive.
    def test_slash_does_not_open_comment_or_path_holes
      ["fill:red/**/", "fill:red/*x*/blue", "fill:rgb(0 0 0)/* */", "fill:red/*", # comments need *, charset blocks
       "fill:url(/evil)", "fill:url(//evil.example/x)",                            # paths still fragment-only
       "fill:red / blue", "transform:translate(1 / 2)",                            # slash only in color alpha
       "fill:rgb(0 0 0 / )", "fill:rgb(0 0 0 / url(#x))"].each do |css|            # malformed alpha
        assert_nil SvgCss.sanitize_declarations(css), css
      end
    end

    def test_extended_properties_still_reject_external_and_function_misuse
      assert_nil SvgCss.sanitize_declarations("marker-end:url(http://evil.example/x)")
      assert_nil SvgCss.sanitize_declarations("display:url(#x)")        # no function on a keyword property
      assert_nil SvgCss.sanitize_declarations("color:url(#x)")          # color takes no url()
      assert_nil SvgCss.sanitize_declarations("vector-effect:ur\\6c(#x)")
    end

    def test_sanitizes_simple_stylesheets
      assert_equal ".st0{fill:#FF0000;stroke:#000}", SvgCss.sanitize_stylesheet(".st0{fill:#FF0000;stroke:#000;}")
      assert_equal "svg .a,g>.b{opacity:.5}", SvgCss.sanitize_stylesheet("svg .a, g > .b { opacity: .5 }")
      assert_equal "*{fill:red}", SvgCss.sanitize_stylesheet("*{fill:red}")
    end

    def test_drops_rules_with_unsupported_selectors
      assert_equal "rect{fill:red}", SvgCss.sanitize_stylesheet("rect{fill:red}.bad:hover{fill:red}")
      assert_nil SvgCss.sanitize_stylesheet("a[href]{fill:red}")
      assert_nil SvgCss.sanitize_stylesheet(".a + .b{fill:red}")
    end

    def test_stylesheet_fails_closed_on_structure
      assert_nil SvgCss.sanitize_stylesheet("@import url(http://evil.example/x.css); .a{fill:red}")
      assert_nil SvgCss.sanitize_stylesheet("@media screen { .a{fill:red} }")
      assert_nil SvgCss.sanitize_stylesheet("@font-face{src:url(http://evil.example/f.woff)}")
      assert_nil SvgCss.sanitize_stylesheet(".a{fill:red} }")
      assert_nil SvgCss.sanitize_stylesheet(".a{fill:red")
      assert_nil SvgCss.sanitize_stylesheet(".a{}")
    end

    # An at-rule must fail the WHOLE element closed, even when an otherwise-valid
    # rule follows it — the rule-by-rule scan must not keep the trailing rule.
    def test_at_rule_fails_the_whole_stylesheet_not_just_its_own_rule
      assert_nil SvgCss.sanitize_stylesheet("@font-face{font-family:x}.ok{fill:red}")
      assert_nil SvgCss.sanitize_stylesheet("@import url(#x);.bad{x}.ok{fill:red}")
      assert_nil SvgCss.sanitize_stylesheet(".ok{fill:red}@media screen{.a{fill:blue}}")
      assert_nil SvgCss.sanitize_stylesheet(".ok{fill:red}@charset 'utf-8';")
    end

    # Adapted from svg-hush's filter tests (src/lib.rs), translated to this
    # sanitizer's allowlist posture: where svg-hush rewrites, we drop.
    def test_svg_hush_adversarial_vectors
      assert_nil SvgCss.sanitize_declarations("fill:url(data:text/plain;base64,AAA)")
      assert_equal "fill:red", SvgCss.sanitize_declarations("fill: red; background: URL(X); huh")
      assert_equal "font-size:1em", SvgCss.sanitize_declarations("@import 'foo'; FONT-size: 1em;")
      assert_nil SvgCss.sanitize_declarations("@\\69MporT 'foo';")
      assert_nil SvgCss.sanitize_declarations("fill:UR\\4c(#x)")
      assert_equal "fill:url(#x)", SvgCss.sanitize_declarations("fill:URL( #x )")
      assert_nil SvgCss.sanitize_declarations("fill:url (#x)")
      assert_nil SvgCss.sanitize_stylesheet("sel, sel\\2 { bg: url(data:x); ba\\d; }")
    end

    def test_namespace_prefixes_url_fragments_in_declarations
      assert_equal "fill:url(#ns-grad);stroke:#000",
                   SvgCss.sanitize_declarations("fill:url(#grad);stroke:#000", namespace: "ns")
      # idempotent: an already-prefixed fragment is left alone
      assert_equal "fill:url(#ns-grad)", SvgCss.sanitize_declarations("fill:url(#ns-grad)", namespace: "ns")
    end

    def test_namespace_scopes_selectors_and_prefixes_ids_and_classes
      out = SvgCss.sanitize_stylesheet(".box{fill:url(#g)} #ico{stroke:red} *{opacity:.5} rect{fill:#abc}", namespace: "ns")
      # ids AND classes are namespaced; type/universal are confined by the scope
      assert_equal ".ns-scope .ns-box{fill:url(#ns-g)}.ns-scope #ns-ico{stroke:red}.ns-scope *{opacity:.5}.ns-scope rect{fill:#abc}", out
      # every selector is anchored under the scope class, so none can match a host element
      refute_match(/(?<!-scope )(?<!,)\*\{/, out)
    end

    def test_namespace_is_idempotent
      css = ".box{fill:url(#g)} #ico{stroke:red} *{opacity:.5}"
      once = SvgCss.sanitize_stylesheet(css, namespace: "ns")
      assert_equal once, SvgCss.sanitize_stylesheet(once, namespace: "ns")
      decl = SvgCss.sanitize_declarations("fill:url(#g)", namespace: "ns")
      assert_equal decl, SvgCss.sanitize_declarations(decl, namespace: "ns")
    end

    def test_no_namespace_leaves_references_bare
      assert_equal "fill:url(#g)", SvgCss.sanitize_declarations("fill:url(#g)")
      assert_equal ".box{fill:url(#g)}", SvgCss.sanitize_stylesheet(".box{fill:url(#g)}")
    end

    # The deliberate-review rule for this allowlist: a CSS property may appear
    # here only when its presentation-attribute twin is already allowlisted.
    def test_property_allowlist_mirrors_presentation_attributes
      SvgCss::ALLOWED_PROPERTIES.each_key do |property|
        assert_includes SvgSanitizer::ALLOWED_ATTRIBUTES, property,
                        "CSS property #{property} has no allowlisted presentation-attribute twin"
      end
    end
  end
end
