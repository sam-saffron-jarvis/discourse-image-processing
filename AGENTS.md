# AGENTS.md

Guidance for AI coding agents working in this repository. CLAUDE.md is a symlink to this file.

## Commands

- `bundle exec rake` — run all tests. Nothing compiles: the libvips binding (`lib/safe_image/vips_glue.rb`) is pure Ruby via Fiddle and dlopens `libvips.so.42` when `SafeImage.configure!(backend: :vips)` runs.
- Single file: `bundle exec rake test TEST=test/svg_sanitizer_test.rb`
- Single test: add `TESTOPTS="--name=/pattern/"`
- Lint: `bundle exec rubocop` (inherits rubocop-discourse; CI runs this)
- `docker/run.sh` — runs the suite in a Debian bookworm container against the oldest supported packaged libvips (8.14) with no toolchain, validating the no-compile install.
- Tests shell out to real tools: the libvips runtime library, `magick`, `jpegoptim`, `pngquant`, `oxipng` are required; `cjpegli`, HEIC delegates, and Landlock are optional — tests for them skip when missing.

## Workflow rules

- **Never commit.** The user makes all commits themselves; leave changes in the working tree.
- **Never change `SafeImage::VERSION`.** A version bump on main auto-publishes the gem to RubyGems via CI.

## Testing conventions

- Minitest. Tests inherit from `SafeImage::TestCase`; helpers (fixture paths, `tmp_path`, `assert_result`) live in `test/test_helper.rb`. Setup configures `backend: :vips, landlock: false` by default; tests exercising other combinations call `configure_safe_image(...)` themselves (`configure!` is re-callable, last call wins).
- Exercise real code paths against the real fixtures in `test/fixtures/images/` — no mocks. Stubs are an absolute last resort (`test/support/stub_image_server.rb` exists only because remote-fetch tests need a local HTTP endpoint).
- When an optional tool is unavailable, skip (see `heic_or_skip`) — never let its absence fail the suite.

## Security invariants — do not weaken

This gem is a security boundary for untrusted images:

- External commands are argv arrays only; never build shell strings.
- `SafeImage.configure!(backend:, landlock:)` is mandatory before any operation; operations without it raise `NotConfiguredError`. Keep that enforcement — it is what makes the backend and sandbox posture a deliberate, single-place decision.
- The libvips binding blocks vips' ImageMagick loaders and untrusted operations, and exposes only the operations `SafeImage::Native` invokes. There is no fallback from vips to ImageMagick — the backend is the one-time `configure!` decision, and formats the configured backend cannot decode fail closed.
- The default pixel cap (128MP) is enforced before any full decode in the libvips fast path (`SafeImage::Native`) and via the area limit on the ImageMagick path; keep the two in sync.
- The SVG sanitizer is allowlist-based (REXML): rejects DOCTYPE/PIs and caps depth/element/attribute counts. CSS in `style` attributes/elements is reduced to the constructed subset in `SafeImage::SvgCss` — output is reassembled from validated tokens, never echoed from input, and escapes/quotes/at-rules/comments are rejected rather than parsed. Extend the allowlists (elements, attributes, CSS properties/functions/units) only with deliberate review.
- `sanitize_svg!` requires `id_namespace:` — a deliberate choice with no silently-wrong default. `:standalone` gives document-safe output (only for `<img>`/CSS-url/file use); a stable per-document String makes it safe to inline into HTML. Keep it required, and keep the namespace prefixing idempotent (skip-if-already-prefixed) — callers re-sanitize.
- **Inline-safety invariant**: a namespaced SVG must reference *nothing outside its own namespaced content*. That means every attacker-controllable reference into the host is neutralized — ids and all id references (`href`/`xlink:href`, `url(#…)` in attributes and CSS, ARIA IDREFs, `#id` selectors), `class` tokens and `.class` selectors (host-cascade binding), host-reaching CSS functions (`var()`/`env()`/`attr()`), the `<style>` cascade (scoped under the root `<ns>-scope` class), and root `overflow` (clipped). If you widen `ALLOWED_ELEMENTS`/`ALLOWED_ATTRIBUTES` or the CSS grammar, re-audit `SvgSanitizer.namespace_references!` and `SvgCss` for any new reference-bearing attribute/selector/function and namespace or reject it.
- ImageMagick runs only under the bundled restrictive `policy.xml`; remote fetching is SSRF-hardened (DNS pinning, special-use IP blocking, redirect limits).
- Untrusted local paths must pass `PathSafety` symlink checks.
