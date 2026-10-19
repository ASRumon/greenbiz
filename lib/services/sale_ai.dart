import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/api_client.dart';
import '../core/money.dart';
import '../core/quantity_input.dart';
import '../models/product.dart';
import '../models/sale.dart';

/// Which AI provider the shop owner supplied a key for.
///
/// The key never reaches the GreenBiz Worker: the request goes from this device
/// straight to the provider. That is the whole point of letting the user bring
/// their own key — the server holds no AI credentials for the Sell flow.
enum AiProvider {
  gemini(
    label: 'Google Gemini',
    defaultModel: 'gemini-2.5-flash',
    keyHint: 'AIza…',
    host: 'generativelanguage.googleapis.com',
  ),
  openRouter(
    label: 'OpenRouter',
    defaultModel: 'openrouter/auto',
    keyHint: 'sk-or-…',
    host: 'openrouter.ai',
  );

  const AiProvider({
    required this.label,
    required this.defaultModel,
    required this.keyHint,
    required this.host,
  });

  final String label;
  final String defaultModel;
  final String keyHint;
  final String host;

  static AiProvider fromStorage(String? value) =>
      value == 'openrouter' ? AiProvider.openRouter : AiProvider.gemini;

  String get storageValue =>
      this == AiProvider.openRouter ? 'openrouter' : 'gemini';
}

/// What the user configured on the Profile tab.
class AiSettings {
  const AiSettings({
    this.provider = AiProvider.gemini,
    this.model = '',
    this.apiKey = '',
  });

  final AiProvider provider;

  /// Empty means "use the provider's default model".
  final String model;
  final String apiKey;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  String get effectiveModel =>
      model.trim().isEmpty ? provider.defaultModel : model.trim();

  AiSettings copyWith({AiProvider? provider, String? model, String? apiKey}) =>
      AiSettings(
        provider: provider ?? this.provider,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );
}

/* -------------------------------------------------------------------------- */
/* Wire types between the two AI passes                                        */
/* -------------------------------------------------------------------------- */

/// One requested line from pass 1: "3 kg rice" or "30 taka onion".
class SaleIntent {
  const SaleIntent({
    required this.query,
    this.quantity,
    this.unit,
    this.amountMinor,
  });

  final String query;
  final double? quantity;
  final String? unit;

  /// Money the customer wants to spend on this line, in minor units.
  ///
  /// "30 taka onion" gives 3000. The quantity is then worked out from the
  /// product's price; the amount is never treated as a quantity.
  final int? amountMinor;

  bool get isAmountBased => (amountMinor ?? 0) > 0;
}

/// One product the model selected in pass 2.
class SaleMatch {
  const SaleMatch({
    required this.query,
    required this.productId,
    required this.quantity,
    required this.confidence,
  });

  final String query;
  final String productId;

  /// The final quantity the AI worked out, including amount-based lines.
  final double quantity;
  final double confidence;
}

class ParsedSaleMatches {
  const ParsedSaleMatches({required this.matches, required this.unmatched});

  final List<SaleMatch> matches;
  final List<String> unmatched;
}

/// The final, ready-to-receipt output.
class SaleAiResult {
  const SaleAiResult({required this.lines, required this.unmatched});

  final List<SaleLine> lines;
  final List<String> unmatched;
}

/* -------------------------------------------------------------------------- */
/* Prompts                                                                     */
/* -------------------------------------------------------------------------- */

