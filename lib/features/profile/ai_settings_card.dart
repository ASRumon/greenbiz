import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/sale_ai.dart';
import '../../widgets/common.dart';
import 'ai_settings_controller.dart';

/// Profile → "AI assistant".
///
/// This is deliberately a client-only setting: the key is entered by the shop
/// owner, stored on the device, and sent straight to the provider. The GreenBiz
/// Worker never sees it and has no AI key for these flows.
class AiSettingsCard extends ConsumerStatefulWidget {
  const AiSettingsCard({super.key});

  @override
  ConsumerState<AiSettingsCard> createState() => _AiSettingsCardState();
}

class _AiSettingsCardState extends ConsumerState<AiSettingsCard> {
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _model = TextEditingController();

  AiProvider _provider = AiProvider.gemini;
  bool _showKey = false;
  bool _seeded = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Seed the form once, when the keystore read completes. Later saves must
    // not overwrite what the user is typing.
    ref.listenManual<AsyncValue<AiSettings>>(aiSettingsControllerProvider, (
      AsyncValue<AiSettings>? previous,
      AsyncValue<AiSettings> next,
    ) {
      final AiSettings? settings = next.value;
      if (settings == null || _seeded) return;
      _seeded = true;
      _provider = settings.provider;
      _apiKey.text = settings.apiKey;
      _model.text = settings.model;
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String key = _apiKey.text.trim();
    if (key.isEmpty) {
      showAppMessage(
        context,
        'Paste your ${_provider.label} API key first.',
        isError: true,
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(aiSettingsControllerProvider.notifier)
          .save(
            AiSettings(
              provider: _provider,
              model: _model.text.trim(),
              apiKey: key,
            ),
          );
      if (!mounted) return;
      showAppMessage(context, 'AI key saved on this device.');
    } catch (error) {
      if (!mounted) return;
      showAppMessage(context, 'Could not save the key: $error', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeKey() async {
    final bool confirmed = await confirmDialog(
      context,
      title: 'Remove the AI key?',
      message:
          'Voice sales and product scanning will stop working until you add a '
          'key again. Your inventory and sales are not affected.',
      confirmLabel: 'Remove key',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isSaving = true);
    try {
      await ref.read(aiSettingsControllerProvider.notifier).clearKey();
      if (!mounted) return;
      _apiKey.clear();
      showAppMessage(context, 'AI key removed.');
    } catch (error) {
      if (!mounted) return;
      showAppMessage(context, 'Could not remove the key.', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final AsyncValue<AiSettings> settings = ref.watch(
      aiSettingsControllerProvider,
    );

    if (settings.isLoading && !_seeded) {
      return const AppCard(
        title: 'AI assistant',
        child: LoadingView(message: 'Reading your AI settings'),
      );
    }

    final bool hasSavedKey = settings.value?.isConfigured ?? false;

    return AppCard(
      title: 'AI assistant',
      subtitle: hasSavedKey
          ? 'Key saved · ${_provider.label}'
          : 'Add your own key for voice sales and photo scanning',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Say what a customer bought — "3 kg rice and two notebooks" — and '
            'the assistant turns it into receipt lines from your inventory. '
            'The same key reads a product label from a photo.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<AiProvider>(
            segments: <ButtonSegment<AiProvider>>[
              for (final provider in AiProvider.values)
                ButtonSegment<AiProvider>(
                  value: provider,
                  label: Text(provider.label),
                ),
            ],
            selected: <AiProvider>{_provider},
            onSelectionChanged: _isSaving
                ? null
                : (Set<AiProvider> selection) =>
                      setState(() => _provider = selection.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '${_provider.label} API key',
              hintText: _provider.keyHint,
              helperText: 'Stored on this phone, never sent to GreenBiz.',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                tooltip: _showKey ? 'Hide key' : 'Show key',
                onPressed: () => setState(() => _showKey = !_showKey),
                icon: Icon(
                  _showKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Model (optional)',
              hintText: _provider.defaultModel,
              helperText: 'Leave blank to use ${_provider.defaultModel}.',
              prefixIcon: const Icon(Icons.memory_rounded),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_isSaving ? 'Saving…' : 'Save AI settings'),
          ),
          if (hasSavedKey) ...<Widget>[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _isSaving ? null : _removeKey,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Remove key'),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'GreenBiz has no AI key for this feature. The request goes from '
            'this device directly to ${_provider.label}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
