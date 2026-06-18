import { imageError, validateDimensions } from "./support"
import { ImageError, PixelAlphaMode } from "./types"

export class PixelBytes {
  readonly width: int
  readonly height: int
  readonly bytes: readonly byte[]
  readonly alphaMode: PixelAlphaMode

  static constructor(
    width: int,
    height: int,
    bytes: readonly byte[],
    alphaMode: PixelAlphaMode = .Premultiplied,
  ): PixelBytes {
    expected := validateDimensions(width, height) else error {
      panic(error.message)
    }
    if long(bytes.length) != expected {
      panic("pixel payload length must equal width * height * 4")
    }

    return PixelBytes { width, height, bytes, alphaMode }
  }
}
