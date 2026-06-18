export enum ImageFormat {
  Png = 0,
  Jpeg = 1,
  Heic = 2,
  Tiff = 3,
  Gif = 4,
}

export enum ImageResampling {
  Nearest = 0,
  Linear = 1,
  HighQuality = 2,
}

export enum PixelAlphaMode {
  Premultiplied = 0,
  Straight = 1,
}

export enum ImageErrorKind {
  InvalidArgument = 0,
  InvalidData = 1,
  OutOfBounds = 2,
  UnsupportedFormat = 3,
  DecodeFailed = 4,
  EncodeFailed = 5,
  IoFailed = 6,
}

export class ImageError {
  readonly kind: ImageErrorKind
  readonly message: string
}

export class ImageEncodeOptions {
  readonly quality: double = 0.9
}