/// Pass 1: sentence -> search terms.
String buildIntentPrompt(String transcript) =>
    '''
You are the checkout assistant for a small shop.
Split the sentence into one item per product the customer is buying.
Return ONLY a JSON object. No prose, no markdown.

{"items":[{"query":"<the product words>","quantity":<number or null>,"unit":"<unit or null>","amount":<Taka or null>}]}

Rules:
- One array entry per product. Never merge two products into one "query".
- "1 kg rice and two litre milk" means TWO items: rice (quantity 1, unit kg)
  and milk (quantity 2, unit litre).
- "30 taka onion and 20 taka milk" means TWO items: onion (amount 30) and
  milk (amount 20).
- A money amount belongs ONLY to the product it is said with.
  "70 taka onion and a calculator" means onion (amount 70) and calculator
  (amount null, quantity 1). Never copy an amount to another product.
- A product sold by the piece (calculator, bottle, packet) has a fixed price.
  Never use an amount to make a fractional piece of it.
- "amount" is the TOTAL money the customer wants to spend on that item, in
  Taka. "30 taka", "30 tk", "৳30", "30 takar" all mean amount 30.
  Use null when no money was mentioned.
- Never put a money amount in "quantity". "30 taka onion" has quantity null,
  amount 30. Pass 2 computes the weight from the shop's price.
- If both a weight and a total amount are said ("2 kg onion, 120 taka"), keep
  both; pass 2 uses the amount.
- Keep the shopkeeper's own words in "query". Do not translate or invent brands.
- "quantity" must be a number: "a dozen" is 12, "half a kilo" is 0.5, "two" is 2.
- If no quantity was said, use null. Never guess a quantity.
- If nothing is being bought, return {"items":[]}.
- Maximum 20 items.

Sentence: ${jsonEncode(transcript)}
''';

/// Pass 2: sentence + shopping list + inventory candidates -> chosen products.
String buildMatchPrompt({
  required String transcript,
  required List<SaleIntent> intents,
  required Map<String, List<Product>> candidates,
}) {
  final requested = <Map<String, dynamic>>[
    for (final intent in intents)
      <String, dynamic>{
        'query': intent.query,
        'quantity': intent.quantity,
        if (intent.unit != null) 'unit': intent.unit,
        if (intent.amountMinor != null) 'amountMinor': intent.amountMinor,
      },
  ];

  final candidateJson = <String, dynamic>{
    for (final entry in candidates.entries)
      entry.key: <Map<String, dynamic>>[
        for (final product in entry.value)
          <String, dynamic>{
            'productId': product.id,
            'name': product.productName,
            'unit': product.unit,
            'priceMinor': product.unitPriceMinor,
            'stock': product.stockQuantity,
          },
      ],
  };

  return '''
You match a shop's inventory to what a customer is buying.
Return ONLY a JSON object. No prose, no markdown.

{"items":[{"query":"rice","productId":"<id from the candidates for that query, or null>","quantity":3,"confidence":0.0}],"unmatched":["<queries you could not match>"]}

Rules:
- "productId" MUST be one of the ids listed under that query, or null. Never invent an id.
- Return one output item for EVERY entry in "Requested items". Do not omit any.
- If a requested item has a plausible candidate, choose it. Use null only when none is plausible.
- Never merge two requested items into one output item.
- Prefer an exact product over a similar one.
- "amountMinor" is money the customer wants to spend (Taka x 100), not a
  quantity. When it is present, compute the FINAL quantity yourself from the
  chosen product's priceMinor: quantity = amountMinor / priceMinor, rounded to
  at most 3 decimals. The line total (quantity x priceMinor) must round back to
  amountMinor.
- A product sold by the piece, box, packet or bottle must have a whole-number
  quantity. Never return a fraction of one:
  * If the amount buys whole items, return that count.
  * If it buys whole items plus a remainder, return the whole count and add a
    note to "unmatched" such as "calculator: 2 piece = ৳1,600.00, ৳200.00 left
    over".
  * If it cannot buy one whole item, return 1 and add "calculator: sold per
    piece; 1 piece is ৳800.00" to "unmatched".
- Use the requested quantity when no amountMinor is present. If neither exists,
  use 1.
- Never copy an amount from one requested item to another. An amount belongs
  only to the item it was requested with.
- "confidence" is a number from 0 to 1.
- List every query you could not match in "unmatched".
- Do not add products the customer did not mention.

What the customer said: ${jsonEncode(transcript)}

Requested items (JSON):
${jsonEncode(requested)}

Inventory candidates by query (JSON):
${jsonEncode(candidateJson)}
''';
}

/* -------------------------------------------------------------------------- */
/* Pure parsing and local search                                               */
/* -------------------------------------------------------------------------- */

