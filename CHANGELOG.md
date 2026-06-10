# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
