import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/models/product.dart';
import 'package:greenbiz/models/sale.dart';
import 'package:greenbiz/services/sale_ai.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final Map<String, dynamic> Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Product _product(
  String id,
  String name, {
  int priceMinor = 10000,
  double stock = 10,
  String unit = 'kg',
}) => Product(
  id: id,
  shopId: 'shop-1',
  productName: name,
  unit: unit,
  unitPriceMinor: priceMinor,
  stockQuantity: stock,
);

void main() {
  group('extractJsonObject', () {
    test('reads plain JSON', () {
      expect(extractJsonObject('{"items":[]}'), <String, dynamic>{
        'items': <dynamic>[],
      });
    });

    test('strips markdown fences and surrounding prose', () {
      final Map<String, dynamic>? json = extractJsonObject(
        'Here you go:\n```json\n{"items":[{"query":"rice"}]}\n```\nThanks',
      );
      expect(json, isNotNull);
      expect((json!['items'] as List).length, 1);
    });

    test('returns null for prose with no object', () {
      expect(extractJsonObject('I could not understand that.'), isNull);
    });
  });

  group('parseSaleIntents', () {
    test('reads queries and numeric quantities', () {
      final List<SaleIntent> intents = parseSaleIntents('''
{"items":[
  {"query":"rice","quantity":3,"unit":"kg"},
  {"query":"notebook","quantity":"2"},
  {"query":"onion","quantity":null}
]}
''');

      expect(intents.length, 3);
      expect(intents[0].query, 'rice');
      expect(intents[0].quantity, 3);
      expect(intents[0].unit, 'kg');
      expect(intents[1].quantity, 2);
      expect(intents[2].quantity, isNull);
    });

    test('accepts a plain list of strings and drops blanks', () {
      final List<SaleIntent> intents = parseSaleIntents(
        '{"items":["rice","  ",null]}',
      );
      expect(intents.map((SaleIntent i) => i.query), <String>['rice']);
    });

    test('ignores quantities that are zero or negative', () {
      final List<SaleIntent> intents = parseSaleIntents(
        '{"items":[{"query":"rice","quantity":-2}]}',
      );
      expect(intents.single.quantity, isNull);
    });

    test('returns an empty list for an unusable reply', () {
      expect(parseSaleIntents('nonsense'), isEmpty);
    });
  });

  group('parseSaleMatches', () {
    final Product rice = _product('p-rice', 'Rice');
    final Product ricePremium = _product('p-rice-premium', 'Premium Rice');
    final Map<String, List<Product>> candidates = <String, List<Product>>{
      'rice': <Product>[rice, ricePremium],
    };

    test('keeps only ids that exist in the candidate pool', () {
      final ParsedSaleMatches parsed = parseSaleMatches('''
{"items":[
  {"query":"rice","productId":"p-rice","quantity":3},
  {"query":"rice","productId":"made-up-id","quantity":9}
]}
''', candidates: candidates);

      expect(parsed.matches.length, 1);
      expect(parsed.matches.single.productId, 'p-rice');
      expect(parsed.matches.single.quantity, 3);
    });

    test('defaults a missing quantity to 1', () {
      final ParsedSaleMatches parsed = parseSaleMatches(
        '{"items":[{"productId":"p-rice","quantity":null}]}',
        candidates: candidates,
      );
      expect(parsed.matches.single.quantity, 1);
    });

    test('merges duplicate lines for the same product', () {
      final ParsedSaleMatches parsed = parseSaleMatches('''
{"items":[
  {"productId":"p-rice","quantity":2},
  {"productId":"p-rice","quantity":1.5}
]}
''', candidates: candidates);
      expect(parsed.matches.single.quantity, 3.5);
    });

    test('collects unmatched queries, including null product ids', () {
      final ParsedSaleMatches parsed = parseSaleMatches('''
{"items":[
  {"query":"sugar","productId":null},
  {"query":"salt","productId":null}
],"unmatched":["salt"]}
''', candidates: candidates);

      expect(parsed.matches, isEmpty);
      expect(parsed.unmatched, containsAll(<String>['sugar', 'salt']));
    });

    test('treats an unparseable reply as no matches', () {
      final ParsedSaleMatches parsed = parseSaleMatches(
        'sorry',
        candidates: candidates,
      );
      expect(parsed.matches, isEmpty);
      expect(parsed.unmatched, <String>['rice']);
    });
  });

  group('searchSaleCandidates', () {
    final List<Product> products = <Product>[
      _product('1', 'Aromatic Rice 5kg', priceMinor: 65000, stock: 12),
      _product('2', 'Miniket Rice', priceMinor: 70000, stock: 8),
      _product('3', 'Notebook', priceMinor: 4500, stock: 40, unit: 'piece'),
      _product('4', 'Onion', priceMinor: 3500, stock: 20),
    ];

    test('ranks a name match above unrelated products', () {
      final Map<String, List<Product>> result = searchSaleCandidates(
        products,
        <SaleIntent>[const SaleIntent(query: 'rice', quantity: 3)],
      );

      final List<Product> rice = result['rice']!;
      expect(rice.first.productName, contains('Rice'));
      expect(rice.map((Product p) => p.id), isNot(contains('3')));
    });

    test('matches a token in any position and respects the limit', () {
      final Map<String, List<Product>> result = searchSaleCandidates(
        products,
        <SaleIntent>[const SaleIntent(query: 'notebook')],
        limit: 1,
      );

      expect(result['notebook'], hasLength(1));
      expect(result['notebook']!.single.productName, 'Notebook');
    });

    test('falls back to closest names when nothing matches lexically', () {
      final Map<String, List<Product>> result = searchSaleCandidates(
        products,
        <SaleIntent>[const SaleIntent(query: 'chal')],
      );

      // "chal" is the local word for rice and shares no characters with the
      // English names, so the fallback must still offer the catalogue to the
      // model instead of returning an empty list.
      expect(result['chal'], isNotEmpty);
      expect(result['chal']!.length, lessThanOrEqualTo(12));
    });
  });

  group('compound sale sentences', () {
    test('splits a single merged query into one item per product', () {
      final List<SaleIntent> intents = expandCompoundIntents(<SaleIntent>[
        const SaleIntent(query: '1KG rice and two litre milk'),
      ]);

      expect(intents.length, 2);
      expect(intents[0].query, 'rice');
      expect(intents[0].quantity, 1);
      expect(intents[0].unit, 'kg');
      expect(intents[1].query, 'milk');
      expect(intents[1].quantity, 2);
      expect(intents[1].unit, 'litre');
    });

    test('splits a comma-separated sentence', () {
      final List<SaleIntent> intents = expandCompoundIntents(<SaleIntent>[
        const SaleIntent(query: 'rice, two notebooks'),
      ]);

      expect(intents.map((SaleIntent i) => i.query), <String>[
        'rice',
        'notebooks',
      ]);
      expect(intents[1].quantity, 2);
    });

    test('leaves a single product untouched', () {
      final List<SaleIntent> intents = expandCompoundIntents(<SaleIntent>[
        const SaleIntent(query: 'rice', quantity: 3),
      ]);

      expect(intents.length, 1);
      expect(intents.single.query, 'rice');
    });

    test('leaves an already-split response untouched', () {
      final List<SaleIntent> intents = expandCompoundIntents(<SaleIntent>[
        const SaleIntent(query: 'rice', quantity: 1, unit: 'kg'),
        const SaleIntent(query: 'milk', quantity: 2, unit: 'litre'),
      ]);

      expect(intents.length, 2);
    });

    test('recovers an item the model dropped in pass 2', () async {
      var calls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((RequestOptions options) {
        calls++;
        final String sent = jsonEncode(options.data);
        final bool isMatchPass = sent.contains('Requested items');

        final Map<String, dynamic> payload = isMatchPass
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'query': 'milk',
                    'productId': 'p-milk',
                    'quantity': 2,
                    'confidence': 0.9,
                  },
                ],
                'unmatched': <String>[],
              }
            : <String, dynamic>{
                // The model failed to split the sentence into two items.
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'query': 'rice and two litre milk',
                    'quantity': null,
                    'unit': null,
                  },
                ],
              };

        return <String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'parts': <Map<String, dynamic>>[
                  <String, dynamic>{'text': jsonEncode(payload)},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        };
      });

      final SaleAiService service = SaleAiService(dio: dio);
      final SaleAiResult result = await service.interpret(
        transcript: 'rice and two litre milk',
        products: <Product>[
          _product('p-rice', 'Rice', stock: 5),
          _product('p-milk', 'Milk', stock: 5, unit: 'litre'),
        ],
        settings: const AiSettings(apiKey: 'test-key'),
      );

      expect(calls, 2);
      expect(
        result.lines.map((SaleLine line) => line.product.id),
        containsAll(<String>['p-rice', 'p-milk']),
      );
      expect(
        result.lines
            .firstWhere((SaleLine line) => line.product.id == 'p-rice')
            .quantity,
        1,
      );
    });
  });

  group('amount-based sales', () {
    test('both prompts make the AI responsible for amounts', () {
      final String intents = buildIntentPrompt('30 taka onion');
      expect(intents, contains('Never put a money amount in "quantity"'));
      expect(intents, contains('70 taka onion and a calculator'));
      expect(intents, contains('Pass 2 computes the weight'));

      final String matching = buildMatchPrompt(
        transcript: '30 taka onion',
        intents: const <SaleIntent>[
          SaleIntent(query: 'onion', amountMinor: 3000),
        ],
        candidates: <String, List<Product>>{
          'onion': <Product>[_product('p-onion', 'Onion')],
        },
      );
      expect(matching, contains('"amountMinor":3000'));
      expect(matching, contains('compute the FINAL quantity yourself'));
      expect(matching, contains('whole-number'));
    });

    test('a pass-1 amount is money, never a quantity', () {
      final List<SaleIntent> intents = parseSaleIntents(
        '{"items":[{"query":"onion","quantity":null,"amount":30}]}',
      );

      expect(intents.single.quantity, isNull);
      expect(intents.single.amountMinor, 3000);
      expect(intents.single.isAmountBased, isTrue);
    });

    test('merges two lines for the same product and sums their money', () {
      final List<SaleIntent> intents = mergeDuplicateIntents(<SaleIntent>[
        const SaleIntent(query: 'onion', amountMinor: 3000),
        const SaleIntent(query: 'Onion', amountMinor: 2000),
      ]);

      expect(intents.length, 1);
      expect(intents.single.amountMinor, 5000);
    });

    test('uses the AI quantity for amount-based lines', () async {
      var calls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((RequestOptions options) {
        calls++;
        final String sent = jsonEncode(options.data);
        final bool isMatchPass = sent.contains('Requested items');

        final Map<String, dynamic> payload = isMatchPass
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'query': 'onion',
                    'productId': 'p-onion',
                    // The AI did the arithmetic: ৳30 ÷ ৳60 per kg.
                    'quantity': 0.5,
                    'confidence': 0.9,
                  },
                  <String, dynamic>{
                    'query': 'milk',
                    'productId': 'p-milk',
                    // ৳20 ÷ ৳50 per litre.
                    'quantity': 0.4,
                    'confidence': 0.9,
                  },
                ],
                'unmatched': <String>[],
              }
            : <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{'query': 'onion', 'amount': 30},
                  <String, dynamic>{'query': 'milk', 'amount': 20},
                ],
              };

        return <String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'parts': <Map<String, dynamic>>[
                  <String, dynamic>{'text': jsonEncode(payload)},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        };
      });

      final SaleAiService service = SaleAiService(dio: dio);
      final SaleAiResult result = await service.interpret(
        transcript: '30 taka onion 20 taka milk',
        products: <Product>[
          _product('p-onion', 'Onion', priceMinor: 6000, stock: 10),
          _product(
            'p-milk',
            'Milk',
            priceMinor: 5000,
            stock: 10,
            unit: 'litre',
          ),
        ],
        settings: const AiSettings(apiKey: 'test-key'),
      );

      expect(calls, 2);

      final SaleLine onion = result.lines.firstWhere(
        (SaleLine line) => line.product.id == 'p-onion',
      );
      expect(onion.quantity, 0.5);
      expect(onion.lineTotalMinor, 3000);

      final SaleLine milk = result.lines.firstWhere(
        (SaleLine line) => line.product.id == 'p-milk',
      );
      expect(milk.quantity, 0.4);
      expect(milk.lineTotalMinor, 2000);
    });

    test('uses the AI whole-piece quantity for a calculator', () async {
      var calls = 0;
      final Dio dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((RequestOptions options) {
        calls++;
        final String sent = jsonEncode(options.data);
        final bool isMatchPass = sent.contains('Requested items');

        final Map<String, dynamic> payload = isMatchPass
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'query': 'onion',
                    'productId': 'p-onion',
                    'quantity': 70 / 60,
                    'confidence': 0.9,
                  },
                  <String, dynamic>{
                    'query': 'calculator',
                    'productId': 'p-calc',
                    'quantity': 1,
                    'confidence': 0.9,
                  },
                ],
                'unmatched': <String>[],
              }
            : <String, dynamic>{
                // The prompt requires the calculator to have no amount.
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{'query': 'onion', 'amount': 70},
                  <String, dynamic>{'query': 'calculator'},
                ],
              };

        return <String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'parts': <Map<String, dynamic>>[
                  <String, dynamic>{'text': jsonEncode(payload)},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        };
      });

      final SaleAiService service = SaleAiService(dio: dio);
      final SaleAiResult result = await service.interpret(
        transcript: '70 taka onion and calculator',
        products: <Product>[
          _product('p-onion', 'Onion', priceMinor: 6000, stock: 10),
          _product(
            'p-calc',
            'Calculator',
            priceMinor: 80000,
            stock: 5,
            unit: 'piece',
          ),
        ],
        settings: const AiSettings(apiKey: 'test-key'),
      );

      expect(calls, 2);

      final SaleLine onion = result.lines.firstWhere(
        (SaleLine line) => line.product.id == 'p-onion',
      );
      expect(onion.quantity, closeTo(70 / 60, 1e-9));
      expect(onion.lineTotalMinor, 7000);

      final SaleLine calculator = result.lines.firstWhere(
        (SaleLine line) => line.product.id == 'p-calc',
      );
      expect(calculator.quantity, 1);
      expect(calculator.lineTotalMinor, 80000);
    });
  });

  group('sale money', () {
    test('rounds once, at the line level', () {
      // 19.99 * 2.5 = 49.975 -> 49.98 (4998 minor units).
      final SaleLine line = SaleLine(
        product: _product('1', 'Rice', priceMinor: 1999),
        quantity: 2.5,
      );
      expect(line.lineTotalMinor, 4998);
      expect(line.quantityLabel, '2.5');
    });

    test('formats whole quantities without a decimal point', () {
      expect(formatQuantity(3), '3');
      expect(formatQuantity(2.5), '2.5');
      expect(formatQuantity(0.25), '0.25');
      expect(formatQuantity(0.333333), '0.333');
    });
  });

  group('SaleReceipt', () {
    test('reads the server receipt exactly as recorded', () {
      final SaleReceipt receipt = SaleReceipt.fromJson(<String, dynamic>{
        'transaction': <String, dynamic>{'id': 'tx-1'},
        'totalMinor': 4998,
        'currency': 'BDT',
        'score': 61,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'productId': '1',
            'productName': 'Rice',
            'unit': 'kg',
            'quantity': 2.5,
            'unitPriceMinor': 1999,
            'lineTotalMinor': 4998,
          },
        ],
      });

      expect(receipt.transactionId, 'tx-1');
      expect(receipt.totalMinor, 4998);
      expect(receipt.score, 61);
      expect(receipt.items.single.productName, 'Rice');
      expect(receipt.items.single.quantityLabel, '2.5');
    });
  });
}