/// Pulls the first JSON object out of a model reply.
///
/// Models occasionally wrap JSON in ``` fences or add a sentence before it even
/// when told not to. Being tolerant here is cheaper than failing a sale.
Map<String, dynamic>? extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  final fence = text.indexOf('```');
  if (fence != -1) {
    text = text.substring(fence + 3);
    if (text.toLowerCase().startsWith('json')) {
      text = text.substring(4);
    }
    final closing = text.indexOf('```');
    if (closing != -1) text = text.substring(0, closing);
  }

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start == -1 || end <= start) return null;

  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

double? _asQuantity(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final text = value.toString().replaceAll(',', '.');
  final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(text);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}

/// A Taka amount ("30", "30.50", "৳30") as minor units.
int? _asAmountMinor(dynamic value) {
  if (value == null) return null;

  final String text = normalizeNumericDigits(value.toString());
  final RegExpMatch? match = RegExp(r'\d+(?:[.,]\d{1,2})?').firstMatch(text);
  if (match == null) return null;

  final minor = parseMajorToMinor(match.group(0)!.replaceAll(',', '.'));
  return (minor == null || minor <= 0) ? null : minor;
}

/// An already-minor-unit amount from the model.
int? _asMinorUnits(dynamic value) {
  if (value == null) return null;
  final int? parsed = value is num
      ? value.round()
      : int.tryParse(value.toString());
  return (parsed == null || parsed <= 0) ? null : parsed;
}

/// Merges lines that ask for the same product more than once.
///
/// Candidate lookup and matching are keyed by the query, so two "onion" lines
/// would otherwise collapse into one and lose an amount. Summing them keeps
/// "30 taka onion and 20 taka onion" as one ৳50 line.
List<SaleIntent> mergeDuplicateIntents(List<SaleIntent> intents) {
  final Map<String, SaleIntent> merged = <String, SaleIntent>{};

  for (final SaleIntent intent in intents) {
    final String key = normalizeForSaleSearch(intent.query);
    if (key.isEmpty) continue;

    final SaleIntent? previous = merged[key];
    if (previous == null) {
      merged[key] = intent;
      continue;
    }

    final double? quantity =
        previous.quantity == null && intent.quantity == null
        ? null
        : (previous.quantity ?? 0) + (intent.quantity ?? 0);
    final int? amountMinor =
        previous.amountMinor == null && intent.amountMinor == null
        ? null
        : (previous.amountMinor ?? 0) + (intent.amountMinor ?? 0);

    merged[key] = SaleIntent(
      query: previous.query,
      quantity: quantity,
      unit: previous.unit ?? intent.unit,
      amountMinor: amountMinor,
    );
  }

  return merged.values.toList(growable: false);
}

/// Parses pass 1. Never throws: a malformed reply becomes an empty list.
List<SaleIntent> parseSaleIntents(String raw) {
  final json = extractJsonObject(raw);
  if (json == null) return const <SaleIntent>[];

  final rawItems = json['items'] ?? json['products'] ?? json['queries'];
  if (rawItems is! List) return const <SaleIntent>[];

  final intents = <SaleIntent>[];
  for (final entry in rawItems) {
    String? query;
    double? quantity;
    String? unit;
    int? amountMinor;

    if (entry is String) {
      query = entry;
    } else if (entry is Map) {
      final map = Map<String, dynamic>.from(entry);
      query =
          (map['query'] ??
                  map['term'] ??
                  map['name'] ??
                  map['product'] ??
                  map['item'])
              ?.toString();
      quantity = _asQuantity(map['quantity'] ?? map['qty']);
      unit = (map['unit'] ?? map['uom'])?.toString();
      amountMinor =
          _asMinorUnits(map['amountMinor']) ??
          _asAmountMinor(map['amount'] ?? map['amountTaka'] ?? map['taka']);
    }

    final trimmed = query?.trim();
    if (trimmed == null || trimmed.isEmpty) continue;
    if (quantity != null && quantity <= 0) quantity = null;

    intents.add(
      SaleIntent(
        query: trimmed,
        quantity: quantity,
        unit: unit,
        amountMinor: amountMinor,
      ),
    );
    if (intents.length >= 20) break;
  }
  return intents;
}

/* -------------------------------------------------------------------------- */
/* Compound-sentence fallback                                                  */
/* -------------------------------------------------------------------------- */

const Map<String, double> _wordNumbers = <String, double>{
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'half': 0.5,
  'dozen': 12,
};

