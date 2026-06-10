# Safe Image

Safe Image is a small Ruby image-processing boundary for untrusted uploads.

It gives an application one narrow API for probing, thumbnailing, resizing,
cropping, converting, optimising, SVG sanitising, animation checks, dominant
colour extraction, favicon conversion, and letter-avatar generation. The default fast path uses a tiny
Fiddle binding that drives `libvips` directly — pure Ruby, nothing compiles
at install time. Compatibility paths use
ImageMagick, but with shell-free command execution and a restrictive bundled
policy.

Safe Image started as a Discourse extraction: the public surface intentionally
covers the image operations Discourse performs today. The useful part is more
general: hostile image bytes are a lousy thing to spread across model callbacks,
upload helpers, optimizer wrappers, and hand-built command strings.

## Security model

Safe Image is not magic pixie dust. It is a deliberately small choke point.

What it does:

- uses explicit argv arrays for external commands, never shell strings
- starts external commands with an allowlisted environment, private temp/home/cache
  directories, bounded stdout/stderr, and process-group timeout cleanup
- uses explicit libvips loaders selected from allowlisted extensions
- enables libvips' untrusted-operation block in-process (deliberately
  re-enabling only the libjxl loader/saver, which libvips tags untrusted,
  because JPEG XL is part of the supported input surface)
- blocks libvips ImageMagick loader classes in the libvips binding, which
  itself exposes only the operations the gem invokes
- disables libvips cache by default in-process
- strips metadata on generated images where applicable
- rejects symlinked local input/output paths and symlinked path components for
  untrusted file-processing paths
- caps decoded pixels before expensive work: the libvips path enforces a
  default `SafeImage::DEFAULT_MAX_PIXELS` (128MP) ceiling even when no
  `max_pixels` is given, and callers can raise or lower it per call
- ships a restrictive ImageMagick `policy.xml`
- denies Ghostscript-backed formats and dangerous ImageMagick features:
  - `PS`, `PS2`, `PS3`, `EPS`, `EPSF`, `PDF`, `XPS`, `PCL`
  - `MSL`, `MVG`
  - `HTTP`, `HTTPS`, `URL`
  - delegates, filters, and `@file` indirection
- supports optional Landlock subprocess sandboxing on Linux

The ImageMagick backend is explicit. Safe Image will not silently fall from the
libvips path into generic ImageMagick decoding.

## Install

