import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/image_compression.dart';
import 'package:greenbiz/services/product_scan_ai.dart';
import 'package:image/image.dart' as img;

void main() {
  group('parseProductScan', () {
    test('reads a plain JSON reply', () {
      final ProductScanResult result = parseProductScan(
        '{"productName":"Fresh Milk 1L","unit":"litre","priceMajor":12.5,"confidence":0.92,"notes":""}',
      );

      expect(result.productName, 'Fresh Milk 1L');
      expect(result.unit, 'litre');
      expect(result.unitPriceMinor, 1250);
      expect(result.confidence, closeTo(0.92, 0.001));
      expect(result.notes, isNull);
      expect(result.isEmpty, isFalse);
    });

    test('strips markdown fences', () {
      final ProductScanResult result = parseProductScan(
        'Here you go:\n```json\n{"productName":"Aromatic Rice 5kg","unit":"bag","priceMajor":650}\n```',
      );

      expect(result.productName, 'Aromatic Rice 5kg');
      expect(result.unitPriceMinor, 65000);
    });

    test('converts a formatted price exactly', () {
      final ProductScanResult result = parseProductScan(
        '{"productName":"Tea","unit":"packet","priceMajor":"1,250.00"}',
      );
      expect(result.unitPriceMinor, 125000);
    });

    test('leaves the price empty when the label did not show one', () {
      final ProductScanResult result = parseProductScan(
        '{"productName":"Soap","unit":"piece","priceMajor":null}',
      );
      expect(result.unitPriceMinor, isNull);
    });

    test('marks an unreadable label as empty', () {
      final ProductScanResult result = parseProductScan(
        '{"productName":"","unit":"","priceMajor":null,"confidence":0,"notes":"Not a product label"}',
      );
      expect(result.isEmpty, isTrue);
      expect(result.notes, 'Not a product label');
    });

    test('rejects a reply that is not JSON', () {
      expect(
        () => parseProductScan('I cannot read this photo.'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('full-HD compression', () {
    test('scales the longest side to 1920 without distortion', () {
      final img.Image source = img.Image(width: 3000, height: 2000);
      final Uint8List jpeg = Uint8List.fromList(img.encodeJpg(source));

      final Uint8List compressed = compressImageBytes(jpeg);
      final img.Image? result = img.decodeJpg(compressed);

      expect(result, isNotNull);
      expect(result!.width, 1920);
      expect(result.height, 1280);
    });

    test('does not upscale a small photo', () {
      final img.Image source = img.Image(width: 800, height: 600);
      final Uint8List jpeg = Uint8List.fromList(img.encodeJpg(source));

      final img.Image? result = img.decodeJpg(compressImageBytes(jpeg));

      expect(result, isNotNull);
      expect(result!.width, 800);
      expect(result.height, 600);
    });
  });
}
