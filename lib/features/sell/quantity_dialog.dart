import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/quantity_input.dart';
import '../../core/theme.dart';
import '../../models/product.dart';
import '../../models/sale.dart';

/// Quantity / amount editor for one product on a sale.
///
/// Type a quantity ("2.5 kg") or the money the customer wants to spend ("৳10 of
/// onion") and the dialog works out the other side. Invalid input is explained
/// on the field instead of closing silently.
///
/// The field calls `setState` on every change: without that, the Set button is
/// built once while the amount field is empty and stays disabled even after the
/// owner types an amount.
class QuantityDialog extends StatefulWidget {
  const QuantityDialog({
    super.key,
    required this.product,
    required this.initialQuantity,
    this.startWithAmount = false,
  });

  final Product product;
  final double initialQuantity;

  /// Open on the money side ("Give me ৳10 of onion").
  final bool startWithAmount;

  @override
  State<QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<QuantityDialog> {
  late final TextEditingController _quantity = TextEditingController(
    text: formatQuantity(widget.initialQuantity),
  );
  late final TextEditingController _amount = TextEditingController();
  late bool _byAmount =
      widget.startWithAmount && widget.product.unitPriceMinor > 0;

  @override
  void initState() {
    super.initState();
    if (_byAmount) {
      _prefillAmount();
      _selectAll(_amount);
    } else {
      _selectAll(_quantity);
    }
  }

  @override
  void dispose() {
    _quantity.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// Selects the prefilled value, so the first keystroke replaces it instead of
  /// appending ("60" + "10" would otherwise become ৳6,010).
  void _selectAll(TextEditingController controller) {
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  /// The money the current quantity costs, so switching to Amount starts from
  /// a sensible number instead of an empty field.
  void _prefillAmount() {
    if (_amount.text.trim().isNotEmpty) return;
    final double? quantity = parseQuantityText(_quantity.text);
    if (quantity == null || quantity <= 0) return;

    _amount.text = minorToEditable(
      lineTotalFor(
        unitPriceMinor: widget.product.unitPriceMinor,
        quantity: quantity,
      ),
    );
  }

  ({double quantity, String? warning})? get _amountResolution {
    if (!_byAmount) return null;
    final int? amountMinor = parseMoneyText(_amount.text);
    if (amountMinor == null) return null;
    if (widget.product.unitPriceMinor <= 0) return null;

    return resolveAmountQuantity(
      product: widget.product,
      amountMinor: amountMinor,
      fallbackQuantity: 1,
    );
  }

  double? get _value {
    if (_byAmount) return _amountResolution?.quantity;
    return parseQuantityText(_quantity.text);
  }

  String? get _amountWarning => _amountResolution?.warning;

  bool get _hasText =>
      (_byAmount ? _amount.text : _quantity.text).trim().isNotEmpty;

  String? get _error {
    final double? value = _value;
    if (value == null) {
      return _byAmount
          ? 'Enter an amount like 10 or 20.50'
          : 'Enter a quantity like 2 or 2.5';
    }
    if (value <= 0) {
      return _byAmount
          ? 'Enter an amount above zero'
          : 'Enter a quantity above zero';
    }
    if (value > widget.product.stockQuantity + 1e-9) {
      if (_byAmount) {
        final int maxMinor =
            (widget.product.unitPriceMinor * widget.product.stockQuantity)
                .round();
        return 'Only ${widget.product.stockLabel} ${widget.product.unit} in '
            'stock (up to ${formatMinor(maxMinor)})';
      }
      return 'Only ${widget.product.stockLabel} ${widget.product.unit} in '
          'stock';
    }
    return null;
  }

  String get _helper {
    final Product product = widget.product;
    if (!_byAmount) {
      return 'In stock: ${product.stockLabel} ${product.unit}';
    }
    final int maxMinor = (product.unitPriceMinor * product.stockQuantity)
        .round();
    return 'In stock: ${product.stockLabel} ${product.unit} · up to '
        '${formatMinor(maxMinor)}';
  }

  String? get _preview {
    if (_error != null) return null;
    final double? value = _value;
    if (value == null || value <= 0) return null;

    final int totalMinor = lineTotalFor(
      unitPriceMinor: widget.product.unitPriceMinor,
      quantity: value,
    );
    return '${formatQuantity(value)} ${widget.product.unit} · '
        '${formatMinor(totalMinor)}';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? value = _value;
    final String? error = _error;
    final bool canSet = value != null && error == null && value > 0;

    return AlertDialog(
      title: Text(widget.product.productName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Quantity'),
                  icon: Icon(Icons.straighten_rounded, size: 16),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Amount'),
                  icon: Icon(Icons.payments_outlined, size: 16),
                ),
              ],
              selected: <bool>{_byAmount},
              showSelectedIcon: false,
              onSelectionChanged: (Set<bool> selection) {
                setState(() {
                  _byAmount = selection.first;
                  if (_byAmount) {
                    _prefillAmount();
                    _selectAll(_amount);
                  } else {
                    _selectAll(_quantity);
                  }
                });
              },
            ),
            const SizedBox(height: 14),
            TextField(
              // A fresh field per mode so the correct controller, text and
              // focus are picked up when the owner switches.
              key: ValueKey<bool>(_byAmount),
              controller: _byAmount ? _amount : _quantity,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: <TextInputFormatter>[
                DecimalInputFormatter(
                  decimalDigits: _byAmount ? 2 : kQuantityDecimals,
                ),
              ],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _byAmount
                    ? 'Amount the customer is paying'
                    : 'Quantity in ${widget.product.unit}',
                prefixText: _byAmount ? '৳ ' : null,
                hintText: _byAmount ? '10' : '2.5',
                helperText: _helper,
                helperMaxLines: 2,
                errorText: _hasText ? error : null,
                errorMaxLines: 2,
              ),
            ),
            if (_amountWarning != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _amountWarning!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: GreenBizTheme.scoreMedium,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_preview != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _preview!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: GreenBizTheme.inflow,
                ),
              ),
            ],
            if (_byAmount && widget.product.unitPriceMinor <= 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'This product has no selling price yet. Set one in Inventory '
                'to sell it by amount.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSet ? () => Navigator.of(context).pop(value) : null,
          child: const Text('Set'),
        ),
      ],
    );
  }
}