const Set<String> _unitWords = <String>{
  'kg',
  'g',
  'gram',
  'grams',
  'kilogram',
  'kilograms',
  'litre',
  'liter',
  'litres',
  'liters',
  'ml',
  'piece',
  'pieces',
  'pc',
  'pcs',
  'packet',
  'packets',
  'pack',
  'dozen',
  'bag',
  'bags',
  'box',
  'boxes',
  'bottle',
  'bottles',
};

/// Splits "1 kg rice and two litre milk" when the model returned it as one
/// item. A reply that already contains two items is left untouched.
List<SaleIntent> expandCompoundIntents(List<SaleIntent> intents) {
  if (intents.length != 1) return intents;

  final SaleIntent source = intents.single;
  final List<String> parts = _splitIntoSaleParts(source.query);
  if (parts.length < 2) return intents;

  final List<SaleIntent> expanded = <SaleIntent>[];
  for (final String part in parts) {
    final SaleIntent intent = _intentFromPart(part, source.unit);
    if (intent.query.trim().isNotEmpty) expanded.add(intent);
  }
  return expanded.length > 1 ? expanded : intents;
}

List<String> _splitIntoSaleParts(String text) {
  final List<String> raw = text
      .split(RegExp(r'\s+(?:and|plus|&|ar)\s+|[,;]', caseSensitive: false))
      .map((String part) => part.trim())
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  if (raw.length < 2) return const <String>[];

  final List<String> merged = <String>[];
  for (final String part in raw) {
    if (merged.isNotEmpty && _isQuantityOnly(part)) {
      merged[merged.length - 1] = '${merged.last} $part';
    } else {
      merged.add(part);
    }
  }
  return merged.length > 1 ? merged : const <String>[];
}

