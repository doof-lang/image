# std/image

Mutable raster images, immutable pixel payloads, non-copying image views, encoding, compositing, and resampling. The initial backend is native to macOS and iOS and uses CoreGraphics and ImageIO.

Images have a stable in-memory representation:

- 8-bit RGBA channels
- tightly packed rows (`width * 4` bytes per row)
- sRGB colour space
- premultiplied alpha
- top-left origin

## Usage

```doof
import { Image, ImageFormat, ImageResampling, PixelBytes } from "std/image"

rgba: readonly byte[] := [
  255, 0, 0, 255,
  0, 255, 0, 255,
]

pixels := PixelBytes(2, 1, rgba)
image := try Image.fromPixelBytes(pixels)

// Views retain the image and write through to it.
left := try image.view(0, 0, 1, 1)
left.copyFrom(try Image.create(1, 1), 0, 0)

// Resizing always creates an independent image.
thumbnail := try image.resize(64, 32, .HighQuality)
png := try thumbnail.saveBlob(.Png)
try thumbnail.saveFile("thumbnail.data", ImageFormat.Png)
```

## Types

### `PixelBytes`

An immutable pixel payload with readonly `width`, `height`, `bytes`, and `alphaMode` fields.

```doof
PixelBytes(
  width: int,
  height: int,
  bytes: readonly byte[],
  alphaMode: PixelAlphaMode = .Premultiplied,
)
```

Creation validates positive dimensions, byte-count overflow, and an exact `width * height * 4` payload. The input array is copied. Pixel channel values are not validated; `alphaMode` declares how the payload should be interpreted.

`PixelAlphaMode.Straight` is the escape hatch for APIs that provide ordinary non-premultiplied RGBA. `Image.fromPixelBytes` premultiplies that payload while copying it. Conversely, `image.pixelBytes(.Straight)` unpremultiplies an extracted snapshot. This conversion is quantized at 8 bits and cannot recover RGB values hidden behind alpha zero.

### `Image`

`Image` is a managed, mutable native resource.

| Method | Description |
|---|---|
| `Image.create(width, height)` | Create a transparent image. |
| `Image.fromPixelBytes(pixels)` | Create an image by copying a pixel payload. |
| `Image.loadFile(path)` | Decode the first frame of an image file. |
| `Image.loadBlob(bytes)` | Decode the first frame of encoded bytes. |
| `width()`, `height()` | Return pixel dimensions. |
| `view(x, y, width, height)` | Create a strict, non-empty view within the image. |
| `pixelBytes(alphaMode?)` | Return an immutable pixel snapshot. |
| `resize(width, height, resampling?)` | Return an independently owned resized image. |
| `saveFile(path, format, options?)` | Encode and overwrite a file using the explicit format. |
| `saveBlob(format, options?)` | Return an encoded immutable blob. |
| `copyFrom(source, x, y)` | Replace pixels with an unscaled source image or view. |
| `sourceOver(source, x, y)` | Composite an unscaled source using premultiplied source-over. |

Decoding applies image orientation metadata and converts source colour data and alpha into the canonical representation. Encoded formats with straight alpha need no load option: ImageIO performs the premultiplication while decoding.

### `ImageView`

An `ImageView` retains an `Image` and addresses a rectangular slice. Coordinates passed to a view are relative to that view. Nested views are supported. Creating an empty or out-of-bounds view returns an error rather than clamping.

Views expose the same extraction, resize, save, copy, and source-over operations as images. Destination operations mutate the retained image. Resizing a view produces a new independent `Image` containing only the viewed region.

Blits are clipped to the destination image or view, so negative destination coordinates are valid. Overlapping self-blits behave as if the source region were snapshotted before writing.

## Resampling and encoding

`ImageResampling` provides `Nearest`, `Linear`, and `HighQuality`. CoreGraphics supplies the corresponding platform-native interpolation. Resizing never mutates its source.

`ImageFormat` provides `Png`, `Jpeg`, `Heic`, `Tiff`, and single-frame `Gif`. File extensions are ignored; callers always select the output format explicitly. If an ImageIO encoder such as HEIC is unavailable on the current OS, encoding returns `ImageErrorKind.UnsupportedFormat`.

`ImageEncodeOptions` has a `quality` field defaulting to `0.9`. Values must be between `0.0` and `1.0`. Quality is applied to JPEG and HEIC and ignored by lossless encoders.

## Errors

Fallible operations return `Result<..., ImageError>`. `ImageError` contains a readonly `kind` and diagnostic `message`. Kinds cover invalid arguments, invalid pixel or encoded data, view bounds, unavailable formats, decode failures, encode failures, and file I/O failures.

## Platform and scope

The v1 implementation supports macOS, iOS Simulator, and iOS Device. It does not currently provide a non-Apple backend, animated image access, scaling blits, colour-profile preservation, alternate channel depths/layouts, or direct mutable access to image storage.
