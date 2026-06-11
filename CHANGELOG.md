# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

- **`sanitize_svg!` now requires `id_namespace:`.** The argument forces a
  deliberate choice of where the output may be used, removing the footgun of a
  silently-wrong default. Pass `:standalone` for output served only as an
  external `<img>`/CSS-url/file, or a stable per-document String to make it safe
  to inline (see below). Omitting it (or passing `nil`/`""`) raises
  `ArgumentError`. Callers must update: `sanitize_svg!(path)` →
  `sanitize_svg!(path, id_namespace: :standalone)`.

### Added

- **`sanitize_svg!` can produce output safe to inline into an HTML DOM.** Pass
  `id_namespace:` a stable per-document value (e.g. the upload sha) and the
  sanitizer prefixes every `id` and every reference to it (`href`/`xlink:href`
  fragments, `url(#…)` in attributes and CSS, ARIA IDREF attributes like
  `aria-labelledby`/`aria-controls`, and every `class` token plus the matching
  `.class` selectors) with the namespace, and scopes every `<style>` selector
  under a `<ns>-scope` class added to the root `<svg>`. Namespacing classes stops
  an inlined SVG from invoking the host page's framework CSS (a bare
  `class="modal fixed"` overlay vector). `var()`/`env()`/`attr()` in presentation
  attributes are rejected outright — they resolve against the host page.
  Inlined into a page, the preserved `<style>` can no longer reach the host
  cascade (`*{visibility:hidden}`, `#header{display:none}`) and ids cannot
  clobber host ids — including references written `URL(#x)`, `url('#x')`, or
  `url("#x")`, which are namespaced like the unquoted form. In this mode the root
  `<svg>`'s `overflow` is also dropped so it clips to its declared viewport (a
  tiny viewport with `overflow:visible` and oversized content would otherwise
  paint a full-page overlay). With `id_namespace: :standalone` the output is the
  document-safe form (no namespacing). The namespace must be a valid ident (a
  letter followed by letters/digits/`_`/`-`); malformed tokens are rejected
  rather than coerced, so two distinct values can never collapse to one. The
  transform is idempotent per namespace. `style=""` attributes are
  element-scoped and inline-safe either way.
- **`<style>` elements now fail closed on any at-rule.** Previously an at-rule
  block followed by a valid rule (`@font-face{…}.ok{…}`) could keep the trailing
  rule; a stylesheet containing `@` anywhere is now rejected whole, matching the
  documented guarantee.
- **The SVG sanitizer keeps a safe CSS subset instead of stripping all CSS.**
  `style` attributes (as written by Inkscape) and `<style>` elements (as
  written by Illustrator) now survive sanitisation when they parse against a
  constructed allowlist grammar: properties mirroring the allowed
  presentation attributes, type/class/id selectors, numeric/keyword/color
  values, and `url(#fragment)` references only. Output is reassembled from
  validated tokens — CSS escapes, quotes/strings, at-rules, comments, and
  unknown properties, functions, or selectors drop the declaration, rule, or
  whole stylesheet rather than being interpreted. A single at-rule or nested
  block fails the whole `<style>` element closed. `!important` and modern
  `rgb()/hsl()` slash-alpha (`rgb(R G B / A)`) are preserved; both are parsed
  structurally and re-emitted, and admitting `/` for the alpha keeps CSS
  comments impossible because `*` remains excluded from the value charset.
- **The presentation-attribute allowlist covers common editor output.** Added
  the safe, widely-emitted SVG presentation properties (and their CSS twins):
  `stroke-dasharray`/`stroke-dashoffset`, `vector-effect`, `marker`/`marker-*`
  (with the `<marker>` element and its geometry attributes), `color`,
  `display`/`visibility`/`overflow`, `paint-order`/`mix-blend-mode`/`isolation`,
  the `*-rendering` hints, and the longhand text properties (`font-style`,
  `font-variant`, `font-stretch`, `text-decoration`, `letter-spacing`,
  `word-spacing`, `dominant-baseline`, `baseline-shift`, `writing-mode`,
  `direction`). The only additions carrying a URL — `marker*` — are constrained
  to `url(#fragment)` like the existing paint and clip/mask references. Filters
  remain out of scope.

