# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # Property-based fuzzing for the CSS sanitizer, in the spirit of svg-hush's
  # fuzz/ targets (filter = never crash, idempotent = fixed point, url = every
  # surviving url() is inert). We cannot run libFuzzer against Ruby, so instead
  # we generate inputs from two streams — well-formed CSS with poison spliced
  # in, and pure attack garbage — and assert output-safety *invariants* that
  # must hold for ALL inputs, across several fixed seeds so the run is
  # deterministic in CI.
  class SvgCssFuzzTest < TestCase
    SEEDS = [1, 42, 1337, 2024].freeze
    ITERATIONS = 1500

    # Garbage stream: attack syntax concatenated without separators. Almost
    # everything here is (correctly) rejected; this stresses the reject path
    # and the never-crash property.
    POISON = [
      ":", ";", ",", "(", ")", "{", "}", ">", "*", "/", "//", "/*", "*/",
      "\\", "\\6c", "\\4c ", "\\0075 ", "'", '"', "@", "@import", "@media", "@font-face",
      "javascript:", "data:", "http://", "expression", "url(", "URL(", "image-set(",
      "var(", "--x", "behavior", "src", "//evil.example", "http://evil.example/x",
      "!", "!important", " / ", "/ .5", "/*", "*/", # priority + color-alpha + comment surface
      "‮", "ｕ", "ﬁ", " " # non-ASCII smuggling (RTL override, fullwidth u, fi ligature, NBSP)
    ].freeze

    # Structured stream: well-formed declarations from a benign vocabulary,
    # with a poison token spliced in sometimes. This is what actually exercises
    # the construction path and the idempotence (fixed-point) assertion, since
    # those only run on surviving (non-nil) output.
    PROPERTIES = (SvgCss::ALLOWED_PROPERTIES.keys + %w[cursor background unknown-prop]).freeze
    VALUE_TOKENS = %w[
      red none evenodd #grad #abc #ff0000 1 1.5 .5 0 12px 45deg 100%
      rgb(255,0,0) matrix(1,0,0,1,2,3) translate(3,4) rotate(45deg) url(#g)
      DejaVu sans-serif bold !important
    ].freeze
    # Kept separate: contains spaces, so it can't live in a %w[] list.
    COLOR_ALPHA_TOKEN = "rgb(0 0 0 / 0.5)"
    SEPARATORS = [" ", ", ", ",", "  "].freeze

    SAFE_OUTPUT = /\A[\x20-\x7e]*\z/.freeze

    # Minimum fraction of structured inputs that must survive sanitisation. If a
    # change drives this toward 0 (as an over-poisoned generator first did), the
    # idempotence assertion silently stops being exercised — so guard it.
    MIN_SURVIVAL_RATE = 0.20

    def test_declaration_sanitizer_holds_invariants
      assert_survival_rate do |rng|
        input = generate_declarations(rng)
        out = SvgCss.sanitize_declarations(input)
        assert_css_safe(out, input, :sanitize_declarations)
        garbage = generate_garbage(rng)
        assert_css_safe(SvgCss.sanitize_declarations(garbage), garbage, :sanitize_declarations)
        out
      end
    end

    def test_stylesheet_sanitizer_holds_invariants
      assert_survival_rate do |rng|
        rule = "#{generate_selectors(rng)}{#{generate_declarations(rng)}}"
        out = SvgCss.sanitize_stylesheet(rule)
        assert_css_safe(out, rule, :sanitize_stylesheet)
        garbage = generate_garbage(rng)
        assert_css_safe(SvgCss.sanitize_stylesheet(garbage), garbage, :sanitize_stylesheet)
        out
      end
    end

    # Under a namespace, every surviving rule must be scoped under the root's
    # `.ns-scope` class (so no selector can match a host element when inlined),
    # url() must point at a namespaced fragment, and the result must be a fixed
    # point. Holds for adversarial input, not just well-formed CSS.
    def test_namespaced_stylesheet_is_scoped_and_idempotent
      ns = "ns"
      SEEDS.each do |seed|
        rng = Random.new(seed)
        ITERATIONS.times do
          rule = "#{generate_selectors(rng)}{#{generate_declarations(rng)}}"
          out = SvgCss.sanitize_stylesheet(rule, namespace: ns)
          next if out.nil?

          context = "sanitize_stylesheet(#{rule.inspect}, namespace: #{ns}) => #{out.inspect}"
          out.scan(/([^{}]+)\{/).each do |selectors,|
            selectors.split(",").each do |selector|
              assert_match(/\A\.#{ns}-scope[ >]/, selector.strip, "selector escaped the scope: #{context}")
            end
          end
          out.scan(/url\(#([^)]*)\)/).each do |fragment,|
            assert_match(/\A#{ns}-/, fragment, "url() fragment not namespaced: #{context}")
          end
          assert_equal out, SvgCss.sanitize_stylesheet(out, namespace: ns), "not idempotent: #{context}"
        end
      end
    end

    # svg-hush's url.rs target: arbitrary bytes wrapped in <style><![CDATA[...]]>,
    # filtered, then every url( in the output must be inert. Here we run it
    # through the real sanitize_svg! entry point and assert the file-level
    # invariants (no escapes, no external host, every url() a fragment).
    def test_arbitrary_css_in_style_element_is_neutralised
      SEEDS.each do |seed|
        rng = Random.new(seed)
        100.times do
          css = rng.rand < 0.5 ? generate_declarations(rng) : generate_garbage(rng)
          svg = <<~SVG
            <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
              <style><![CDATA[#{css}]]></style>
              <rect width="10" height="10" style="#{css}"/>
            </svg>
          SVG
          path = write_tmp("fuzz-#{seed}.svg", svg)
          begin
            SafeImage.sanitize_svg!(path, id_namespace: :standalone)
          rescue InvalidImageError, LimitError
            next # rejecting the whole document is always a safe outcome
          end
          assert_file_invariants(File.read(path), css)
        end
      end
    end

    # Adversarial url() forms in presentation attributes, run through the real
    # namespaced sanitize_svg!. The invariant: no url() reference survives unless
    # it is the namespaced fragment form. Catches the quoted/uppercase/malformed
    # bypasses where dangerous_value? and the rewrite could disagree.
    URL_FUZZ = [
      "url(", "URL(", "Url(", "url (", "#g", "#u1-g", "u1-g", "'", '"', ")", " ",
      "http://evil.example/x", "//evil.example", "#", "data:x", "javascript:x", "fill"
    ].freeze

    def test_namespaced_presentation_attribute_urls_never_leave_bare_refs
      SEEDS.each do |seed|
        rng = Random.new(seed)
        40.times do
          rects = Array.new(25) do
            value = Array.new(rng.rand(1..6)) { URL_FUZZ[rng.rand(URL_FUZZ.length)] }.join
            attr = %w[fill stroke clip-path marker-end mask][rng.rand(5)]
            %(<rect #{attr}="#{xml_escape(value)}"/>)
          end
          svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">) +
                %(<defs><linearGradient id="g"/></defs>#{rects.join}</svg>)
          path = write_tmp("urlfuzz-#{seed}.svg", svg)
          SafeImage.sanitize_svg!(path, id_namespace: "u1")
          out = File.read(path)

          # The guarantee is about url() references (the only fetching/binding
          # form); a bare external string in a paint attribute is an inert,
          # ignored value. So: every surviving url( must be a namespaced fragment.
          refute_match(/url\s*\(\s*['"]?#(?!u1-)/i, out, "bare/unnamespaced fragment survived: #{svg}")
          refute_match(/url\s*\(\s*['"]?[^#'")\s]/i, out, "non-fragment url( survived: #{svg}")
          refute_match(/url\s*\([^)]*evil/i, out, "external host inside url() survived: #{svg}")
        end
      end
    end

    def xml_escape(value)
      value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    private

    # Runs the block over every seed/iteration, treating its return value as the
    # sanitiser output, and asserts a healthy fraction survived so the kept-path
    # invariants stay exercised.
    def assert_survival_rate
      kept = total = 0
      SEEDS.each do |seed|
        rng = Random.new(seed)
        ITERATIONS.times do
          total += 1
          kept += 1 if yield(rng)
        end
      end
      assert_operator kept.to_f / total, :>=, MIN_SURVIVAL_RATE,
                      "generator no longer exercises the kept path (#{kept}/#{total} survived)"
    end

    # 1-4 declarations of "prop: value [sep value]*", with a poison token
    # spliced in ~30% of the time.
    def generate_declarations(rng)
      Array.new(rng.rand(1..4)) do
        property = PROPERTIES[rng.rand(PROPERTIES.length)]
        values = Array.new(rng.rand(1..3)) { VALUE_TOKENS[rng.rand(VALUE_TOKENS.length)] }
        values << COLOR_ALPHA_TOKEN if rng.rand < 0.15
        values << POISON[rng.rand(POISON.length)] if rng.rand < 0.3
        "#{property}:#{values.join(SEPARATORS[rng.rand(SEPARATORS.length)])}"
      end.join(";")
    end

    def generate_selectors(rng)
      Array.new(rng.rand(1..3)) do
        compound = %w[rect g .st0 .a #id text *][rng.rand(7)]
        rng.rand < 0.2 ? "#{compound} > .#{rng.rand(99)}" : compound
      end.join(rng.rand < 0.3 ? " " : ", ")
    end

    def generate_garbage(rng)
      Array.new(rng.rand(1..14)) { POISON[rng.rand(POISON.length)] }.join
    end

    # The structural safety guarantees of the constructed output: nothing the
    # grammar cannot emit may appear, regardless of input. A nil result (drop)
    # is always acceptable.
    def assert_css_safe(out, input, method)
      return if out.nil?

      context = "#{method}(#{input.inspect}) => #{out.inspect}"
      assert_match SAFE_OUTPUT, out, "non-ASCII/control byte in output: #{context}"
      refute_includes out, "\\", "CSS escape survived: #{context}"
      refute_includes out, "'", "single quote survived: #{context}"
      refute_includes out, '"', "double quote survived: #{context}"
      refute_includes out, "@", "at-rule survived: #{context}"
      # "/" is permitted only as modern color alpha (rgb(R G B / A)); the danger
      # it gates is comments, which need "/*"/"*/" — assert those never form.
      refute_match(%r{/\*|\*/}, out, "comment delimiter survived: #{context}")
      refute_match(/url\((?!#)/i, out, "non-fragment url() survived: #{context}")

      # Fixed point: re-sanitising constructed output must not change it.
      assert_equal out, SvgCss.public_send(method, out), "not idempotent: #{context}"
    end

    def assert_file_invariants(cleaned, css)
      refute_includes cleaned, "\\", "CSS escape reached file output for #{css.inspect}"
      refute_includes cleaned, "evil.example", "external host reached file output for #{css.inspect}"
      refute_match(/@import/i, cleaned, "@import reached file output for #{css.inspect}")
      # Any url() in a style attribute/element must be a fragment.
      cleaned.scan(/style='([^']*)'/i).flatten.each do |style|
        refute_match(/url\((?!#)/i, style, "non-fragment url() in style for #{css.inspect}")
      end
    end
  end
end
