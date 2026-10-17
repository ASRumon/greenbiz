import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_controller.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/finance/business_report_screen.dart';
import '../features/finance/transactions_screen.dart';
import '../features/home_shell.dart';
import '../features/inventory/product_detail_screen.dart';
import '../features/sell/sell_screen.dart';
import '../models/live_sms_payment.dart';
import '../models/product.dart';

/// Every navigable route in the app.
class AppRoutes {
  const AppRoutes._();

  /// Entry point. Decides between the login screen and the tab shell.
  static const String bootstrap = '/';

  static const String login = '/login';
  static const String register = '/register';
  static const String home = '/home';

  /// Expects a [Product] as the route argument.
  static const String productDetail = '/product-detail';

  /// Build a sale from inventory, optionally by voice.
  static const String sell = '/sell';

  /// The payment ledger, where rows can be marked business or personal.
  static const String transactions = '/payments';

  /// Full Finance report with a selectable period and breakdowns.
  static const String businessReport = '/business-report';
}

class AppRouter {
  const AppRouter._();

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.bootstrap:
        return MaterialPageRoute<void>(
          builder: (_) => const BootstrapScreen(),
          settings: settings,
        );

      case AppRoutes.login:
        return MaterialPageRoute<void>(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );

      case AppRoutes.register:
        return MaterialPageRoute<void>(
          builder: (_) => const RegisterScreen(),
          settings: settings,
        );

      case AppRoutes.home:
        return MaterialPageRoute<void>(
          builder: (_) => const HomeShell(),
          settings: settings,
        );

      case AppRoutes.sell:
        final Object? arguments = settings.arguments;
        return MaterialPageRoute<void>(
          builder: (_) => SellScreen(
            livePayment: arguments is LiveSmsPayment ? arguments : null,
          ),
          settings: settings,
        );

      case AppRoutes.transactions:
        return MaterialPageRoute<void>(
          builder: (_) => const TransactionsScreen(),
          settings: settings,
        );

      case AppRoutes.businessReport:
        return MaterialPageRoute<void>(
          builder: (_) => const BusinessReportScreen(),
          settings: settings,
        );

      case AppRoutes.productDetail:
        final Object? arguments = settings.arguments;
        if (arguments is! Product) {
          // Reached only by a programming mistake, so say so rather than
          // rendering a detail screen with no product.
          return MaterialPageRoute<void>(
            builder: (_) => const _RoutingErrorScreen(
              message: 'This screen needs a product to display.',
            ),
            settings: settings,
          );
        }
        return MaterialPageRoute<void>(
          builder: (_) => ProductDetailScreen(product: arguments),
          settings: settings,
        );

      default:
        return MaterialPageRoute<void>(
          builder: (_) => _RoutingErrorScreen(
            message: 'Page "${settings.name}" not found.',
          ),
          settings: settings,
        );
    }
  }
}

/// First screen after launch.
///
/// Shows the splash while the stored session is validated, then replaces itself
/// with the login screen or the tab shell. It never renders a "logged out" flash
/// for an already-signed-in user, because the restore is still in flight while
/// the splash is visible.
class BootstrapScreen extends ConsumerStatefulWidget {
  const BootstrapScreen({super.key});

  @override
  ConsumerState<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends ConsumerState<BootstrapScreen> {
  bool _navigated = false;

  void _goTo(AuthState state) {
    if (_navigated || !mounted || state.status == AuthStatus.restoring) return;
    _navigated = true;
    Navigator.of(context).pushReplacementNamed(
      state.isAuthenticated ? AppRoutes.home : AppRoutes.login,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authControllerProvider, (
      AuthState? previous,
      AuthState next,
    ) {
      _goTo(next);
    });

    // Covers the case where the state resolved before this widget first built.
    final AuthState state = ref.watch(authControllerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(state));

    return const _SplashScreen();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              height: 64,
              width: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                Icons.storefront_rounded,
                size: 34,
                color: theme.colorScheme.onPrimary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'GreenBiz',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'SME Finance Copilot',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutingErrorScreen extends StatelessWidget {
  const _RoutingErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Not found')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.wrong_location_outlined, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.home,
                (Route<dynamic> route) => false,
              ),
              child: const Text('Back to the app'),
            ),
          ],
        ),
      ),
    ),
  );
}