bool _isQuantityOnly(String part) {
  final List<String> tokens = normalizeForSaleSearch(part)
      .split(' ')
      .where((String token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return false;

  return tokens.every(
    (String token) =>
        RegExp(r'^\d+(?:[.]\d+)?[a-z]*$').hasMatch(token) ||
        _unitWords.contains(token) ||
        token == 'of',
  );
}

SaleIntent _intentFromPart(String part, String? fallbackUnit) {
  final List<String> tokens = part
      .split(RegExp(r'\s+'))
      .where((String token) => token.isNotEmpty)
      .toList(growable: false);

  double? quantity;
  String? unit;
  var index = 0;

  if (tokens.isNotEmpty) {
    final String first = tokens.first.toLowerCase();
    final double? wordNumber = _wordNumbers[first];
    final RegExpMatch? numeric = RegExp(r'^(\d+(?:[.]\d+)?)([a-zA-Z]+)?$')
        .firstMatch(first);

    if (wordNumber != null) {
      quantity = wordNumber;
      index = 1;
    } else if (numeric != null) {
      quantity = double.tryParse(numeric.group(1)!);
      final String? suffix = numeric.group(2);
      if (suffix != null && suffix.isNotEmpty) unit = suffix.toLowerCase();
      index = 1;
    }
  }

  // "half a kilo" -> skip the article before the unit.
  if (index < tokens.length) {
    final String next = tokens[index].toLowerCase();
    if (next == 'a' || next == 'an') index++;
  }
  if (index < tokens.length) {
    final String next = tokens[index].toLowerCase();
    if (_unitWords.contains(next)) {
      unit ??= next;
      index++;
    }
  }
  if (index < tokens.length && tokens[index].toLowerCase() == 'of') index++;

  final String query = tokens.skip(index).join(' ').trim();
  return SaleIntent(
    query: query.isEmpty ? part : query,
    quantity: quantity,
    unit: unit ?? fallbackUnit,
  );
}

/// A strong, unambiguous lexical match, used only when the model omitted a
/// requested item. Weak matches are left to the model so the app does not
/// invent a product.
Product? _bestLocalMatch(List<Product> products, String query) {
  final List<({Product product, double score})> scored =
      <({Product product, double score})>[];
  for (final Product product in products) {
    final double score = _scoreProduct(product, query);
    if (score > 0) scored.add((product: product, score: score));
  }
  if (scored.isEmpty) return null;

  scored.sort((a, b) => b.score.compareTo(a.score));
  final double top = scored.first.score;
  final double second = scored.length > 1 ? scored[1].score : 0;

  if (top >= 60 || (top >= 20 && top > second * 1.5)) {
    return scored.first.product;
  }
  return null;
}

/// Parses pass 2. Any product id not in [candidates] is discarded, so a model
/// cannot invent an id and cause an unintended stock write.
ParsedSaleMatches parseSaleMatches(
  String raw, {
  required Map<String, List<Product>> candidates,
}) {
  final allowed = <String, Product>{
    for (final list in candidates.values)
      for (final product in list) product.id: product,
  };

  final json = extractJsonObject(raw);
  if (json == null) {
    return ParsedSaleMatches(
      matches: const <SaleMatch>[],
      unmatched: candidates.keys.toList(growable: false),
    );
  }

  final rawItems = json['items'] ?? json['matches'];
  final byProduct = <String, SaleMatch>{};

  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = (map['productId'] ?? map['product_id'] ?? map['id'])
          ?.toString();
      if (id == null || !allowed.containsKey(id)) continue;

      final quantity = _asQuantity(map['quantity'] ?? map['qty']) ?? 1;
      if (quantity <= 0) continue;

      final confidence = (_asQuantity(map['confidence']) ?? 1).clamp(0, 1);
      var query = (map['query'] ?? map['term'] ?? allowed[id]!.productName)
          .toString()
          .trim();
      if (query.isEmpty) query = allowed[id]!.productName;

      final previous = byProduct[id];
      byProduct[id] = SaleMatch(
        productId: id,
        query: query,
        quantity: (previous?.quantity ?? 0) + quantity,
        confidence: confidence.toDouble(),
      );
    }
  }

  final unmatched = <String>{};
  final rawUnmatched = json['unmatched'] ?? json['unmatchedQueries'];
  if (rawUnmatched is List) {
    for (final entry in rawUnmatched) {
      final text = entry is Map
          ? (entry['query'] ?? entry['term'] ?? entry['name'])
          : entry;
      final trimmed = text?.toString().trim();
      if (trimmed != null && trimmed.isNotEmpty) unmatched.add(trimmed);
    }
  }

  // A null productId is the model's other way of saying "no match".
  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      if (map['productId'] != null) continue;
      final query = (map['query'] ?? map['term'])?.toString().trim();
      if (query != null && query.isNotEmpty) unmatched.add(query);
    }
  }

  return ParsedSaleMatches(
    matches: byProduct.values.toList(growable: false),
    unmatched: unmatched.toList(growable: false),
  );
}

/// Lowercases and strips punctuation, keeping letters and digits from Latin,
/// Bengali and Devanagari so local names still tokenize.
String normalizeForSaleSearch(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0980-\u09FF\u0900-\u097F\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

double _scoreProduct(Product product, String query) {
  final name = normalizeForSaleSearch(product.productName);
  final unit = normalizeForSaleSearch(product.unit);
  final wanted = normalizeForSaleSearch(query);
  if (wanted.isEmpty) return 0;

  if (name == wanted) return 100;

  final tokens = wanted.split(' ').where((token) => token.isNotEmpty).toList();
  final words = name.split(' ').where((word) => word.isNotEmpty).toSet();

  var score = name.contains(wanted) ? 60.0 : 0.0;
  var matched = 0;

  for (final token in tokens) {
    if (words.contains(token)) {
      score += 14;
      matched++;
    } else if (name.contains(token)) {
      score += 7;
      matched++;
    } else if (unit.contains(token)) {
      score += 2;
    }
  }

  if (matched == tokens.length && matched > 0) score += 10;
  return score;
}

double _bigramSimilarity(String a, String b) {
  final left = a.replaceAll(' ', '');
  final right = b.replaceAll(' ', '');
  if (left.length < 2 || right.length < 2) return 0;

  final counts = <String, int>{};
  for (var i = 0; i < left.length - 1; i++) {
    final gram = left.substring(i, i + 2);
    counts[gram] = (counts[gram] ?? 0) + 1;
  }

  var overlap = 0;
  for (var i = 0; i < right.length - 1; i++) {
    final gram = right.substring(i, i + 2);
    final available = counts[gram] ?? 0;
    if (available > 0) {
      overlap++;
      counts[gram] = available - 1;
    }
  }

  final total = (left.length - 1) + (right.length - 1);
  return total == 0 ? 0 : (2 * overlap) / total;
}

/// Local lexical search: the shopkeeper's words against product names.
///
/// This is the "search terms in the inventory" step. When a term has no
/// lexical match at all, a handful of the closest names are still offered to
/// the model, which is what lets it resolve a synonym or a local word.
Map<String, List<Product>> searchSaleCandidates(
  List<Product> products,
  List<SaleIntent> intents, {
  int limit = 8,
  int fallback = 12,
}) {
  final result = <String, List<Product>>{};

  for (final intent in intents) {
    final scored = <({Product product, double score})>[];
    for (final product in products) {
      final score = _scoreProduct(product, intent.query);
      if (score > 0) scored.add((product: product, score: score));
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0
          ? byScore
          : a.product.productName.compareTo(b.product.productName);
    });

    var picked = scored.take(limit).map((entry) => entry.product).toList();

    if (picked.isEmpty) {
      final ranked = <({Product product, double score})>[
        for (final product in products)
          (
            product: product,
            score: _bigramSimilarity(
              normalizeForSaleSearch(product.productName),
              normalizeForSaleSearch(intent.query),
            ),
          ),
      ]..sort((a, b) => b.score.compareTo(a.score));

      picked = ranked.take(fallback).map((entry) => entry.product).toList();
    }

    result[intent.query] = picked;
  }

  return result;
}

