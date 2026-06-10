# AGENTS.md

Guidance for AI coding agents working in this repository. CLAUDE.md is a symlink to this file.

## Commands

- `bundle exec rake` — run all tests. Nothing compiles: the libvips binding (`lib/safe_image/vips_glue.rb`) is pure Ruby via Fiddle and dlopens `libvips.so.42` at first use.
- Single file: `bundle exec rake test TEST=test/svg_sanitizer_test.rb`
- Single test: add `TESTOPTS="--name=/pattern/"`
- Lint: `bundle exec rubocop` (inherits rubocop-discourse; CI runs this)
- `docker/run.sh` — runs the suite in a Debian bookworm container against the oldest supported packaged libvips (8.14) with no toolchain, validating the no-compile install.
- Tests shell out to real tools: the libvips runtime library, `magick`, `jpegoptim`, `pngquant`, `oxipng` are required; `cjpegli`, HEIC delegates, and Landlock are optional — tests for them skip when missing.

## Workflow rules

- **Never commit.** The user makes all commits themselves; leave changes in the working tree.
- **Never change `SafeImage::VERSION`.** A version bump on main auto-publishes the gem to RubyGems via CI.

## Testing conventions

- Minitest. Tests inherit from `SafeImage::TestCase`; helpers (fixture paths, `tmp_path`, `assert_result`) live in `test/test_helper.rb`.
- Exercise real code paths against the real fixtures in `test/fixtures/images/` — no mocks. Stubs are an absolute last resort (`test/support/stub_image_server.rb` exists only because remote-fetch tests need a local HTTP endpoint).
- When an optional tool is unavailable, skip (see `heic_or_skip`) — never let its absence fail the suite.

## Security invariants — do not weaken

This gem is a security boundary for untrusted images:

- External commands are argv arrays only; never build shell strings.
- The libvips binding blocks vips' ImageMagick loaders and untrusted operations, and exposes only the operations `SafeImage::Native` invokes. There is no silent fallback from vips to ImageMagick — backend selection is explicit.
- The default pixel cap (128MP) is enforced before any full decode in the libvips fast path (`SafeImage::Native`) and via the area limit on the ImageMagick path; keep the two in sync.
- The SVG sanitizer is allowlist-based (REXML): rejects DOCTYPE/PIs and caps depth/element/attribute counts. Extend the allowlist only with deliberate review.
- ImageMagick runs only under the bundled restrictive `policy.xml`; remote fetching is SSRF-hardened (DNS pinning, special-use IP blocking, redirect limits).
- Untrusted local paths must pass `PathSafety` symlink checks.