### Changed

- **Remote fetches reject bad responses from the headers alone.** The
  `Content-Type` allowlist and content-type/extension agreement checks now run
  before any body bytes are read (previously the body was downloaded first and
  rejected afterwards), and the first bytes of the body must be compatible
  with the claimed format's magic bytes — an obviously mislabeled body is
  dropped after the first chunk instead of being downloaded to `max_bytes`.
- **Remote metadata helpers download only what the answer needs.**
  `remote_size`, `remote_type`, `remote_info` and `remote_animated?` now probe
  the partially-downloaded file at growing thresholds (64KB, 256KB, ...) and
  abort the transfer once the answer is final, instead of always downloading
  up to `max_bytes`. Early answers are only trusted when more data cannot
  change them: "not animated" still requires the complete file (truncated
  animations undercount frames), SVG metadata still downloads the whole
  document so the SVG size cap keeps its meaning, and any prefix probe
  failure falls back to the full download with unchanged validation and
  error behaviour. `fetch_remote` and `remote_dominant_color` still download
  the complete body.

### Security

- **Presentation-attribute `url()` references fail closed unless they are a
  canonical same-document fragment.** A single validation/rewrite grammar now
  governs both the keep decision and the namespace rewrite, so external URLs,
  mismatched quotes, and unterminated forms (`url(#id`, `url(http://evil`) are
  dropped rather than kept on browser parse-error leniency — and no bare,
  un-namespaced reference can survive in inline (`id_namespace:` String) output.
- **Attribute values containing CSS escapes are rejected outright.**
  Browsers feed SVG presentation attributes through their CSS value parsers,
  where an escape can re-form a token after the sanitizer's pattern checks
  (`ur\6c(...)` is `url(...)`). No allowlisted attribute legitimately
  contains a backslash, so any attribute value with one is now dropped.
- **SVG parsing rejects encodings the byte-level guards cannot see through.**
  The DOCTYPE/processing-instruction guards are ASCII byte scans; a UTF-16
  document interleaves NUL bytes between the ASCII characters, so a
  `<!DOCTYPE` (and an entity payload behind it) could slip past them while
  REXML still decoded and honoured it. SVG documents must now be UTF-8 (BOM
  allowed) or declare a single-byte ASCII-transparent charset (US-ASCII,
  ISO-8859-*, Windows-125x): UTF-16/32 BOMs, embedded NUL bytes, and declared
  multi-byte or transforming encodings (Shift_JIS, GBK, EUC-*, ISO-2022-*,
  UTF-7) raise `InvalidImageError`. Declared names that fit the allowed shape
  but resolve to no real encoding (e.g. `utf8`, `windows-1259`) also fail
  closed as `InvalidImageError` instead of surfacing REXML's bare
  `ArgumentError`.

## [0.2.0] - 2026-06-10

The host's whole image-processing posture is now decided in one place, once,
at boot. There is no per-call backend fidelity and no automatic routing
between backends.

### Added

- **`SafeImage.configure!(backend:, landlock:, max_pixels:)` is mandatory**:
  every operation before it raises the new `SafeImage::NotConfiguredError`.
  `backend:` (`:vips` or `:imagemagick`) picks the decoder for all untrusted
  bytes; `landlock:` decides sandboxing; `max_pixels:` sets the default
  decompression-bomb ceiling (128MP, still overridable per call). Validation
  is eager — a missing libvips, ImageMagick binary, or Landlock support fails
  at boot, not on the first request. Calling `configure!` again replaces the
  configuration atomically, so initializer reloads are safe.
- `SafeImage.config` (frozen current configuration) and
  `SafeImage.configured?`.

