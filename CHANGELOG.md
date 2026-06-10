# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