Nothing compiles at install time: libvips is bound at runtime through Fiddle
(`libvips.so.42` is dlopened on first use; `SAFE_IMAGE_LIBVIPS` overrides the
library name authoritatively). libvips' GLib warnings about rejected input
(e.g. "Not a PNG file") are silenced — failures surface as exceptions
instead; set `SAFE_IMAGE_VIPS_WARNINGS=1` to restore them for debugging. Install the runtime
[dependencies](#dependencies) below; to fail fast at boot rather than on the
first image operation, call `SafeImage::VipsGlue.init!` during startup.

libvips is strongly recommended but not mandatory: on a host with only
ImageMagick, every `backend: :auto` operation routes through the ImageMagick
compatibility paths and the pure-Ruby paths (SVG, ICO metadata) are
unaffected. Explicit `backend: :vips` calls fail closed with
`SafeImage::VipsUnavailableError`, and `SafeImage::VipsGlue.available?`
reports the state.

```bash
gem build safe_image.gemspec
gem install ./safe_image-0.1.0.gem
```

```ruby
require "safe_image"

result = SafeImage.thumbnail(
  input: "upload.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  max_pixels: 40_000_000
)

puts "#{result.backend}: #{result.width}x#{result.height} #{result.filesize} bytes"

SafeImage.convert(
  "upload.png",
  "upload.jpg",
  format: "jpg",
  quality: 85,
  max_pixels: 40_000_000
)
```

## Dependencies

### Quick install

Debian / Ubuntu:

```bash
sudo apt-get install --no-install-recommends \
  libvips42 imagemagick jpegoptim pngquant oxipng libjpeg-turbo-progs
```

`oxipng` is packaged from Debian 13 / Ubuntu 24.04; on older releases install
it with `cargo install oxipng`. For `cjpegli`, Debian/Ubuntu package names
vary by release (`libjpegli-tools` where available); it is optional and
detected at runtime.

Arch:

```bash
sudo pacman -S --needed libvips \
  imagemagick jpegoptim pngquant oxipng libjpeg-turbo libjxl
```

(`libjpeg-turbo` provides `jpegtran`, `libjxl` provides `cjpegli`.)

### What each dependency is for

| Dependency | Kind | Needed for | Without it |
| --- | --- | --- | --- |
| `libvips` runtime library (`libvips.so.42`; Debian: `libvips42` ≥ 8.13) | strongly recommended | the fast path for every operation, bound via Fiddle at first use | `backend: :auto` routes everything through ImageMagick instead; explicit `backend: :vips` raises `VipsUnavailableError` |
| ImageMagick (`magick`/`convert`, `identify`) | optional | the explicit `backend: :imagemagick` opt-in paths, and ICO-input routing for the transform operations | ICO transforms and explicit `:imagemagick` calls raise; everything else runs natively |
| `jpegoptim` | required for JPEG `optimize` | lossless JPEG optimisation and metadata stripping | JPEG `optimize` raises in strict mode |
| `oxipng` | required for PNG `optimize` | lossless PNG optimisation | PNG `optimize` raises in strict mode |
| `pngquant` | optional | lossy PNG quantisation (`optimize_mode: :lossy`, files < 500KB) | lossy mode silently skips the quantisation pass |
| `jpegtran` (libjpeg-turbo) | optional | lossless tier of `fix_orientation` for MCU-aligned JPEGs | falls back to the libvips re-encode tier |
| `cjpegli` (libjxl) | optional | higher-quality encoding of generated JPEGs (`encoder: :auto`) | falls back to libvips/ImageMagick JPEG encoders |
| `landlock` gem (Linux kernel ≥ 5.13) | optional, opt-in | the atomic sandbox (`SafeImage.enable_sandbox!`) | `sandbox_available?` is false; inline execution only |
| `rexml` gem | automatic | SVG sanitising and SVG metadata | installed as a gem dependency |

The `landlock` gem is intentionally **not** a gem dependency; add it to the
host application's Gemfile if you want sandboxing.

### libvips build capabilities

Some features depend on how the host's libvips was built (all present in
stock Debian, Ubuntu and Arch packages):

- **libheif** — HEIC/AVIF decode (`probe`, `convert`, thumbnails)
- **Pango text** (`VipsText`) — native `letter_avatar`; without it the
  operation falls back to ImageMagick
- **cgif** (`gifsave`) — GIF *output* from the vips backend; GIF *decode*
  (libnsgif) is always built in
- **libjxl** (`jxlload`/`jxlsave`) — JPEG XL decode and encode

Check a host with:

```bash
vips -l | grep -cE "VipsForeignSaveCgif|VipsText|VipsForeignLoadHeif|VipsForeignLoadJxl" # expect 4+
```

### Fonts

Letter avatars need **no font packages** with the default `DejaVu-Sans`
token: the gem bundles DejaVu Sans and pins it via fontconfig's app-font API.
The other allowlisted tokens (`NimbusSans-Regular`, `Liberation-Sans`,
`Arial`, `Helvetica`, `Adwaita-Sans`) resolve through system fontconfig —
install e.g. `fonts-liberation` (Debian/Ubuntu) or `ttf-liberation` (Arch) if
you select them. Glyphs outside DejaVu's coverage (CJK, Hangul, ...) fall
back per-glyph to whatever system fonts exist.

### Checking a host

```ruby
require "safe_image"

%w[magick identify jpegoptim oxipng pngquant jpegtran cjpegli].each do |tool|
  puts format("%-10s %s", tool, SafeImage::Runner.available?(tool) ? "ok" : "missing")
end
puts format("%-10s %s", "libvips", SafeImage::VipsGlue.available? ? "ok" : "unavailable (ImageMagick fallback)")
puts format("%-10s %s", "sandbox", SafeImage.sandbox_available? ? "ok" : "unavailable")
```

## Return values

Image-producing operations return `SafeImage::Result`:

```ruby
SafeImage::Result[
  input:,          # source path or "generated"
  output:,         # output path, nil for probe
  input_format:,   # "jpg", "png", "webp", "heic", "avif", etc.
  output_format:,  # output format, nil for probe
  width:,
  height:,
  filesize:,
  backend:,        # e.g. "libvips-direct", "imagemagick", "cjpegli",
                   #      "libvips-direct+cjpegli", or "sandboxed-..."
  duration_ms:,
  optimizer:       # optimizer tool list for thumbnail path, otherwise nil
]
```