### Changed

- **Backend selection is strict.** `:auto` is gone; nothing ever falls back
  from libvips to ImageMagick. A format the configured backend cannot decode
  (e.g. ICO transform input on `:vips`, HEIC on a libvips build without
  libheif) raises `UnsupportedFormatError`. Pure-Ruby format handling (SVG
  metadata/sanitising, ICO metadata) still works on either backend.
- **cjpegli is availability-driven**, like the optimizer tools: installed
  means used for JPEG output on the `:vips` backend, absent means libvips
  encodes. It is no longer a per-call or configuration choice.
- Sandbox worker processes inherit the parent's backend and pixel-ceiling
  configuration through the request payload (landlock is forced off inside
  the worker, so sandboxed operations never nest).
- `dominant_color` on the `:imagemagick` backend now decodes ICO through
  ImageMagick; the pure-Ruby ICO decoder serves the `:vips` backend.

### Removed

- Per-call `backend:` keyword on `resize`, `crop`, `downsize`, `convert`,
  `thumbnail`, `letter_avatar`, `fix_orientation` and `dominant_color`.
- Per-call `encoder:` keyword on `convert`, `convert_to_jpeg`, `thumbnail`,
  `resize`, `crop` and `downsize`.
- `execution:` keyword on `thumbnail` (`:sandbox` / `:sandbox_if_available`)
  — sandboxing is decided by `configure!(landlock:)`.
- `SafeImage.enable_sandbox!`, `SafeImage.disable_sandbox!`,
  `SafeImage.sandbox_enabled?` and `SafeImage.sandbox_call` —
  `SafeImage.sandbox_available?` remains as the pre-configuration probe.

## [0.1.1] - 2026-06-10

### Added

- `SafeImage.dominant_color` and `SafeImage.remote_dominant_color`: alpha-weighted
  average colour as an `RRGGBB` hex string, computed natively through libvips,
  with an ImageMagick histogram backend (`backend: :imagemagick`) matching the
  command Discourse runs.
- Pure-Ruby ICO support: directory parsing for `probe`/`frame_count`,
  largest-entry favicon extraction for `convert_favicon_to_png` (embedded PNG
  payloads are sanitised by re-encoding; legacy DIB payloads decode 1/4/8/24/32bpp
  with the AND mask), and decompression-bomb caps enforced from the container
  and IHDR headers before any decode.
- Native GIF decode through libvips' bundled libnsgif loader (first frame,
  matching the ImageMagick `[0]` semantics) and GIF output through cgif.
- JPEG XL support end to end: native libvips loader/saver, ImageMagick coder
  and policy allowlisting, remote content-type/extension handling, and a
  committed test fixture.
- Native letter avatars rendered through libvips' Pango text support with the
  glyph blended in one linear transform; the gem now bundles DejaVu Sans (see
  `lib/safe_image/fonts/DEJAVU-LICENSE`) so the default font renders
  identically on every host with no font packages installed.
- Header-only native metadata reads: `frame_count`/`animated?` from the
  n-pages field and `orientation` from the orientation field — no pixel decode
  and no `identify` subprocess for natively supported formats.
- `fix_orientation` lossless tier: MCU-aligned JPEGs are transformed with
  `jpegtran` (zero generation loss) when installed, falling back to a libvips
  re-encode with a new `quality:` keyword (default 95).
- Native `convert` tier: decode through the allowlisted loaders,
  auto-orient, flatten transparency onto white for JPEG targets (matching the
  ImageMagick path), re-encode; default JPEG quality 92 when unspecified.
- `backend:` keyword (`:auto` / `:vips` / `:imagemagick`) across
  `resize`, `crop`, `downsize`, `convert`, `thumbnail`, `letter_avatar`,
  `fix_orientation` and `dominant_color`. `:auto` prefers the native path and
  uses ImageMagick only for capabilities libvips cannot serve; `:vips` fails
  closed; `:imagemagick` pins the compatibility pipeline.
