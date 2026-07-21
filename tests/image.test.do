import {
  Image,
  ImageEncodeOptions,
  ImageError,
  ImageErrorKind,
  ImageFormat,
  ImageResampling,
  PixelAlphaMode,
  PixelBytes,
} from "../index"
import { decodeBase64 } from "std/crypto"
import { remove } from "std/fs"
import { join, tempDirectory } from "std/path"

function pixels(width: int, height: int, bytes: readonly byte[]): PixelBytes {
  return PixelBytes(width, height, bytes)
}

function assertBytes(actual: readonly byte[], expected: readonly byte[]): none {
  assert(actual.length == expected.length, "expected byte lengths to match")
  for index of 0..<actual.length {
    assert(
      actual[index] == expected[index],
      "pixel byte mismatch at index ${index}: got ${actual[index]}, expected ${expected[index]}",
    )
  }
}

function failureKind<T>(result: Result<T, ImageError>): ImageErrorKind {
  _ := result else error { return error.kind }
  panic("expected image operation to fail")
}

function check(value: bool): none {
  assert(value, "image test condition failed")
}

export function testPixelValidationAndTransparentCreate(): none {
  image := try! Image.create(2, 2)
  check(image.width() == 2)
  check(image.height() == 2)
  extracted := try! image.pixelBytes()
  expected: readonly byte[] := [
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
  ]
  assertBytes(extracted.bytes, expected)
}

export function testImageCopiesPixelPayloadAndExtractionIsSnapshot(): none {
  original: readonly byte[] := [255, 0, 0, 255]
  image := try! Image.fromPixelBytes(pixels(1, 1, original))
  snapshot := try! image.pixelBytes()

  blueBytes: readonly byte[] := [0, 0, 255, 255]
  blue := try! Image.fromPixelBytes(pixels(1, 1, blueBytes))
  image.copyFrom(blue, 0, 0)

  assertBytes(snapshot.bytes, original)
  assertBytes((try! image.pixelBytes()).bytes, blueBytes)
}

export function testViewsAreStrictNestedAndWriteThrough(): none {
  baseBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 255, 0, 255,
    0, 0, 255, 255,
    255, 255, 255, 255,
  ]
  image := try! Image.fromPixelBytes(pixels(2, 2, baseBytes))
  view := try! image.view(1, 0, 1, 2)
  check(view.width() == 1 && view.height() == 2)
  nested := try! view.view(0, 1, 1, 1)
  white: readonly byte[] := [255, 255, 255, 255]
  assertBytes((try! nested.pixelBytes()).bytes, white)

  yellowBytes: readonly byte[] := [255, 255, 0, 255]
  yellow := try! Image.fromPixelBytes(pixels(1, 1, yellowBytes))
  view.copyFrom(yellow, 0, 0)
  expected: readonly byte[] := [
    255, 0, 0, 255,
    255, 255, 0, 255,
    0, 0, 255, 255,
    255, 255, 255, 255,
  ]
  assertBytes((try! image.pixelBytes()).bytes, expected)

  check(failureKind(image.view(-1, 0, 1, 1)) == .OutOfBounds)
  check(failureKind(view.view(0, 0, 2, 1)) == .OutOfBounds)
  check(failureKind(image.view(0, 0, 0, 1)) == .InvalidArgument)
}

export function testCopyClipsAndOverlappingCopyUsesSnapshot(): none {
  sourceBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 255, 0, 255,
  ]
  source := try! Image.fromPixelBytes(pixels(2, 1, sourceBytes))
  destination := try! Image.create(2, 1)
  destination.copyFrom(source, -1, 0)
  clipped: readonly byte[] := [
    0, 255, 0, 255,
    0, 0, 0, 0,
  ]
  assertBytes((try! destination.pixelBytes()).bytes, clipped)

  overlapBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 255, 0, 255,
    0, 0, 255, 255,
  ]
  overlap := try! Image.fromPixelBytes(pixels(3, 1, overlapBytes))
  firstTwo := try! overlap.view(0, 0, 2, 1)
  overlap.copyFrom(firstTwo, 1, 0)
  expectedOverlap: readonly byte[] := [
    255, 0, 0, 255,
    255, 0, 0, 255,
    0, 255, 0, 255,
  ]
  assertBytes((try! overlap.pixelBytes()).bytes, expectedOverlap)
}

export function testPremultipliedSourceOver(): none {
  destinationBytes: readonly byte[] := [0, 0, 100, 128]
  sourceBytes: readonly byte[] := [100, 0, 0, 128]
  destination := try! Image.fromPixelBytes(pixels(1, 1, destinationBytes))
  source := try! Image.fromPixelBytes(pixels(1, 1, sourceBytes))
  destination.sourceOver(source, 0, 0)
  expected: readonly byte[] := [100, 0, 50, 192]
  assertBytes((try! destination.pixelBytes()).bytes, expected)
}

export function testStraightAlphaPixelBoundary(): none {
  straightBytes: readonly byte[] := [200, 100, 50, 128]
  straight := PixelBytes(1, 1, straightBytes, .Straight)
  check(straight.alphaMode == PixelAlphaMode.Straight)
  image := try! Image.fromPixelBytes(straight)

  premultiplied: readonly byte[] := [100, 50, 25, 128]
  assertBytes((try! image.pixelBytes()).bytes, premultiplied)
  roundTrip := try! image.pixelBytes(.Straight)
  requantizedStraight: readonly byte[] := [199, 100, 50, 128]
  assertBytes(roundTrip.bytes, requantizedStraight)
}

