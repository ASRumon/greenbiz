import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Longest side of the image sent to the AI. 1920 px covers Full HD while
/// keeping a camera photo around a few hundred kilobytes.
const int kFullHdLongestSide = 1920;

/// Reads a captured photo, applies EXIF rotation, scales it down to Full HD,
/// and re-encodes it as JPEG. The original never leaves the device.
Future<Uint8List> compressPhotoForAi(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  // Decoding a 12 MP photo is CPU-heavy; keep it off the UI isolate.
  return compute(compressImageBytes, bytes);
}

/// Pure, isolate-friendly half of [compressPhotoForAi]. Also used by tests.
Uint8List compressImageBytes(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('That photo could not be decoded.');
  }

  final img.Image oriented = img.bakeOrientation(decoded);
  final int longest = math.max(oriented.width, oriented.height);

  final img.Image resized = longest > kFullHdLongestSide
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? kFullHdLongestSide : null,
          height: oriented.height > oriented.width ? kFullHdLongestSide : null,
          interpolation: img.Interpolation.average,
        )
      : oriented;

  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}