/// Only Gemini 2.5 Flash/Lite accept `thinkingBudget: 0`. Other models either
/// do not know the field or require a minimum thinking budget, and would reject
/// the whole request.
bool _supportsThinkingBudget(String model) =>
    model.contains('2.5') &&
    (model.contains('flash') || model.contains('lite'));

/* -------------------------------------------------------------------------- */
/* The service                                                                 */
/* -------------------------------------------------------------------------- */

/// Runs the two-pass, bring-your-own-key pipeline.
///
///   1. transcript -> search terms (AI)
///   2. terms -> local inventory search (this app)
///   3. transcript + terms + candidates -> final product ids (AI)
class SaleAiService {
  SaleAiService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;

  Future<SaleAiResult> interpret({
    required String transcript,
    required List<Product> products,
    required AiSettings settings,
  }) async {
    final intents = await extractIntents(transcript, settings: settings);

    if (intents.isEmpty) {
      return const SaleAiResult(lines: <SaleLine>[], unmatched: <String>[]);
    }

    final candidates = searchSaleCandidates(products, intents);
    final parsed = await matchItems(
      transcript: transcript,
      intents: intents,
      candidates: candidates,
      settings: settings,
    );

    final byId = <String, Product>{
      for (final product in products) product.id: product,
    };

    final lines = <SaleLine>[];
    final unmatched = <String>{...parsed.unmatched};

    for (final match in parsed.matches) {
      final product = byId[match.productId];
      if (product == null) {
        unmatched.add(match.query);
        continue;
      }
      if (product.stockQuantity <= 0) {
        unmatched.add('${match.query}: out of stock');
        continue;
      }

      // The AI already turned "30 taka onion" into the right quantity (and
      // kept piece-based products whole). Use its number as-is; the app only
      // enforces stock.
      final double quantity = match.quantity;

      if (quantity > product.stockQuantity) {
        // Sell what is actually on the shelf, and say so rather than silently
        // recording a negative stock level.
        lines.add(SaleLine(product: product, quantity: product.stockQuantity));
        unmatched.add(
          '${match.query}: only ${product.stockLabel} ${product.unit} left',
        );
      } else {
        lines.add(SaleLine(product: product, quantity: quantity));
      }
    }

    // Safety net: a model occasionally returns only the first line of a
    // multi-item request, or drops one while listing the others. If the omitted
    // item has a strong, unambiguous lexical match in the inventory, add it
    // rather than losing the sale line. Weak matches are still left to the
    // model, so the app never invents a product.
    final Set<String> answeredByModel = <String>{
      for (final SaleMatch match in parsed.matches)
        normalizeForSaleSearch(match.query),
    };

    for (final intent in intents) {
      final String wanted = normalizeForSaleSearch(intent.query);
      final bool matchedLocally = lines.any(
        (line) => _scoreProduct(line.product, intent.query) > 0,
      );
      final bool answered = answeredByModel.any(
        (query) =>
            query == wanted || query.contains(wanted) || wanted.contains(query),
      );
      if (matchedLocally || answered) continue;

      final Product? fallback = _bestLocalMatch(products, intent.query);
      if (fallback == null) {
        unmatched.add(intent.query);
        continue;
      }
      if (lines.any((line) => line.product.id == fallback.id)) continue;
      if (fallback.stockQuantity <= 0) {
        unmatched.add('${intent.query}: out of stock');
        continue;
      }

      // An amount-based line needs the AI's arithmetic (and its whole-piece
      // decision). If pass 2 dropped it, ask the owner to retry rather than
      // guessing a quantity here.
      if (intent.isAmountBased) {
        unmatched.add('${intent.query}: the AI did not match this item');
        continue;
      }

      final double quantity = intent.quantity ?? 1;
      if (quantity > fallback.stockQuantity) {
        lines.add(
          SaleLine(product: fallback, quantity: fallback.stockQuantity),
        );
        unmatched.add(
          '${intent.query}: only ${fallback.stockLabel} ${fallback.unit} left',
        );
      } else {
        lines.add(SaleLine(product: fallback, quantity: quantity));
      }
      unmatched.remove(intent.query);
    }

    return SaleAiResult(
      lines: lines,
      unmatched: unmatched.toList(growable: false),
    );
  }

