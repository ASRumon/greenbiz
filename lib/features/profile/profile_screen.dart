import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env.dart';
import '../../core/providers.dart';
import '../../models/shop.dart';
import '../../models/user.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import 'ai_settings_card.dart';
import 'profile_controller.dart';
import 'sms_permission_card.dart';

/// Tab 3 - who you are, which shop you are looking at, and what you have
/// granted.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authControllerProvider);
    final SmsSyncState sync = ref.watch(smsSyncControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          _AccountCard(user: auth.user),
          const SizedBox(height: 12),
          _ShopSelectorCard(auth: auth),
          const SizedBox(height: 12),
          const AiSettingsCard(),
          const SizedBox(height: 12),
          const SmsPermissionCard(),
          const SizedBox(height: 12),
          const _DataAndPrivacyCard(),
          const SizedBox(height: 12),
          _SessionCard(user: auth.user, sync: sync),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'GreenBiz ${Env.appVersion}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final User? account = user;

    return AppCard(
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 26,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              account?.initials ?? '?',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  account?.fullName ?? 'Loading…',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '@${account?.username ?? ''}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (account?.email != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    account!.email!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shop picker plus the create / delete actions.
///
/// The selector is a plain list of choices rather than a dropdown: a shop owner
/// with three shops benefits more from seeing them all at once than from saving
/// two lines of vertical space.
class _ShopSelectorCard extends ConsumerStatefulWidget {
  const _ShopSelectorCard({required this.auth});

  final AuthState auth;

  @override
  ConsumerState<_ShopSelectorCard> createState() => _ShopSelectorCardState();
}

class _ShopSelectorCardState extends ConsumerState<_ShopSelectorCard> {
  bool _isBusy = false;

  Future<void> _createShop() async {
    final TextEditingController name = TextEditingController();
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();

    final bool? submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Add a shop',
                  style: Theme.of(sheetContext).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Shop name',
                    hintText: 'Karim General Store',
                  ),
                  validator: (String? value) => (value?.trim().isEmpty ?? true)
                      ? 'Give the shop a name'
                      : null,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    if (formKey.currentState?.validate() ?? false) {
                      Navigator.of(sheetContext).pop(true);
                    }
                  },
                  child: const Text('Add shop'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (submitted != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(shopServiceProvider).create(shopName: name.text.trim());
      await ref.read(authControllerProvider.notifier).refresh();
      if (!mounted) return;
      showAppMessage(context, 'Shop added.');
    } catch (error) {
      if (!mounted) return;
      showErrorMessage(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _deleteShop(Shop shop) async {
    final bool confirmed = await confirmDialog(
      context,
      title: 'Delete "${shop.shopName}"?',
      message:
          'This permanently deletes the shop along with its inventory, synced '
          'messages, transactions and credit profile.',
      confirmLabel: 'Delete shop',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(shopServiceProvider).delete(shop.id);
      await ref.read(authControllerProvider.notifier).refresh();
      if (!mounted) return;
      showAppMessage(context, 'Shop deleted.');
    } catch (error) {
      if (!mounted) return;
      showErrorMessage(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = widget.auth;

    return AppCard(
      title: 'Your shops',
      subtitle: auth.shops.isEmpty
          ? 'No shops yet'
          : '${auth.shops.length} shop${auth.shops.length == 1 ? '' : 's'} · '
                '${auth.activeShop?.shopName ?? ''} is active',
      trailing: IconButton(
        tooltip: 'Add a shop',
        visualDensity: VisualDensity.compact,
        onPressed: _isBusy ? null : _createShop,
        icon: const Icon(Icons.add_business_outlined, size: 20),
      ),
      child: auth.shops.isEmpty
          ? EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No shop yet',
              message: 'Add a shop to start tracking inventory and payments.',
              action: FilledButton.icon(
                onPressed: _isBusy ? null : _createShop,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add shop'),
              ),
            )
          : Column(
              children: auth.shops
                  .map(
                    (Shop shop) => _ShopRow(
                      shop: shop,
                      isActive: shop.id == auth.activeShop?.id,
                      onSelect: () => ref
                          .read(authControllerProvider.notifier)
                          .selectShop(shop.id),
                      onDelete: _isBusy ? null : () => _deleteShop(shop),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _ShopRow extends StatelessWidget {
  const _ShopRow({
    required this.shop,
    required this.isActive,
    required this.onSelect,
    required this.onDelete,
  });

  final Shop shop;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(
              isActive
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    shop.shopName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (shop.businessType != null)
                    Text(
                      shop.businessType!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Delete shop',
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is collected, where it goes, and what is never shared.
class _DataAndPrivacyCard extends StatelessWidget {
  const _DataAndPrivacyCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const List<(IconData, String, String)> items = <(IconData, String, String)>[
      (
        Icons.sms_outlined,
        'Only payment confirmations are uploaded',
        'Messages are filtered on this phone. Personal messages, one-time '
            'passwords and promotions never leave the device.',
      ),
      (
        Icons.storage_outlined,
        'Your raw messages stay private to your account',
        'They are stored against your shop so you can reconcile them. They are '
            'never sold and never shared with a lender.',
      ),
      (
        Icons.insights_outlined,
        'Lenders would only ever see aggregated signals',
        'If you apply for a loan, a lender sees your score and totals — not your '
            'messages and not your customers\' phone numbers.',
      ),
      (
        Icons.no_accounts_outlined,
        'No advertising, no data brokers',
        'There is no ad SDK and no analytics SDK in this app.',
      ),
      (
        Icons.delete_outline_rounded,
        'You can delete everything',
        'Deleting a shop removes its messages, transactions and credit profile '
            'from the server.',
      ),
    ];

    return AppCard(
      title: 'Data & privacy',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items
            .map(
              ((IconData, String, String) item) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(item.$1, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item.$2,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.$3,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _SessionCard extends ConsumerStatefulWidget {
  const _SessionCard({required this.user, required this.sync});

  final User? user;
  final SmsSyncState sync;

  @override
  ConsumerState<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends ConsumerState<_SessionCard> {
  bool _isSigningOut = false;

  Future<void> _logout() async {
    final bool confirmed = await confirmDialog(
      context,
      title: 'Sign out?',
      message:
          'Your records stay on the server and will be here when you sign '
          'back in.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !mounted) return;

    setState(() => _isSigningOut = true);
    await ref.read(authControllerProvider.notifier).logout();

    if (!mounted) return;
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppCard(
      title: 'Session',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DetailRow(label: 'Signed in as', value: widget.user?.username ?? '—'),
          DetailRow(
            label: 'Permission',
            value: widget.sync.permission.isGranted
                ? 'Messages allowed'
                : 'Messages not allowed',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _isSigningOut ? null : _logout,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: Text(_isSigningOut ? 'Signing out…' : 'Log out'),
          ),
        ],
      ),
    );
  }
}
