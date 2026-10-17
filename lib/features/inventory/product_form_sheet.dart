import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import '../../core/image_compression.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../models/product.dart';
import '../../services/product_scan_ai.dart';
import '../../services/sale_ai.dart';
import '../../widgets/common.dart';
import '../profile/ai_settings_controller.dart';
import 'inventory_controller.dart';

/// Bottom-sheet form for creating or editing a product.
///
/// One widget serves both cases: the only differences are the pre-filled values,
/// the title, and whether a PATCH or a POST is sent. Two near-identical forms
/// would drift apart.
class ProductFormSheet extends ConsumerStatefulWidget {
  const ProductFormSheet({super.key, this.existing, this.autoScan = false});

  /// Null when adding.
  final Product? existing;

  /// Open the camera as soon as the sheet is on screen.
  final bool autoScan;

  static Future<bool?> show(
    BuildContext context, {
    Product? existing,
    bool autoScan = false,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProductFormSheet(existing: existing, autoScan: autoScan),
    );
  }

  @override
  ConsumerState<ProductFormSheet> createState() => _ProductFormSheetState();
}

class _ProductFormSheetState extends ConsumerState<ProductFormSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _price;
  late final TextEditingController _stock;
  bool _isSaving = false;
  bool _isScanning = false;

  bool get _isEditing => widget.existing != null;

  /// Common units for a shop that sells by piece or by weight.
  static const List<String> _unitSuggestions = <String>[
    'piece',
    'kg',
    'gram',
    'litre',
    'packet',
    'dozen',
    'bag',
    'box',
    'bottle',
  ];

  @override
  void initState() {
    super.initState();
    final Product? existing = widget.existing;

    _name = TextEditingController(text: existing?.productName ?? '');
    _unit = TextEditingController(text: existing?.unit ?? '');
    _price = TextEditingController(
      text: existing == null ? '' : minorToEditable(existing.unitPriceMinor),
    );
    _stock = TextEditingController(text: existing?.stockLabel ?? '');

    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanProduct();
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _price.dispose();
    _stock.dispose();
    super.dispose();
  }

  Future<void> _scanProduct() async {
    FocusScope.of(context).unfocus();

    AiSettings settings;
    try {
      settings = await ref.read(aiSettingsControllerProvider.future);
    } catch (_) {
      settings = const AiSettings();
    }

    if (!settings.isConfigured) {
      if (!mounted) return;
      await _showScanKeyHelp();
      return;
    }

    final ImagePicker picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 100,
      );
    } catch (_) {
      if (!mounted) return;
      showAppMessage(
        context,
        'The camera could not be opened on this device.',
        isError: true,
      );
      return;
    }

    if (picked == null || !mounted) return;

    final String capturePath = picked.path;
    setState(() => _isScanning = true);

    try {
      final Uint8List compressed = await compressPhotoForAi(capturePath);
      final ProductScanResult result = await ref
          .read(productScanAiServiceProvider)
          .scan(jpegBytes: compressed, settings: settings);

      if (!mounted) return;

      if (result.isEmpty) {
        showAppMessage(
          context,
          result.notes ??
              'No product name was readable. Try a clearer, closer photo.',
          isError: true,
        );
        return;
      }

      setState(() {
        _name.text = result.productName;
        if (result.unit.isNotEmpty) _unit.text = result.unit;
        if (result.unitPriceMinor != null && result.unitPriceMinor! > 0) {
          _price.text = minorToEditable(result.unitPriceMinor!);
        }
      });

      showAppMessage(
        context,
        'Photo read. Check the name, price and stock before saving.',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.userMessage, isError: true);
    } catch (_) {
      if (!mounted) return;
      showAppMessage(
        context,
        'Could not read that photo. Try again with more light.',
        isError: true,
      );
    } finally {
      // Camera captures live in the picker's cache; remove ours immediately.
      try {
        await File(capturePath).delete();
      } catch (_) {
        // The OS will reap the temporary file.
      }
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _showScanKeyHelp() => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Add your AI key'),
      content: const Text(
        'Product scanning uses your own AI key. Open Profile → AI assistant, '
        'choose Gemini or OpenRouter, and paste a key.\n\n'
        'Gemini 2.5 Flash is recommended because it can read images.',
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    final int? priceMinor = parseMajorToMinor(_price.text);
    final double stock = double.tryParse(_stock.text.trim()) ?? 0;

    if (priceMinor == null) {
      showAppMessage(
        context,
        'Enter a valid price, for example 95 or 95.50',
        isError: true,
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final controller = ref.read(inventoryControllerProvider);

      if (_isEditing) {
        await controller.updateProduct(
          widget.existing!.id,
          productName: _name.text.trim(),
          unit: _unit.text.trim(),
          unitPriceMinor: priceMinor,
          stockQuantity: stock,
        );
      } else {
        await controller.addProduct(
          productName: _name.text.trim(),
          unit: _unit.text.trim(),
          unitPriceMinor: priceMinor,
          stockQuantity: stock,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      showErrorMessage(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      // Lift the sheet above the keyboard instead of letting it cover the form.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _isEditing ? 'Edit product' : 'Add product',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Scan product with camera',
                    onPressed: _isSaving || _isScanning ? null : _scanProduct,
                    icon: _isScanning
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_camera_outlined),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _isScanning
                    ? 'Reading the product label…'
                    : 'Tap the camera icon to fill the name, unit and price '
                          'from a photo.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                autofocus: !_isEditing,
                decoration: const InputDecoration(
                  labelText: 'Product name',
                  hintText: 'Aromatic rice 5kg',
                ),
                validator: (String? value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Give the product a name';
                  if (text.length > 120) return 'Keep it under 120 characters';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _unit,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Unit',
                  hintText: 'piece, kg, bag',
                ),
                validator: (String? value) => (value?.trim().isEmpty ?? true)
                    ? 'How do you sell it?'
                    : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: -6,
                children: _unitSuggestions
                    .map(
                      (String unit) => ActionChip(
                        label: Text(unit, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _unit.text = unit),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Selling price',
                  prefixText: '  ',
                  hintText: '95.50',
                  helperText: 'Per unit, in your local currency',
                ),
                validator: (String? value) {
                  final parsed = parseMajorToMinor(value ?? '');
                  if (parsed == null) return 'Enter a price like 95 or 95.50';
                  if (parsed <= 0) return 'Price must be more than zero';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _stock,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _isSaving ? null : _save(),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Stock on hand',
                  hintText: '24',
                  helperText: 'Decimals are fine for weight, e.g. 2.5',
                ),
                validator: (String? value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Enter the quantity in stock';
                  final parsed = double.tryParse(text);
                  if (parsed == null) return 'Enter a number';
                  if (parsed < 0) return 'Stock cannot be negative';
                  return null;
                },
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Text(_isEditing ? 'Save changes' : 'Add to inventory'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