  /// Pass 1.
  Future<List<SaleIntent>> extractIntents(
    String transcript, {
    required AiSettings settings,
  }) async {
    final raw = await _complete(
      settings: settings,
      system: 'You turn a shopkeeper\'s sentence into a shopping list. Reply with JSON only.',
      user: buildIntentPrompt(transcript),
    );

    final json = extractJsonObject(raw);
    if (json == null) {
      throw ApiException(
        code: 'AI_BAD_RESPONSE',
        message:
            'The AI reply was not usable JSON. Try again, or switch model in '
            'Profile.',
      );
    }

    return mergeDuplicateIntents(expandCompoundIntents(parseSaleIntents(raw)));
  }

  /// Pass 2.
  Future<ParsedSaleMatches> matchItems({
    required String transcript,
    required List<SaleIntent> intents,
    required Map<String, List<Product>> candidates,
    required AiSettings settings,
  }) async {
    final raw = await _complete(
      settings: settings,
      system: 'You match shopping-list items to a shop\'s inventory. Reply with JSON only.',
      user: buildMatchPrompt(
        transcript: transcript,
        intents: intents,
        candidates: candidates,
      ),
    );

    if (extractJsonObject(raw) == null) {
      throw ApiException(
        code: 'AI_BAD_RESPONSE',
        message:
            'The AI reply was not usable JSON. Try again, or switch model in '
            'Profile.',
      );
    }
    return parseSaleMatches(raw, candidates: candidates);
  }

  Future<String> _complete({
    required AiSettings settings,
    required String system,
    required String user,
  }) async {
    if (!settings.isConfigured) {
      throw ApiException(
        code: 'AI_KEY_MISSING',
        message:
            'Add your own AI API key in Profile before using the voice sell '
            'assistant.',
      );
    }

    try {
      return settings.provider == AiProvider.gemini
          ? await _askGemini(settings, user)
          : await _askOpenRouter(settings, system, user);
    } on DioException catch (error) {
      throw _fromDio(error, settings.provider);
    }
  }

