import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/payment_tolerance.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../models/live_sms_payment.dart';
import '../../models/product.dart';
import '../../models/sale.dart';
import '../../services/sale_ai.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import '../finance/finance_controller.dart';
import '../inventory/inventory_controller.dart';
import '../profile/ai_settings_controller.dart';
import 'payment_picker_sheet.dart';
import 'swipe_confirm_bar.dart';

/// Turn inventory into money.
///
/// Two ways to build the same receipt:
///   * tap/search products and set quantities, or
///   * say what the customer bought and let the user's own AI key fill it in.
///
/// Nothing is written until "Confirm sale". Confirmation is a single server
/// call that records one inflow transaction and decrements stock atomically.
class SellScreen extends ConsumerStatefulWidget {
  const SellScreen({super.key, this.livePayment});

  /// Set when the screen was opened from a live "payment received" prompt.
  final LiveSmsPayment? livePayment;

  @override
  ConsumerState<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends ConsumerState<SellScreen> {
  final TextEditingController _transcript = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _customer = TextEditingController();
  final SpeechToText _speech = SpeechToText();

  final List<SaleLine> _lines = <SaleLine>[];
  LiveSmsPayment? _livePayment;

  bool _speechReady = false;
  bool _isListening = false;
  bool _isThinking = false;
  bool _isSaving = false;

  String? _aiMessage;
  List<String> _unmatched = const <String>[];

  @override
  void initState() {
    super.initState();
    _livePayment = widget.livePayment;
    _search.addListener(_onSearchChanged);
    _transcript.addListener(_onTranscriptChanged);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _transcript.removeListener(_onTranscriptChanged);
    if (_speechReady) {
      _speech.cancel();
    }
    _transcript.dispose();
    _search.dispose();
    _customer.dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  void _onTranscriptChanged() => setState(() {});

  /* ------------------------------------------------------------------------ */
  /* Cart                                                                     */
  /* ------------------------------------------------------------------------ */

  int get _totalMinor =>
      _lines.fold(0, (int sum, SaleLine line) => sum + line.lineTotalMinor);

  void _addProduct(Product product) {
    if (product.stockQuantity <= 0) {
      showAppMessage(
        context,
        '${product.productName} is out of stock.',
        isError: true,
      );
      return;
    }

    final int index = _lines.indexWhere(
      (SaleLine line) => line.product.id == product.id,
    );
    final double current = index == -1 ? 0 : _lines[index].quantity;

    if (current + 1 > product.stockQuantity + 1e-9) {
      showAppMessage(
        context,
        'Only ${product.stockLabel} ${product.unit} of '
        '${product.productName} left.',
        isError: true,
      );
      return;
    }

    setState(() {
      if (index == -1) {
        _lines.add(SaleLine(product: product, quantity: 1));
      } else {
        _lines[index] = _lines[index].copyWith(quantity: current + 1);
      }
    });
  }

  void _changeQuantity(SaleLine line, double delta) {
    final double next = line.quantity + delta;
    if (next <= 0) {
      _removeLine(line.product.id);
      return;
    }
    if (next > line.product.stockQuantity + 1e-9) {
      showAppMessage(
        context,
        'Only ${line.product.stockLabel} ${line.product.unit} of '
        '${line.product.productName} left.',
        isError: true,
      );
      return;
    }

    setState(() {
      final int index = _lines.indexWhere(
        (SaleLine existing) => existing.product.id == line.product.id,
      );
      if (index != -1) {
        _lines[index] = line.copyWith(quantity: next);
      }
    });
  }

  void _removeLine(String productId) {
    setState(() {
      _lines.removeWhere((SaleLine line) => line.product.id == productId);
    });
  }

  Future<void> _promptQuantity(SaleLine line) async {
    final TextEditingController controller = TextEditingController(
      text: line.quantityLabel,
    );

    final double? value = await showDialog<double>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(line.product.productName),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: 'Quantity in ${line.product.unit}',
            helperText: 'In stock: ${line.product.stockLabel}',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final double? parsed = double.tryParse(controller.text.trim());
              Navigator.of(dialogContext).pop(parsed);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (!mounted || value == null) return;

    if (value <= 0) {
      _removeLine(line.product.id);
      return;
    }
    if (value > line.product.stockQuantity + 1e-9) {
      showAppMessage(
        context,
        'Only ${line.product.stockLabel} ${line.product.unit} in stock.',
        isError: true,
      );
      return;
    }

    setState(() {
      final int index = _lines.indexWhere(
        (SaleLine existing) => existing.product.id == line.product.id,
      );
      if (index != -1) {
        _lines[index] = line.copyWith(quantity: value);
      }
    });
  }

  Future<void> _clearCart() async {
    if (_lines.isEmpty) return;
    final bool confirmed = await confirmDialog(
      context,
      title: 'Clear this receipt?',
      message: 'The items are removed. Nothing has been sold yet.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _lines.clear();
      _unmatched = const <String>[];
      _aiMessage = null;
    });
  }

  /* ------------------------------------------------------------------------ */
  /* Voice                                                                    */
  /* ------------------------------------------------------------------------ */

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    final PermissionStatus status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (!mounted) return;
      showAppMessage(
        context,
        'Microphone access is needed to dictate a sale. You can also type it.',
        isError: true,
      );
      return;
    }

    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (String status) {
          if (!mounted) return;
          if (status == SpeechToText.doneStatus ||
              status == SpeechToText.notListeningStatus) {
            setState(() => _isListening = false);
          }
        },
        onError: (SpeechRecognitionError error) {
          if (!mounted) return;
          setState(() => _isListening = false);
          if (error.permanent) {
            showAppMessage(
              context,
              'Speech recognition is not available on this device. Type the '
              'sale instead.',
              isError: true,
            );
          }
        },
      );
    }

    if (!_speechReady) {
      if (!mounted) return;
      await _showSpeechUnavailable();
      return;
    }

    if (!mounted) return;
    setState(() => _isListening = true);

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (!mounted) return;
        _transcript.text = result.recognizedWords;
        _transcript.selection = TextSelection.collapsed(
          offset: _transcript.text.length,
        );
        // The whole point of the mic is that the spoken sale goes straight to
        // the assistant. Only fire once, on the final result.
        if (result.finalResult && _transcript.text.trim().isNotEmpty) {
          _runAi();
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _showSpeechUnavailable() => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Voice input is unavailable'),
      content: const Text(
        'This device has no speech recognizer available. Install or enable '
        'the Google app / speech service, or type what the customer bought.',
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  /* ------------------------------------------------------------------------ */
  /* AI                                                                       */
  /* ------------------------------------------------------------------------ */

  Future<void> _runAi() async {
    if (_isThinking || _isSaving) return;

    final String transcript = _transcript.text.trim();
    if (transcript.isEmpty) {
      showAppMessage(
        context,
        'Type or say what the customer bought first.',
        isError: true,
      );
      return;
    }

    AiSettings settings;
    try {
      settings = await ref.read(aiSettingsControllerProvider.future);
    } catch (_) {
      settings = const AiSettings();
    }

    if (!settings.isConfigured) {
      if (!mounted) return;
      await _showKeyHelp();
      return;
    }

    final List<Product> products =
        ref.read(productListProvider).value ?? const <Product>[];
    if (products.isEmpty) {
      if (!mounted) return;
      showAppMessage(
        context,
        'Add products to your inventory before using the AI assistant.',
        isError: true,
      );
      return;
    }

    setState(() {
      _isThinking = true;
      _aiMessage = 'Reading the sale…';
      _unmatched = const <String>[];
    });

    try {
      final SaleAiResult result = await ref
          .read(saleAiServiceProvider)
          .interpret(
            transcript: transcript,
            products: products,
            settings: settings,
          );

      if (!mounted) return;
      setState(() {
        for (final SaleLine line in result.lines) {
          final int index = _lines.indexWhere(
            (SaleLine existing) => existing.product.id == line.product.id,
          );
          if (index == -1) {
            _lines.add(line);
          } else {
            _lines[index] = line;
          }
        }
        _unmatched = result.unmatched;
        _aiMessage = result.lines.isEmpty
            ? 'Nothing in your inventory matched. Try naming the product '
                  'differently, or add it manually.'
            : 'Matched ${result.lines.length} '
                  'item${result.lines.length == 1 ? '' : 's'}. Review the '
                  'receipt below.';
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _aiMessage = null);
      showAppMessage(context, error.userMessage, isError: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _aiMessage = null);
      showAppMessage(
        context,
        'The AI request failed. You can still add items manually.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isThinking = false);
    }
  }

  Future<void> _showKeyHelp() => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Add your AI key'),
      content: const Text(
        'The voice assistant uses your own AI key.\n\n'
        'Open Profile → Sell assistant (AI), pick Gemini or OpenRouter, and '
        'paste a key. It stays on this phone.\n\n'
        'Searching products and setting quantities works without a key.',
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  /* ------------------------------------------------------------------------ */
  /* Confirm                                                                  */
  /* ------------------------------------------------------------------------ */

  Future<void> _confirmCash() => _confirm(paymentMethod: 'cash');

  Future<void> _confirmDigital() async {
    if (_lines.isEmpty || _isSaving) return;

    final LiveSmsPayment? live = _livePayment;
    if (live != null) {
      final PaymentAmountMatch match = PaymentAmountMatch(
        receivedMinor: live.amountMinor,
        expectedMinor: _totalMinor,
      );

      if (!match.isAttachable) {
        final bool proceed = await confirmDialog(
          context,
          title: 'The totals do not match',
          message:
              'This payment is ${match.differenceLabel} away from the receipt. '
              'If you continue, the payment and the sale are recorded as two '
              'separate entries.',
          confirmLabel: 'Record separately',
          destructive: true,
        );
        if (!mounted || !proceed) return;

        await _confirm(
          paymentMethod: live.method,
          paymentReference: live.reference,
        );
        return;
      }

      await _confirm(
        paymentMethod: live.method,
        paymentReference: live.reference,
        liveSms: live,
      );
      return;
    }

    await _pickAndConfirmPayment();
  }

  Future<void> _pickAndConfirmPayment() async {
    final PaymentChoice? choice = await PaymentPickerSheet.show(
      context,
      totalMinor: _totalMinor,
    );
    if (choice == null || !mounted) return;

    await _confirm(
      paymentMethod: choice.method,
      paymentReference: choice.reference,
      smsId: choice.smsId,
    );
  }

  Future<void> _confirm({
    required String paymentMethod,
    String? paymentReference,
    String? smsId,
    LiveSmsPayment? liveSms,
  }) async {
    final shop = ref.read(activeShopProvider);
    if (shop == null) {
      showAppMessage(
        context,
        'Create a shop before recording a sale.',
        isError: true,
      );
      return;
    }
    if (_lines.isEmpty || _isSaving) return;

    setState(() => _isSaving = true);

    try {
      final SaleReceipt receipt = await ref
          .read(saleServiceProvider)
          .create(
            shop.id,
            lines: List<SaleLine>.unmodifiable(_lines),
            counterparty: _customer.text,
            paymentMethod: paymentMethod,
            paymentReference: paymentReference,
            smsId: smsId,
            liveSms: liveSms,
          );

      // The ledger, stock and score all changed on the server.
      ref.invalidate(productListProvider);
      ref.invalidate(monthTransactionsProvider);
      ref.invalidate(creditProfileProvider);
      ref.invalidate(matchedPlansProvider);

      if (!mounted) return;
      await _showReceipt(receipt);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.userMessage, isError: true);
      // Stock may have changed elsewhere; pull the truth back in.
      ref.invalidate(productListProvider);
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        context,
        'The sale could not be saved. Try again.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showReceipt(SaleReceipt receipt) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ThemeData theme = Theme.of(dialogContext);

      return AlertDialog(
        title: Row(
          children: <Widget>[
            const Icon(Icons.check_circle_rounded, color: GreenBizTheme.inflow),
            const SizedBox(width: 8),
            const Expanded(child: Text('Sale recorded')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final SaleReceiptItem item in receipt.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${item.quantityLabel} ${item.unit} · '
                          '${item.productName}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        formatMinor(
                          item.lineTotalMinor,
                          currency: receipt.currency,
                        ),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              const Divider(),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Total',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    receipt.totalLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: GreenBizTheme.inflow,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Paid by',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    receipt.paymentMethodLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (receipt.reference != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  'TrxID ${receipt.reference}',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (receipt.score != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'Your credit score is now ${receipt.score}/100.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );

  /* ------------------------------------------------------------------------ */
  /* Build                                                                    */
  /* ------------------------------------------------------------------------ */

  List<Product> _filtered(List<Product> products) {
    final String query = normalizeForSaleSearch(_search.text);
    if (query.isEmpty) return products;

    final List<String> tokens = query
        .split(' ')
        .where((String token) => token.isNotEmpty)
        .toList(growable: false);

    return products
        .where((Product product) {
          final String name = normalizeForSaleSearch(product.productName);
          return tokens.every(name.contains);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<Product>> products = ref.watch(productListProvider);
    final shop = ref.watch(activeShopProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('New sale'),
        actions: <Widget>[
          if (_lines.isNotEmpty)
            IconButton(
              tooltip: 'Clear receipt',
              onPressed: _isSaving ? null : _clearCart,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: shop == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No shop yet',
              message: 'Create a shop in Profile before selling.',
            )
          : SafeArea(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(productListProvider);
                  await ref.read(productListProvider.future);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: <Widget>[
                    if (_livePayment != null) ...<Widget>[
                      _buildLivePaymentCard(theme),
                      const SizedBox(height: 12),
                    ],
                    _buildVoiceCard(theme),
                    const SizedBox(height: 12),
                    _buildProductsCard(theme, products),
                    const SizedBox(height: 12),
                    _buildReceiptCard(theme),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildLivePaymentCard(ThemeData theme) {
    final LiveSmsPayment live = _livePayment!;
    final PaymentAmountMatch? match = _lines.isEmpty
        ? null
        : PaymentAmountMatch(
            receivedMinor: live.amountMinor,
            expectedMinor: _totalMinor,
            currency: 'BDT',
          );

    return Card(
      color: GreenBizTheme.inflow.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: GreenBizTheme.inflow.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.south_west_rounded,
                  color: GreenBizTheme.inflow,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Payment received · ${live.methodLabel}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  formatMinor(live.amountMinor),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: GreenBizTheme.inflow,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Swipe left when you finish the receipt and this message is '
              'linked to the sale, so the money is counted once.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (match != null &&
                match.fit == PaymentAmountFit.outside) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: StatusChip(
                  label:
                      'Receipt total is ${match.differenceLabel} away — this '
                      'payment will stay a separate entry',
                  color: GreenBizTheme.scoreMedium,
                  dense: true,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                live.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (BuildContext dialogContext) => AlertDialog(
                      title: const Text('Payment message'),
                      content: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              live.sender,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SelectableText(live.body),
                          ],
                        ),
                      ),
                      actions: <Widget>[
                        FilledButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                  icon: const Icon(Icons.sms_outlined, size: 16),
                  label: const Text('View message'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _livePayment = null),
                  child: const Text('Detach'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceCard(ThemeData theme) {
    return AppCard(
      title: 'Speak the sale',
      subtitle: 'Optional — the assistant fills the receipt for you',
      trailing: IconButton.filledTonal(
        tooltip: _isListening ? 'Stop listening' : 'Dictate the sale',
        onPressed: _isThinking ? null : _toggleListening,
        style: _isListening
            ? IconButton.styleFrom(
                backgroundColor: theme.colorScheme.errorContainer,
                foregroundColor: theme.colorScheme.onErrorContainer,
              )
            : null,
        icon: Icon(_isListening ? Icons.stop_rounded : Icons.mic_rounded),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _transcript,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: '3 kg rice and two notebooks',
              helperText: _isListening
                  ? 'Listening… tap the mic to stop'
                  : 'Say it, or type it. Then let the AI find the products.',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isThinking || _isSaving ? null : _runAi,
                  icon: _isThinking
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(_isThinking ? 'Reading…' : 'Read with AI'),
                ),
              ),
              if (_transcript.text.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Clear text',
                  onPressed: _isThinking
                      ? null
                      : () => setState(() {
                          _transcript.clear();
                          _aiMessage = null;
                          _unmatched = const <String>[];
                        }),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ],
          ),
          if (_aiMessage != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _aiMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_unmatched.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String item in _unmatched)
                  StatusChip(
                    label: item,
                    color: GreenBizTheme.scoreMedium,
                    icon: Icons.help_outline_rounded,
                    dense: true,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProductsCard(
    ThemeData theme,
    AsyncValue<List<Product>> products,
  ) {
    return AppCard(
      title: 'Add products',
      subtitle: 'Search your inventory',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _search,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Search by name',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => _search.clear(),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          products.when(
            skipLoadingOnRefresh: true,
            skipLoadingOnReload: true,
            loading: () => const LoadingView(message: 'Loading inventory'),
            error: (Object error, StackTrace stack) => ErrorView(
              error: error,
              compact: true,
              onRetry: () => ref.invalidate(productListProvider),
            ),
            data: (List<Product> items) {
              if (items.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No products yet. Add one from the Inventory tab first.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }

              final List<Product> filtered = _filtered(items);
              if (filtered.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Nothing in your inventory matches "${_search.text.trim()}".',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }

              final List<Product> shown = filtered
                  .take(30)
                  .toList(growable: false);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < shown.length; i++) ...<Widget>[
                    if (i > 0) const Divider(height: 1),
                    _ProductRow(
                      product: shown[i],
                      onAdd: () => _addProduct(shown[i]),
                    ),
                  ],
                  if (filtered.length > shown.length) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      'Showing the first 30. Keep typing to narrow it down.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptCard(ThemeData theme) {
    return AppCard(
      title: 'Receipt',
      subtitle: _lines.isEmpty
          ? 'Nothing added yet'
          : '${_lines.length} item${_lines.length == 1 ? '' : 's'} · '
                'stock will be reduced when you confirm',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Tap a product above, or dictate the sale.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else ...<Widget>[
            for (final SaleLine line in _lines)
              _SaleLineRow(
                line: line,
                onDecrease: () => _changeQuantity(line, -1),
                onIncrease: () => _changeQuantity(line, 1),
                onEdit: () => _promptQuantity(line),
                onRemove: () => _removeLine(line.product.id),
              ),
            const Divider(),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Total',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  formatMinor(_totalMinor),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: GreenBizTheme.inflow,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customer,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Customer name (optional)',
                hintText: 'Walk-in customer',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SwipeConfirmBar(
            enabled: _lines.isNotEmpty,
            busy: _isSaving,
            onCash: _confirmCash,
            onDigital: _confirmDigital,
          ),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Small widgets                                                              */
/* -------------------------------------------------------------------------- */

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.onAdd});

  final Product product;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool outOfStock = product.isOutOfStock;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: outOfStock ? null : onAdd,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.inventory_2_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    product.productName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${product.priceLabel()} · '
                    '${outOfStock ? 'out of stock' : '${product.stockLabel} left'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: outOfStock
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              outOfStock ? Icons.block_rounded : Icons.add_circle_rounded,
              color: outOfStock
                  ? theme.colorScheme.outline
                  : theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _SaleLineRow extends StatelessWidget {
  const _SaleLineRow({
    required this.line,
    required this.onDecrease,
    required this.onIncrease,
    required this.onEdit,
    required this.onRemove,
  });

  final SaleLine line;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  line.product.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatMinor(line.lineTotalMinor),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${formatMinor(line.product.unitPriceMinor)} / '
                  '${line.product.unit}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.remove_rounded,
                tooltip: 'One less',
                onPressed: onDecrease,
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onEdit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    line.quantityLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.add_rounded,
                tooltip: 'One more',
                onPressed: onIncrease,
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onRemove,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
    );
  }
}
