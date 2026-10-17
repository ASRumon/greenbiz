import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/router.dart';
import '../features/auth/auth_controller.dart';
import '../features/finance/finance_screen.dart';
import '../features/inventory/inventory_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/sms/live_payment_sheet.dart';
import '../features/sms/live_sms_controller.dart';
import '../features/sync/sync_banner.dart';
import '../features/sync/sync_controller.dart';

/// The signed-in shell: three tabs over a shared bottom navigation bar.
///
/// `IndexedStack` rather than a `PageView` so each tab keeps its scroll
/// position and its loaded data when the user switches away and back. Switching
/// to Finance should not re-fetch the credit profile every time.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _showingPayment = false;

  /// The first `resumed` event arrives during a cold start. Without this flag
  /// the shell synced once from initState and again from that event, which was
  /// the second of the visible reloads at launch.
  bool _wasBackgrounded = false;

  static const List<Widget> _tabs = <Widget>[
    InventoryScreen(),
    FinanceScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Covers a fresh sign-in as well as the first launch: the controller is
    // long-lived, so its own bootstrap only runs once per app process.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(syncControllerProvider.notifier).syncNow();
      ref.read(liveSmsControllerProvider.notifier).start();
    });
  }

  /// Shows the oldest queued payment; each answer moves the queue forward.
  Future<void> _maybeShowPayment() async {
    if (_showingPayment || !mounted) return;

    final LiveSmsState state = ref.read(liveSmsControllerProvider);
    if (state.queue.isEmpty) return;

    _showingPayment = true;
    final payment = state.queue.first;

    final LivePaymentAction? action = await LivePaymentSheet.show(
      context,
      payment: payment,
    );

    ref.read(liveSmsControllerProvider.notifier).dismiss(payment.id);

    if (mounted && action == LivePaymentAction.createSale) {
      await Navigator.of(context).pushNamed(AppRoutes.sell, arguments: payment);
    }

    _showingPayment = false;
    if (mounted) unawaited(_maybeShowPayment());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wasBackgrounded = true;
      return;
    }

    // Android does not deliver connectivity changes while backgrounded, so
    // refresh only when the owner actually comes back — not on the synthetic
    // `resumed` event of a cold start.
    if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      ref.read(syncControllerProvider.notifier).syncNow();
      ref.read(liveSmsControllerProvider.notifier).resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    // If the session ends while the shell is on screen — expired token, or the
    // account was removed — bounce to login instead of leaving the user on a
    // screen that can only produce 401s.
    ref.listen<AuthState>(authControllerProvider, (
      AuthState? previous,
      AuthState next,
    ) {
      if (next.status == AuthStatus.unauthenticated && mounted) {
        unawaited(ref.read(liveSmsControllerProvider.notifier).stop());
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      }
    });

    ref.listen<LiveSmsState>(liveSmsControllerProvider, (
      LiveSmsState? previous,
      LiveSmsState next,
    ) {
      if (_showingPayment || !next.hasPending) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_maybeShowPayment());
      });
    });

    // Covers a prompt that was queued before this widget registered its
    // listener, e.g. when the app was opened from the notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeShowPayment());
    });

    return Scaffold(
      body: Column(
        children: <Widget>[
          // Watching the banner starts the sync controller: initial sync,
          // then a retry whenever connectivity returns.
          const SyncBanner(),
          Expanded(
            child: IndexedStack(index: _index, children: _tabs),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int value) => setState(() => _index = value),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2_rounded),
            label: 'Inventory',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Finance',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
