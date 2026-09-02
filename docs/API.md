# std/image Guide

`std/image` provides mutable raster images, immutable pixel snapshots,
non-copying views, encoding, compositing, and resizing. Native backends use
CoreGraphics and ImageIO on Apple platforms and Windows Imaging Component (WIC)
on Windows. Pinned libwebp sources provide WebP encoding on both backends.

## Pixel Model

Images use one canonical in-memory representation:

- 8-bit RGBA
- tightly packed rows
- sRGB
- premultiplied alpha
- top-left origin

`PixelBytes` is immutable and validates dimensions plus exact byte length. It
does not inspect channel values. `PixelAlphaMode` tells the image loader whether
the bytes are already premultiplied or should be premultiplied while copying.

Extracting `pixelBytes(.Straight)` unpremultiplies a snapshot, which is useful
for interchange but quantized at 8 bits.

## Images And Views

`Image` owns mutable native storage. `ImageView` retains an image and addresses a
strict rectangular region. Views do not copy pixels, and destination operations
write through to the retained image.

View coordinates are relative to the view. Empty or out-of-bounds views return
errors. Blits are clipped to the destination, and overlapping self-blits behave
as if the source were snapshotted first.

## Encoding And Resizing

`resize` always returns an independent image. Resampling can be nearest, linear,
or high quality.

File extensions are ignored when saving; callers choose `ImageFormat`
explicitly. `ImageEncodeOptions.quality` applies to JPEG, HEIC, and lossy WebP.
Set `ImageEncodeOptions.lossless` to encode lossless WebP; it is ignored for
other formats, and quality is ignored for lossless WebP. WebP output is
single-frame.

## Platform Scope

The v1 backend supports macOS, iOS Simulator, iOS Device, and Windows. It does
not yet support animated images, scaling blits, color-profile
preservation, alternate channel depths/layouts, or direct mutable pixel access.

## API Map

Types:

- `PixelBytes`
- `Image`
- `ImageView`
- `ImageFormat`
- `ImageResampling`
- `PixelAlphaMode`
- `ImageEncodeOptions`
- `ImageError`
- `ImageErrorKind`

Key operations:

- create/load images
- create views
- extract pixel snapshots
- resize
- save to files or blobs
- copy pixels
- source-over composite pixels

Declarations are defined in [index.do](../index.do), [pixel_bytes.do](../pixel_bytes.do),
and [types.do](../types.do).