export function testResizeCreatesIndependentImage(): none {
  sourceBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 0, 255, 255,
  ]
  source := try! Image.fromPixelBytes(pixels(2, 1, sourceBytes))
  resized := try! source.resize(4, 2, .Nearest)
  check(resized.width() == 4 && resized.height() == 2)

  clear := try! Image.create(1, 1)
  resized.copyFrom(clear, 0, 0)
  assertBytes((try! source.pixelBytes()).bytes, sourceBytes)

  view := try! source.view(1, 0, 1, 1)
  viewResize := try! view.resize(3, 2, ImageResampling.HighQuality)
  check(viewResize.width() == 3 && viewResize.height() == 2)
  check(failureKind(source.resize(0, 2)) == .InvalidArgument)
}

export function testLosslessBlobRoundTripsAndViewEncoding(): none {
  sourceBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 255, 0, 255,
  ]
  source := try! Image.fromPixelBytes(pixels(2, 1, sourceBytes))

  png := try! source.saveBlob(.Png)
  pngRoundTrip := try! Image.loadBlob(png)
  assertBytes((try! pngRoundTrip.pixelBytes()).bytes, sourceBytes)

  tiff := try! source.saveBlob(.Tiff)
  tiffRoundTrip := try! Image.loadBlob(tiff)
  assertBytes((try! tiffRoundTrip.pixelBytes()).bytes, sourceBytes)

  greenView := try! source.view(1, 0, 1, 1)
  cropped := try! Image.loadBlob(try! greenView.saveBlob(ImageFormat.Png))
  check(cropped.width() == 1 && cropped.height() == 1)
  green: readonly byte[] := [0, 255, 0, 255]
  assertBytes((try! cropped.pixelBytes()).bytes, green)
}

function checkOptionalEncoder(image: Image, format: ImageFormat): none {
  case image.saveBlob(format) {
    success: Success -> {
      decoded := try! Image.loadBlob(success.value)
      check(decoded.width() == image.width() && decoded.height() == image.height())
    }
    failure: Failure -> {
      check(failure.error.kind == .UnsupportedFormat)
    }
  }
}

export function testCuratedLossyAndGifEncoders(): none {
  sourceBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 255, 0, 255,
    0, 0, 255, 255,
    255, 255, 255, 255,
  ]
  image := try! Image.fromPixelBytes(pixels(2, 2, sourceBytes))
  checkOptionalEncoder(image, .Jpeg)
  checkOptionalEncoder(image, .Heic)
  checkOptionalEncoder(image, .Gif)
}

export function testExplicitFormatFileRoundTrip(): none {
  sourceBytes: readonly byte[] := [10, 20, 30, 255]
  image := try! Image.fromPixelBytes(pixels(1, 1, sourceBytes))
  path := join([tempDirectory(), "std-image-explicit-format.data"])
  try! image.saveFile(path, .Png)
  loaded := try! Image.loadFile(path)
  assertBytes((try! loaded.pixelBytes()).bytes, sourceBytes)
  try! remove(path)
}

export function testEncodingAndDecodeErrors(): none {
  image := try! Image.create(1, 1)
  invalidOptions := ImageEncodeOptions { quality: 1.1 }
  check(failureKind(image.saveBlob(.Png, invalidOptions)) == .InvalidArgument)

  corrupt: readonly byte[] := [1, 2, 3, 4]
  check(failureKind(Image.loadBlob(corrupt)) == .DecodeFailed)
  check(failureKind(Image.loadFile("/definitely/not/a/real/image.png")) == .IoFailed)
  check(failureKind(image.saveFile("/definitely/not/a/real/output.png", .Png)) == .IoFailed)
}

export function testDecodeAppliesOrientationMetadata(): none {
  // A 2x1 TIFF containing red then blue, tagged EXIF orientation 6 (90Â° clockwise).
  encoded := try! decodeBase64(
    "TU0AKgAAABD/AAD/AAD//wAPAQAAAwAAAAEAAgAAAQEAAwAAAAEAAQAAAQIAAwAAAAQAAADKAQMAAwAAAAEAAQAAAQYAAwAAAAEAAgAAAQoAAwAAAAEAAQAAAREABAAAAAEAAAAIARIAAwAAAAEABgAAARUAAwAAAAEABAAAARYAAwAAAAEAAQAAARcABAAAAAEAAAAIARwAAwAAAAEAAQAAASgAAwAAAAEAAgAAAVIAAwAAAAEAAQAAAVMAAwAAAAQAAADSAAAAAAAIAAgACAAIAAEAAQABAAE="
  )
  image := try! Image.loadBlob(encoded)
  check(image.width() == 1 && image.height() == 2)
  expected: readonly byte[] := [
    255, 0, 0, 255,
    0, 0, 255, 255,
  ]
  assertBytes((try! image.pixelBytes()).bytes, expected)
}

export function testVerticalPngRoundTripPreservesTopLeftRows(): none {
  sourceBytes: readonly byte[] := [
    255, 0, 0, 255,
    0, 0, 255, 255,
  ]
  source := try! Image.fromPixelBytes(pixels(1, 2, sourceBytes))
  decoded := try! Image.loadBlob(try! source.saveBlob(.Png))
  assertBytes((try! decoded.pixelBytes()).bytes, sourceBytes)
}