  Future<String> _askGemini(AiSettings settings, String prompt) async {
    // Accept both "gemini-2.5-flash" and a pasted "models/gemini-2.5-flash".
    final String model = settings.effectiveModel.replaceFirst(
      RegExp(r'^models/'),
      '',
    );

    final response = await _dio.post<dynamic>(
      'https://${AiProvider.gemini.host}/v1beta/models/$model:generateContent',
      options: Options(
        headers: <String, dynamic>{
          // Header rather than ?key= so the key cannot end up in a URL log.
          'x-goog-api-key': settings.apiKey.trim(),
        },
      ),
      data: <String, dynamic>{
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'text': prompt},
            ],
          },
        ],
        'generationConfig': <String, dynamic>{
          'temperature': 0.1,
          'responseMimeType': 'application/json',
          // Thinking tokens share this budget. A low cap let Gemini Flash spend
          // most of it on reasoning and truncate the JSON mid-object.
          'maxOutputTokens': 8192,
          if (_supportsThinkingBudget(model))
            'thinkingConfig': <String, dynamic>{'thinkingBudget': 0},
        },
      },
    );

    final body = _asMap(response.data);
    final candidates = body['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final candidate = _asMap(candidates.first);
      if (candidate['finishReason']?.toString() == 'MAX_TOKENS') {
        throw ApiException(
          code: 'AI_TRUNCATED',
          message:
              'The AI reply hit its output limit and was cut off. Try again.',
        );
      }

      final content = _asMap(candidate['content']);
      final parts = content['parts'];
      if (parts is List && parts.isNotEmpty) {
        final text = parts
            .whereType<Map>()
            .map((part) => part['text']?.toString() ?? '')
            .join();
        if (text.trim().isNotEmpty) return text;
      }
    }

    throw ApiException(
      code: 'AI_BAD_RESPONSE',
      message: 'Gemini returned an empty reply. Try again.',
    );
  }

  Future<String> _askOpenRouter(
    AiSettings settings,
    String system,
    String user,
  ) async {
    final response = await _dio.post<dynamic>(
      'https://${AiProvider.openRouter.host}/api/v1/chat/completions',
      options: Options(
        headers: <String, dynamic>{
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
          // OpenRouter uses these for attribution only.
          'X-Title': 'GreenBiz',
        },
      ),
      data: <String, dynamic>{
        'model': settings.effectiveModel,
        'temperature': 0.1,
        // Same reasoning as the Gemini budget: a short JSON answer should never
        // be the thing that runs into the ceiling.
        'max_tokens': 4096,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': system},
          <String, dynamic>{'role': 'user', 'content': user},
        ],
      },
    );

    final body = _asMap(response.data);
    final choices = body['choices'];
    if (choices is List && choices.isNotEmpty) {
      final choice = _asMap(choices.first);
      if (choice['finish_reason']?.toString() == 'length') {
        throw ApiException(
          code: 'AI_TRUNCATED',
          message:
              'The AI reply hit its output limit and was cut off. Try again.',
        );
      }

      final message = _asMap(choice['message']);
      final content = message['content']?.toString() ?? '';
      if (content.trim().isNotEmpty) return content;
    }

    throw ApiException(
      code: 'AI_BAD_RESPONSE',
      message: 'OpenRouter returned an empty reply. Try again.',
    );
  }

  ApiException _fromDio(DioException error, AiProvider provider) {
    final response = error.response;
    if (response == null) {
      return ApiException(
        code: 'NETWORK_ERROR',
        message:
            'Cannot reach ${provider.host}. Check your internet connection.',
      );
    }

    final status = response.statusCode;
    final detail = _providerMessage(response.data);

    if (status == 401 || status == 403) {
      return ApiException(
        code: 'AI_KEY_INVALID',
        message:
            '${provider.label} rejected that API key. Check it in Profile.',
        statusCode: status,
      );
    }
    if (status == 429) {
      return ApiException(
        code: 'AI_RATE_LIMIT',
        message:
            '${provider.label} is rate-limiting this key. Wait a moment and '
            'try again.',
        statusCode: status,
      );
    }
    if (status == 400 || status == 404) {
      return ApiException(
        code: 'AI_BAD_REQUEST',
        message:
            detail ??
            '${provider.label} rejected the request. Check the model name in '
                'Profile.',
        statusCode: status,
      );
    }

    return ApiException(
      code: 'AI_UNAVAILABLE',
      message:
          '${provider.label} is not available right now. Try again shortly.',
      statusCode: status,
    );
  }

  String? _providerMessage(dynamic data) {
    final body = _asMap(data);
    final error = body['error'];
    if (error is Map) {
      final message = error['message']?.toString();
      if (message != null && message.trim().isNotEmpty) return message;
    }
    if (error is String && error.trim().isNotEmpty) return error;
    return null;
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
