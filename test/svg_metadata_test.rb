# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # SVG metadata is parsed with a restrictive XML reader, never handed to an
  # image decoder, so malformed or hostile documents must be rejected early.
  class SvgMetadataTest < TestCase
    def test_reports_type_size_and_info
      svg = write_tmp("icon.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
          <rect width="120" height="80" fill="#fff"/>
        </svg>
      SVG

      assert_equal :svg, SafeImage.type(svg)
      assert_equal [120, 80], SafeImage.size(svg)

      info = SafeImage.info(svg, animated: true, orientation: true)
      assert_equal :svg, info.type
      assert_equal false, info.animated
      assert_equal 1, info.orientation
    end

    def test_derives_dimensions_from_viewbox
      svg = write_tmp("viewbox.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33.2 44.1"></svg>')
      assert_equal [34, 45], SafeImage.size(svg)
    end

    def test_accepts_pixel_units
      svg = write_tmp("px.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="10px" height="20px"></svg>')
      assert_equal [10, 20], SafeImage.size(svg)
    end

    def test_rejects_percentage_dimensions
      svg = write_tmp("percent.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"></svg>')
      assert_raises(InvalidImageError) { SafeImage.size(svg) }
    end

    def test_rejects_huge_dimensions
      svg = write_tmp("huge.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"></svg>')
      assert_raises(LimitError) { SafeImage.size(svg) }
    end

    def test_rejects_oversized_documents
      svg = write_tmp("oversized.svg", "<svg width=\"1\" height=\"1\">#{" " * (SvgMetadata::MAX_SVG_BYTES + 1)}</svg>")
      assert_raises(LimitError) { SafeImage.size(svg) }
    end

    def test_rejects_doctype_with_external_entities
      svg = write_tmp("doctype.svg", <<~SVG)
        <!DOCTYPE svg [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&xxe;</svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.size(svg) }
    end

    def test_rejects_xml_stylesheet_processing_instruction
      svg = write_tmp("stylesheet.svg", <<~SVG)
        <?xml version="1.0"?>
        <?xml-stylesheet href="http://evil.example/x.css"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>
      SVG
      assert_raises(InvalidImageError) { SafeImage.size(svg) }
    end

    def test_rejects_deeply_nested_documents
      svg = write_tmp("deep.svg", "<svg width=\"1\" height=\"1\">#{"<g>" * 70}#{"</g>" * 70}</svg>")
      assert_raises(LimitError) { SafeImage.size(svg) }
    end

    # A document that stays under the byte cap but packs hundreds of thousands of
    # tiny elements must be rejected by the element cap while streaming, not after
    # a full DOM has been built. Parsing-then-validating allocated ~6.8M objects
    # for a 1 MiB input; the streaming scan aborts at the 10k-element cap.
    def test_rejects_element_bomb_without_building_full_dom
      head = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">)
      count = (SvgMetadata::MAX_SVG_BYTES - head.bytesize - "</svg>".bytesize) / "<g/>".bytesize
      bomb = write_tmp("bomb.svg", "#{head}#{"<g/>" * count}</svg>")

      GC.start
      before = GC.stat(:total_allocated_objects)
      assert_raises(LimitError) { SafeImage.size(bomb) }
      allocated = GC.stat(:total_allocated_objects) - before

      assert_operator allocated, :<, 1_000_000,
                      "rejecting the element bomb allocated #{allocated} objects; the scan should abort before building the DOM"
    end

    def test_rejects_svg_content_without_svg_extension
      txt = write_tmp("not-svg.txt", '<svg width="1" height="1"></svg>')
      assert_raises(UnsupportedFormatError) { SafeImage.size(txt) }
    end
  end
end
