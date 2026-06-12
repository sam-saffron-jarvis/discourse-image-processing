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

    def test_rejects_empty_svg_file
      svg = write_tmp("empty.svg", "")
      assert_raises(InvalidImageError) { SafeImage.size(svg) }
      assert_raises(InvalidImageError) { SafeImage.sanitize_svg!(svg, id_namespace: :standalone) }
    end

    def test_derives_dimensions_from_viewbox
      svg = write_tmp("viewbox.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33.2 44.1"></svg>')
      assert_equal [34, 45], SafeImage.size(svg)
    end

    def test_ignores_namespaced_root_dimensions
      svg = write_tmp("namespaced-dimensions.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:e="urn:e" width="1000" height="1000" e:width="1" e:height="1"></svg>
      SVG

      assert_raises(LimitError) { SafeImage.size(svg, max_pixels: 100) }
    end

    def test_sanitize_ignores_namespaced_root_dimensions
      svg = write_tmp("sanitize-namespaced-dimensions.svg", <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:e="urn:e" width="1000" height="1000" e:width="1" e:height="1"></svg>
      SVG

      assert_raises(LimitError) { SafeImage.sanitize_svg!(svg, id_namespace: :standalone, max_pixels: 100) }
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

    # The SAX cap-scan enforces the element cap by raising out of a parse
    # callback; libxml2 must propagate that at the next event boundary so the
    # parse aborts *early*, not after scanning the whole buffer. A regression
    # here (e.g. a libxml2 that buffers before propagating) would silently turn
    # the gate into a DoS sink, so assert the abort is bounded: a document with
    # 100x the element cap must reject having allocated far less than a full
    # parse of it would. scan_svg! is driven directly so the byte cap that bounds
    # the public entry points does not mask the property under test.
    def test_element_cap_aborts_sax_parse_early
      far_over_cap = SvgMetadata::MAX_SVG_ELEMENTS * 100
      xml = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">) +
            ("<g/>" * far_over_cap) + "</svg>"

      GC.start
      before = GC.stat(:total_allocated_objects)
      assert_raises(LimitError) { SvgMetadata.scan_svg!(xml) }
      allocated = GC.stat(:total_allocated_objects) - before

      # A full SAX walk of far_over_cap elements would allocate on the order of
      # the element count; aborting at the 10k cap must stay far below that.
      assert_operator allocated, :<, far_over_cap,
                      "rejecting a #{far_over_cap}-element bomb allocated #{allocated} objects; the SAX parse did not abort early at the cap"
    end

    def test_rejects_svg_content_without_svg_extension
      txt = write_tmp("not-svg.txt", '<svg width="1" height="1"></svg>')
      assert_raises(UnsupportedFormatError) { SafeImage.size(txt) }
    end

    # The DOCTYPE/PI guards are ASCII byte regexes. A UTF-16 document interleaves
    # NUL bytes between ASCII characters, so "<!DOCTYPE" never matches the regex,
    # yet REXML decodes the BOM and honours the DOCTYPE. Reject non-UTF-8 input
    # before the byte scans so the bytes we inspect are the bytes REXML parses.
    def test_rejects_utf16_doctype_smuggling
      [Encoding::UTF_16LE, Encoding::UTF_16BE].each do |encoding|
        src = <<~SVG
          <?xml version="1.0"?>
          <!DOCTYPE svg [ <!ENTITY xss "<script>alert(1)</script>"> ]>
          <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&xss;</svg>
        SVG
        bom = "﻿".encode(encoding)
        path = tmp_path("smuggle-#{encoding.name.downcase}.svg")
        File.binwrite(path, (bom + src.encode(encoding)).b)
        assert_raises(InvalidImageError, "UTF-16 (#{encoding}) DOCTYPE bypassed the guard") do
          SafeImage.size(path)
        end
      end
    end

    def test_rejects_embedded_nul_bytes
      path = tmp_path("nul.svg")
      File.binwrite(path, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\0\" height=\"1\"></svg>")
      assert_raises(InvalidImageError) { SafeImage.size(path) }
    end

    # Multi-byte (a lead byte can swallow a following quote) and transforming
    # (UTF-7's "+ADw-" decodes to "<") encodings let bytes our ASCII scans
    # cannot see become markup the browser acts on, so reject them by name.
    def test_rejects_multibyte_and_transforming_encodings
      %w[Shift_JIS GBK EUC-JP UTF-7 ISO-2022-JP].each do |encoding|
        svg = write_tmp("mb-#{encoding}.svg", <<~SVG)
          <?xml version="1.0" encoding="#{encoding}"?>
          <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>
        SVG
        assert_raises(InvalidImageError, "accepted unsafe encoding #{encoding}") { SafeImage.size(svg) }
      end
    end

    # Single-byte, ASCII-transparent charsets are safe: every markup byte is
    # below 0x80 and decodes identically to ASCII, so the byte-level guards stay
    # correct while REXML decodes the high bytes (here e-acute, 0xE9) as latin1.
    def test_accepts_single_byte_legacy_encoding
      svg = <<~SVG.encode(Encoding::ISO_8859_1)
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><title>café</title></svg>
      SVG
      path = tmp_path("latin1.svg")
      File.binwrite(path, svg.b)
      assert_equal [12, 8], SafeImage.size(path)
    end

    # A UTF-8 byte-order mark is still UTF-8: the ASCII scans see through it, so
    # it must keep working rather than be swept up by the non-UTF-8 rejection.
    def test_accepts_utf8_bom
      path = tmp_path("utf8-bom.svg")
      File.binwrite(path, "\xEF\xBB\xBF<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"8\"></svg>")
      assert_equal [12, 8], SafeImage.size(path)
    end

    # The encoding allowlist matches name shapes, which also fit names no
    # decoder knows ("utf8", "windows-1259"). Those must fail closed as
    # InvalidImageError rather than leak REXML's bare ArgumentError.
    def test_rejects_lookalike_encoding_names_as_invalid_image
      %w[utf8 windows-1259 ISO-8859-42 cp-1252 windows1252 iso-88591].each do |encoding|
        svg = write_tmp("lookalike-#{encoding}.svg", <<~SVG)
          <?xml version="1.0" encoding="#{encoding}"?>
          <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>
        SVG
        assert_raises(InvalidImageError, "lookalike encoding #{encoding} should fail closed") { SafeImage.size(svg) }
      end
    end

    # Alternate spellings that Ruby does resolve (cp1252, iso8859-1) stay accepted.
    def test_accepts_resolvable_encoding_aliases
      %w[cp1252 iso8859-1].each do |encoding|
        svg = write_tmp("alias-#{encoding}.svg", <<~SVG)
          <?xml version="1.0" encoding="#{encoding}"?>
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"></svg>
        SVG
        assert_equal [12, 8], SafeImage.size(svg)
      end
    end

    # Defense in depth: if a declared encoding ever reaches REXML without
    # passing the gate, the bare ArgumentError from its Encoding.find lookup
    # must still surface as InvalidImageError.
    def test_scan_maps_rexml_encoding_errors_to_invalid_image
      xml = "<?xml version=\"1.0\" encoding=\"bogus-name\"?><svg></svg>"
      assert_raises(InvalidImageError) { SvgMetadata.scan_svg!(xml) }
    end
  end
end