Optimizer operations return a hash:

```ruby
{
  format: "jpg",
  before_bytes: 123_456,
  after_bytes: 120_000,
  saved_bytes: 3_456,
  tools: ["jpegoptim"]
}
```

## Core API

### `SafeImage.probe(path, max_pixels: nil)`

Reads image metadata through the direct libvips backend.

Supported inputs:

- `jpg` / `jpeg`
- `png`
- `gif` (first frame, via libvips' bundled libnsgif loader)
- `webp`
- `heic` / `heif`
- `avif`
- `jxl` (requires a libvips build with libjxl support)
- `ico` (pure-Ruby directory parse; reports the largest entry's dimensions)

```ruby
info = SafeImage.probe("upload.jpg", max_pixels: 40_000_000)
puts "#{info.width}x#{info.height} #{info.input_format}"
```

Raises `SafeImage::LimitError` if `width * height > max_pixels`.

### `SafeImage.thumbnail(...)`

Creates a center-cropped thumbnail.

```ruby
result = SafeImage.thumbnail(
  input: "upload.jpg",
  output: "thumb.jpg",
  width: 600,
  height: 400,
  format: nil,              # inferred from output extension when nil
  quality: 85,
  max_pixels: 40_000_000,
  backend: :auto,           # :auto (vips, or ImageMagick when vips is absent), :vips, :imagemagick
  optimize: true,
  optimize_mode: :lossless, # :lossless or :lossy for PNG optimisation
  execution: :inline,       # :inline, :sandbox, :sandbox_if_available
  encoder: :auto,           # :auto, :cjpegli, :vips, :imagemagick for JPEG output
  chroma_subsampling: :auto # :auto, "420", "422", "444"
)
```

Supported outputs for the direct libvips backend:

- `jpg` / `jpeg`
- `png`
- `gif` (requires a libvips build with cgif support; raises `UnsupportedFormatError` otherwise)
- `webp`
- `avif`
- `jxl` (requires a libvips build with libjxl support)

`execution: :sandbox` is fail-closed: it raises if Landlock is unavailable.
`execution: :sandbox_if_available` uses the sandbox only when available.

## JPEG encoder selection

Safe Image separates **encoding generated JPEGs** from **optimising existing
JPEGs**. This avoids hiding a lossy re-encode behind a method named `optimize`.

| Operation | `encoder: :auto` behavior |
| --- | --- |
| `thumbnail` / `resize` / `crop` / `downsize` to JPEG with `backend: :vips` | use `cjpegli` when installed; otherwise use normal libvips JPEG output |
| `convert("input.png", "output.jpg", format: "jpg")` | use `cjpegli` when installed; otherwise use ImageMagick compatibility path |
| `convert` from HEIC/WebP/AVIF/GIF/JPEG to JPEG | decode through the native libvips loaders and encode with libvips; `cjpegli` is not treated as a universal decoder |
| `optimize("existing.jpg")` | use `jpegoptim`; never use `cjpegli` by default |

Encoder controls:

| Option | Meaning |
| --- | --- |
| `encoder: :auto` | best available default with safe fallback |
| `encoder: :cjpegli` | require Jpegli and fail closed if unavailable/unsupported |
| `encoder: :vips` | force normal libvips JPEG output where available |
| `encoder: :imagemagick` | force ImageMagick compatibility output |

`cjpegli` output is ordinary browser-compatible JPEG. It is optional because it
is a system binary, not a Ruby dependency. Safe Image detects it at runtime.

`chroma_subsampling: :auto` uses `4:4:4` for PNG-sourced JPEG conversion and
`4:2:0` otherwise. Pass `"420"`, `"422"`, or `"444"` to force a value.

## Local metadata helpers

These helpers are intended to cover the local-file parts of APIs like
`FastImage.type`, `FastImage.size`, and `FastImage#orientation` without adding a
Ruby dependency. They do not fetch remote URLs.

### `SafeImage.type(path, max_pixels: nil)`

Returns a FastImage-style symbol for a local file:

```ruby
SafeImage.type("upload.jpg") # => :jpeg
SafeImage.type("upload.png") # => :png
SafeImage.type("icon.svg")   # => :svg
```

JPEG is returned as `:jpeg`, not `:jpg`, to match common Ruby image-probing
conventions.

### `SafeImage.size(path, max_pixels: nil)` / `SafeImage.dimensions(path, max_pixels: nil)`

Returns `[width, height]` for a local file:

```ruby
SafeImage.size("upload.jpg")       # => [1600, 1200]
SafeImage.dimensions("upload.png") # => [800, 600]
SafeImage.size("icon.svg")         # => [120, 80]
```

SVG metadata is handled by a dedicated parser, not ImageMagick or libvips. It is
limited to local `.svg` files, caps input size/tree depth/element/attribute
counts, rejects `DOCTYPE` and non-XML processing instructions, requires an `<svg>`
root, and derives dimensions from numeric `width`/`height` or `viewBox`.

### `SafeImage.orientation(path, max_pixels: nil)`

Returns the EXIF orientation integer (1-8) for a local file from the
orientation header field the native libvips loaders populate during the
header scan — no pixel data is decoded, and garbage tag values clamp to `1`.
SVG and ICO report `1` by definition; ImageMagick identify remains only as
the fallback for formats outside the native loader allowlist.

Note one deliberate HEIC difference: libheif applies the container's
`irot`/`imir` transforms during decode, so the native path reports the
orientation of the pixels as actually decoded, rather than echoing a raw
EXIF tag that may already be baked in.

```ruby
SafeImage.orientation("upload.jpg") # => 1
```

### `SafeImage.info(path, max_pixels: nil, animated: false, orientation: false)`

Returns a `SafeImage::Info` object for a local file:

```ruby
info = SafeImage.info("upload.jpg", animated: true, orientation: true)
info.type        # => :jpeg
info.width       # => 1600
info.height      # => 1200
info.size        # => [1600, 1200]
info.animated    # => false
info.orientation # => 1
```

`animated:` and `orientation:` default to `false` because they may require extra
ImageMagick work. When disabled, those fields are `nil`.

## Remote metadata helpers

These helpers are intended to cover `FastImage.size(url)` / `FastImage.type(url)`
style use cases without another Ruby dependency. They use only Ruby stdlib
`Net::HTTP`, download to a tempfile with a byte cap, then run the normal Safe
Image local metadata path on that tempfile.

Remote fetching is deliberately conservative:

- only `http` and `https` URLs are accepted
- redirects are capped
- open/read timeouts and an overall `total_timeout` are capped
- response size is capped by `max_bytes`
- public remote fetches are limited to ports 80 and 443 by default
- `Net::HTTP` environment proxies are disabled; proxy environment variables cannot
  route around IP validation
- DNS answers are checked against a special-use address blocklist and the
  connection is pinned to a vetted IP address to avoid DNS-rebinding/TOCTOU
  bypasses
- HTTPS-to-HTTP redirects are rejected
- same-origin redirects keep caller headers; cross-origin redirects use a small
  header allowlist (`Accept`, `Accept-Encoding`, `User-Agent`) rather than a
  blacklist
- initial caller-supplied request headers use the same small allowlist; cookies,
  authorization headers, and custom auth headers are not forwarded by default
- hop-by-hop/proxy/`Host` request headers are rejected before any request
- private, loopback, link-local, multicast, documentation, benchmarking,
  carrier-grade NAT, IPv4-mapped IPv6, NAT64, 6to4/Teredo, and other
  special-use resolved addresses are rejected by default
- no image decoding happens directly from the socket
- the final response `Content-Type` must be an allowed image type and must agree
  with an image-looking URL extension when one is present
- downloaded content is probed before `fetch_remote` yields the tempfile, so the
  raw downloader cannot be used as a blind extension-based file saver
- SVG remote metadata uses the same bounded SVG metadata parser after download;
  SVG is not handed to ImageMagick for probing

Set `allow_private: true` only when the caller has already made an SSRF decision
or is intentionally probing a trusted internal URL. Passing `allow_private: true`
also permits non-standard ports; for public fetches, pass `allowed_ports:` if you
really need to allow a different port.

### `SafeImage.remote_size(url, ...)` / `SafeImage.remote_dimensions(url, ...)`

```ruby
SafeImage.remote_size(
  "https://example.com/image.jpg",
  max_bytes: 10.megabytes,
  total_timeout: 30,
  max_pixels: 40_000_000
)
# => [1600, 1200]
```

### `SafeImage.remote_type(url, ...)`

```ruby
SafeImage.remote_type("https://example.com/image.png", max_bytes: 10.megabytes)
# => :png
```

### `SafeImage.remote_info(url, ...)`

```ruby
info = SafeImage.remote_info(
  "https://example.com/image.gif",
  max_bytes: 10.megabytes,
  animated: true
)
info.type     # => :gif
info.size     # => [640, 480]
info.animated # => true
```

### `SafeImage.remote_animated?(url, ...)`

```ruby
SafeImage.remote_animated?("https://example.com/image.webp", max_bytes: 10.megabytes)
# => true / false
```

### `SafeImage.remote_dominant_color(url, ...)`

```ruby
SafeImage.remote_dominant_color("https://example.com/image.png", max_bytes: 10.megabytes)
# => "6F745E"
```

### `SafeImage.fetch_remote(url, ...) { |path| ... }`

Downloads a remote image to a tempfile and yields the local path:

```ruby
SafeImage.fetch_remote("https://example.com/image.jpg", max_bytes: 10.megabytes) do |path|
  SafeImage.probe(path)
end
```

When global Landlock is enabled, the network fetch itself is not put inside the
Landlock worker because the worker denies network access. The downloaded tempfile
is then passed through the normal Safe Image local image APIs, so decoding still
uses the same sandboxed image-processing path.

## Compatibility API

These methods are shaped around the image operations Discourse currently
performs. They are useful outside Discourse too, but the names are deliberately
boring because they map to common upload-pipeline tasks.

### `SafeImage.resize(from, to, width, height, quality: nil, backend: :auto, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)`

Creates a resized thumbnail-style output.

```ruby
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400)
SafeImage.resize("upload.jpg", "thumb.jpg", 600, 400, backend: :imagemagick, quality: 85)
```

Backends (shared by `resize`, `crop` and `downsize`):

- `:auto` (default) — direct libvips path; only formats outside the native
  loader allowlist (ICO) fall back to the ImageMagick compatibility path
- `:vips` — direct libvips path, fail-closed
- `:imagemagick` — the compatibility path matching Discourse's historical
  `convert` pipelines (`-thumbnail`, catrom interpolation, unsharp, sRGB
  profile); pin this if byte-similar output with existing thumbnails matters

### `SafeImage.crop(from, to, width, height, quality: nil, backend: :auto, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto)`

Creates a north-cropped image. This matches the avatar/optimized-image crop
shape used by Discourse.

```ruby
SafeImage.crop("upload.jpg", "avatar.jpg", 240, 240)
SafeImage.crop("upload.jpg", "avatar.jpg", 240, 240, backend: :imagemagick)
```

### `SafeImage.downsize(from, to, dimensions, backend: :auto, optimize: true, max_pixels: nil, quality: 85, encoder: :auto, chroma_subsampling: :auto)`

Downsizes an image using ImageMagick-style geometry strings.

```ruby
SafeImage.downsize("large.png", "small.png", "50%")
SafeImage.downsize("large.png", "small.png", "100x100>")
SafeImage.downsize("large.png", "small.png", "400000@", backend: :imagemagick)
```

The direct vips backend supports the geometry forms covered by the test suite:
percentage, bounding box with `>`, and pixel-area cap with `@`.

### `SafeImage.convert(from, to, format:, quality: nil, optimize: true, max_pixels: nil, encoder: :auto, chroma_subsampling: :auto, backend: :auto)`

Converts an input image to an explicit output `format:`. Unsupported formats
raise `SafeImage::UnsupportedFormatError`.

The default `backend: :auto` decodes through the native libvips loaders,
auto-orients, flattens transparency onto white for JPEG targets (matching the
ImageMagick path's `-background white -flatten`), and re-encodes. When no
`quality:` is given, native JPEG output uses quality 92 — what ImageMagick
uses for sources without quality tables — rather than libvips' default 75.
Only format routing libvips cannot serve (ICO input, ICO output) falls back
to the ImageMagick compatibility backend; `backend: :vips` makes that
fail-closed, and `backend: :imagemagick` forces the compatibility path.

For JPEG output, `encoder: :auto` uses `cjpegli` when it is installed and the
input can be encoded directly by Jpegli (intentionally limited to PNG input).
Use `encoder: :cjpegli` to require Jpegli and fail closed, `encoder: :vips`
to force the libvips encoder, or `encoder: :imagemagick` (legacy alias for
`backend: :imagemagick`) to force the compatibility path.

```ruby
SafeImage.convert("upload.png", "upload.jpg", format: "jpg", quality: 85)
SafeImage.convert("upload.png", "upload.jpg", format: "jpg", quality: 85, encoder: :cjpegli)
SafeImage.convert("upload.heic", "upload.jpg", format: "jpg", quality: 85)
SafeImage.convert("upload.jpg", "upload.webp", format: "webp", quality: 85)
```

### `SafeImage.fix_orientation(from, to = from, max_pixels: nil, quality: nil, backend: :auto)`

Bakes the EXIF orientation into the pixels and clears the tag. The `:auto`
backend tries tiers in order:

1. **jpegtran (lossless)** — for JPEGs with `jpegtran` installed, the
   transform happens on the DCT coefficients with zero generation loss.
   `-perfect` refuses non-MCU-aligned dimensions, in which case:
2. **libvips re-encode** — autorotate and re-encode, stripping metadata.
   JPEG output uses `quality:` (default 95; note the ImageMagick path
   re-encodes at the input's estimated quality instead).
3. **ImageMagick** is never used implicitly here; opt in with
   `backend: :imagemagick` for the previous `-auto-orient` behaviour.

If `to` is omitted, the file is
rewritten in place.

```ruby
SafeImage.fix_orientation("upload.jpg")
SafeImage.fix_orientation("upload.jpg", "oriented.jpg")
```

### `SafeImage.convert_favicon_to_png(from, to, optimize: true, max_pixels: nil)`

Extracts the largest ICO entry and writes PNG, without ImageMagick: the
container and legacy DIB payloads (1/4/8/24/32bpp BI_RGB plus the AND mask)
are parsed in pure Ruby with explicit bounds checks, and pixels are encoded
through the hardened native libvips path. Embedded PNG payloads are
re-encoded — never copied through verbatim — and their pixel cap is enforced
from the IHDR before any decoder runs.

```ruby
SafeImage.convert_favicon_to_png("favicon.ico", "favicon.png")
```

### `SafeImage.frame_count(path, max_pixels: nil)`

Returns the frame count from the n-pages header field via the native libvips
loaders — no pixel data is decoded. ICO directories are counted by the
pure-Ruby parser. ImageMagick identify remains only as the fallback for
formats neither path knows.

```ruby
frames = SafeImage.frame_count("animated.gif")
```

### `SafeImage.animated?(path, max_pixels: nil)`

Returns `true` when `frame_count(path) > 1`.

```ruby
SafeImage.animated?("animated.webp")
```

### `SafeImage.dominant_color(path, max_pixels: nil, backend: :auto)`

Computes the image's alpha-weighted average colour (first frame for animated
formats) and returns it as an uppercase `RRGGBB` hex string, matching the
value Discourse stores from `Upload#calculate_dominant_color!`.

The default `:auto` backend computes the per-channel mean natively through
libvips; ICO routes through the pure-Ruby ICO decoder, so no format needs
ImageMagick. Pass
`backend: :vips` to forbid ImageMagick entirely, or `backend: :imagemagick`
for the histogram command Discourse runs today. The two backends agree to
within a few least-significant bits per channel (ImageMagick averages through
its resize filter rather than computing the exact mean).

The pixel cap is enforced before the full decode on either backend,
undecodable input raises `InvalidImageError` (never retried on the other
backend), and SVG input raises `UnsupportedFormatError`.

```ruby
SafeImage.dominant_color("upload.png")                       # => "6F745E"
SafeImage.dominant_color("upload.png", backend: :vips)       # ImageMagick-free
```

### `SafeImage.letter_avatar(output:, size:, background_rgb:, letter:, pointsize: 280, font: "DejaVu-Sans", backend: :auto)`

Generates a square letter avatar PNG: one grapheme blended in white at 80%
opacity over a solid background.

The default `:auto` backend renders natively through libvips' Pango text
support (the glyph is markup-escaped before rendering) and falls back to
ImageMagick only when the libvips build has no text renderer. Pass
`backend: :vips` or `backend: :imagemagick` to pin a path.

The default `DejaVu-Sans` font uses the DejaVu Sans file bundled with the gem
(see `lib/safe_image/fonts/DEJAVU-LICENSE`), so rendering does not depend on
which fonts the host has installed. The other allowlisted tokens
(`NimbusSans-Regular`, `Liberation-Sans`, `Arial`, `Helvetica`,
`Adwaita-Sans`) resolve through fontconfig.

The native path centres the glyph's ink box optically, which differs from the
ImageMagick path's baseline placement (where descenders could clip at the
canvas edge). Treat switching backends as a visual change: regenerate cached
avatars (in Discourse, bump `LetterAvatar::VERSION`).

```ruby
SafeImage.letter_avatar(
  output: "avatar.png",
  size: 360,
  background_rgb: [1, 2, 3],
  letter: "S"
)
```

### `SafeImage.optimize(path, mode: :lossless, strip_metadata: true, quality: nil, strict: true)`

Optimises an existing JPEG or PNG in place.

```ruby
SafeImage.optimize("image.jpg", quality: 85)
SafeImage.optimize("image.png")
SafeImage.optimize("image.png", mode: :lossy, quality: "65-90")
```

JPEG path:

- uses `jpegoptim`
- `quality:` maps to `jpegoptim --max`
- metadata is stripped unless `strip_metadata: false`

PNG path:

- uses `oxipng` for lossless optimisation
- when `mode: :lossy`, uses `pngquant` first for PNGs smaller than 500 KB,
  then `oxipng`

When `strict: true`, missing optimizer tools raise. When `strict: false`, missing
optimizer tools are tolerated.

### `SafeImage.optimize_image!(path, allow_lossy_png: false, strip_metadata: true, quality: nil, strict: true)`

Compatibility wrapper around `SafeImage.optimize`.

```ruby
SafeImage.optimize_image!("image.jpg")
SafeImage.optimize_image!("image.png", allow_lossy_png: true)
```

### `SafeImage.sanitize_svg!(path)`

Sanitises an SVG in place using a small REXML allowlist.

```ruby
result = SafeImage.sanitize_svg!("icon.svg")
puts result[:sanitized]
```

The sanitizer removes unsafe elements/attributes such as scripts and event
handlers. It is intentionally conservative rather than a full browser-grade SVG
implementation.

## Security posture

Safe Image is a hardened boundary for untrusted image processing, not a magic
wand. The goal is to centralize risky operations, make the safe path boring, and
remove common image-processing foot-guns.

Baseline hardening:

- external commands use argv arrays, never shell strings
- command environment, temp/home/cache directories, stdout/stderr size, and
  process-group timeout cleanup are controlled
- libvips loaders are selected explicitly from an allowlist
- libvips' untrusted-operation block is enabled in-process
- libvips ImageMagick loader classes are blocked in the libvips binding
- libvips cache is disabled by default in-process
- local untrusted input/output paths reject symlinks and symlinked path components
- generated images strip metadata where applicable
- `max_pixels` checks fail before expensive work; the libvips path applies a
  default 128MP ceiling (`SafeImage::DEFAULT_MAX_PIXELS`) when none is supplied
- remote fetch uses SSRF hardening: scheme/port restrictions, special-use IP
  blocking, DNS pinning, redirect limits, HTTPS-to-HTTP rejection, proxy-env
  bypass prevention, request-header allowlists, content-type/extension agreement,
  and probe-before-yield
- SVG metadata uses a bounded parser; SVG is not handed to ImageMagick for probing
- SVG sanitising is conservative and allowlist based; it rejects `DOCTYPE` and
  XML processing instructions, removes comments and disallowed elements, converts
  CDATA to escaped text, and blocks event handlers, external URLs, and
  `javascript:` / `data:` URL values

SVG sanitising is defense-in-depth for stored bytes. Applications that serve
user-supplied SVGs directly should still use response-level controls such as a
restrictive `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, and/or
attachment/sandbox handling for direct-open routes. Browsers restrict script
execution when an SVG is embedded as `<img>`, but a top-level SVG document is a
different sink.

### Security posture without Landlock

Without Landlock, Safe Image still hardens the ImageMagick path substantially:

- delegates are disabled
- filters are disabled
- `@file` indirection is disabled
- remote URL coders are disabled
- Ghostscript/document/vector formats are denied
- coders are deny-by-default with a small raster allowlist
- commands are executed with argv arrays, not shell strings
- command environment and ImageMagick policy path are controlled
- ImageMagick resource limits are set in the bundled policy

That does **not** make hostile files benign. Raster decoders still parse attacker
controlled bytes: libjpeg, libpng, libwebp, libheif/HEIC/AVIF, ImageMagick's
raster decoders, and libvips loaders. If one of those decoders has a memory
corruption bug or pathological resource-consumption bug, policy alone is not a
sandbox.

So the intended posture is:

- without Landlock: hardened, centralized image processing with the major
  ImageMagick delegate/pseudo-protocol foot-guns removed
- with Landlock: the same hardening plus a real containment boundary around all
  public operations

Do not describe non-sandboxed operation as making hostile images safe. The honest
claim is defense-in-depth, not immunity.

## Atomic Landlock sandboxing

Landlock support is optional, but atomic once enabled.

```ruby
SafeImage.sandbox_available? # => true/false
SafeImage.enable_sandbox!    # raises if unavailable
SafeImage.sandbox_enabled?   # => true
```

After `SafeImage.enable_sandbox!`, every public operation routes through the
sandbox worker:

- `probe`
- `type`
- `size`
- `dimensions`
- `info`
- `orientation`
- `dominant_color`
- `thumbnail`
- `optimize`
- `resize`
- `crop`
- `downsize`
- `convert`
- `convert_to_jpeg` compatibility alias
- `fix_orientation`
- `convert_favicon_to_png`
- `frame_count`
- `animated?`
- `letter_avatar`
- `optimize_image!`
- `sanitize_svg!`

There is no silent fallback after global sandbox enablement. If sandbox setup or
a sandboxed command fails, the operation fails.

The sandbox grants read/write access only to the paths inferred from the
operation arguments, plus runtime/library paths and temporary directories needed
by Ruby, libvips, ImageMagick, and optimizer tools. Network syscalls are denied
through the Landlock helper's seccomp layer.

## Discourse parity

Safe Image currently covers the image-operation surface Discourse performs in:

- optimized image generation
- upload preprocessing
- thumbnail generation
- avatar cropping / letter avatars
- favicon conversion
- HEIC/PNG-to-JPEG conversion
- orientation fixing
- animated image detection
- dominant colour extraction
- JPEG/PNG optimisation
- SVG sanitising

The claim is operation parity, not byte-for-byte output identity across all
ImageMagick/libvips versions. The test suite includes golden compatibility
checks, ImageMagick parity checks, policy-denial checks, and a real-image atomic
sandbox sweep over the full public operation list.

## Development

```bash
bundle install
bundle exec rake          # run the tests (nothing compiles)
docker/run.sh             # run the suite on Debian bookworm's packaged libvips 8.14
bundle exec rubocop       # lint
```

The minitest suite lives in `test/*_test.rb`; individual files run standalone
(`bundle exec ruby test/operations_test.rb`). Tests that depend on optional
host support — cjpegli, HEIC delegates, the Landlock sandbox — skip with an
explanation when that support is missing.

Gem packaging uses the standard Bundler tasks (`rake build`, `rake install`).
Releases follow the Discourse gem publication flow: bump
`SafeImage::VERSION`, merge to `main`, and CI publishes the gem to
RubyGems once the test matrix is green.

## Security reporting

Please report suspected security issues privately to `sam@discourse.org`.

See [`SECURITY.md`](SECURITY.md) for the threat model, non-goals, and reporting
checklist.

## License

Safe Image is MIT licensed.

The gem dynamically links to system `libvips`; `libvips` is
LGPL-2.1-or-later. Safe Image does not vendor `libvips`.

The gem bundles the DejaVu Sans font for deterministic letter-avatar
rendering; its license (Bitstream Vera derivative, freely redistributable)
ships alongside the font at `lib/safe_image/fonts/DEJAVU-LICENSE`.

Optional command-line tools are discovered at runtime and executed as external
programs; they are not bundled into the gem. Typical licenses for those optional
tools are:

| Tool | Purpose | Typical license |
| --- | --- | --- |
| ImageMagick `magick` / `convert` / `identify` | compatibility operations | ImageMagick license |
| `jpegoptim` | JPEG lossless optimisation / metadata stripping | GPL-2.0-or-later |
| `oxipng` | PNG lossless optimisation | MIT |
| `pngquant` | optional lossy PNG quantisation | GPL-3.0-or-later / ISC / BSD-2-Clause components |
| `cjpegli` / `djpegli` / `cjxl` | optional JPEG/JPEG XL tooling when installed | BSD-3-Clause via libjxl |
| `heif-enc` / libheif tools | optional HEIC/AVIF tooling when installed | LGPL-3.0-or-later |

Deployment packages may vary; check your distribution's package metadata if
license compliance depends on the exact binary build.