- Graceful operation without libvips: the new `SafeImage::VipsUnavailableError`
  (a subclass of `UnsupportedFormatError`) makes `backend: :auto` route through
  ImageMagick on hosts without the library, while explicit `backend: :vips`
  calls fail closed. `SafeImage::VipsGlue.available?` reports the state.
- `docker/run.sh`: containerised validation against Debian bookworm's packaged
  libvips 8.14 with no toolchain installed.

### Changed

- **The compiled C extension is gone.** libvips is now bound at runtime
  through a minimal Fiddle binding (`SafeImage::VipsGlue`) that exposes only
  the operations the gem invokes. Nothing compiles at gem install time; the
  only gem dependencies are `fiddle` and `rexml`. Minimum libvips is 8.13
  (Debian bookworm's 8.14 package is tested); `SAFE_IMAGE_LIBVIPS` overrides
  the library name.
- All transform defaults are now native-first: `resize`, `crop`, `downsize`,
  `convert` and `thumbnail` default to `backend: :auto` (previously
  ImageMagick for the first three and `:vips` fail-closed for `thumbnail`).
  Pin `backend: :imagemagick` where byte-similar output with previously
  generated thumbnails matters.
- The default letter avatar font is now `DejaVu-Sans` (bundled), and the
  native renderer centres the glyph's ink box optically; the ImageMagick
  path's baseline placement (which could clip descenders) remains available
  via `backend: :imagemagick`. Regenerate cached avatars when switching.
- `convert_favicon_to_png` extracts the largest ICO entry rather than the
  last one, and `probe` on ICO reports the largest entry's dimensions from a
  pure-Ruby directory parse.
- libvips' GLib warnings about rejected input (e.g. "Not a PNG file") are
  suppressed by default — failures already surface as exceptions; set
  `SAFE_IMAGE_VIPS_WARNINGS=1` to restore them for debugging.

### Fixed

- `resize`/`crop`/`downsize`/`convert` with `optimize: true` no longer raise
  for output formats the optimizer tools cannot handle (GIF, JPEG XL); the
  optimize pass is skipped instead.
- In-place `fix_orientation` writes through a sibling tempfile and renames,
  so libvips never streams its input into itself.
- Garbage EXIF orientation tags clamp to the valid 1–8 range instead of
  leaking raw values.
- The Landlock sandbox grants read access to Ruby's `libdir`, so workers no
  longer fail to start under `--enable-shared` Rubies installed outside the
  default read roots (e.g. GitHub Actions' hostedtoolcache builds). Sandbox
  failures now include the child's stderr in the error message.

### Security

- The bundled ImageMagick `policy.xml` gained write-only `HISTOGRAM`/`INFO`
  coders (for the dominant-colour backend) and the `JXL` coder, plus a
  regression test asserting the policy parses completely — ImageMagick's
  hand-rolled tokenizer silently truncates the file on a stray backtick or
  apostrophe in a comment.
- The libjxl loader/saver are deliberately re-enabled from libvips'
  untrusted-operation block: JPEG XL is part of the supported input surface,
  and inputs still pass extension routing, pixel caps and (optionally) the
  Landlock sandbox.
- The Fiddle binding doubles as an operation allowlist, and a leak-loop test
  guards GObject reference handling.

## [0.1.0] - 2026-06-09

Initial release: hardened image-processing boundary for untrusted uploads.
Probing and metadata helpers, thumbnails/resize/crop/downsize/convert through
a native libvips fast path with an ImageMagick compatibility backend under a
restrictive bundled policy, JPEG/PNG optimisation (jpegoptim/oxipng/pngquant),
optional Jpegli encoding, allowlist-based SVG sanitising, SSRF-hardened remote
fetching with DNS pinning, symlink-safe path handling, 128MP default pixel
caps, and optional atomic Landlock sandboxing.
