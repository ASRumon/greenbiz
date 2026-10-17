import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/live_sms_payment.dart';
import '../../services/sms_live_service.dart';
import '../profile/profile_controller.dart';

/// The payment alerts waiting to be shown, oldest first.
class LiveSmsState {
  const LiveSmsState({
    this.queue = const <LiveSmsPayment>[],
    this.isListening = false,
  });

  final List<LiveSmsPayment> queue;
  final bool isListening;

  bool get hasPending => queue.isNotEmpty;

  LiveSmsState copyWith({List<LiveSmsPayment>? queue, bool? isListening}) =>
      LiveSmsState(
        queue: queue ?? this.queue,
        isListening: isListening ?? this.isListening,
      );
}

final smsLiveServiceProvider = Provider<SmsLiveService>(
  (ref) => const SmsLiveService(),
);

/// Bridges the native SMS receiver to the in-app prompt.
///
/// It does two things with each confirmation: show the owner a prompt, and hand
/// the message to [SmsSyncController] so the ledger is updated even if the
/// owner dismisses the prompt.
class LiveSmsController extends Notifier<LiveSmsState> {
  StreamSubscription<LiveSmsPayment>? _subscription;
  bool _started = false;

  SmsLiveService get _service => ref.read(smsLiveServiceProvider);

  @override
  LiveSmsState build() {
    ref.onDispose(() {
      _subscription?.cancel();
      _subscription = null;
    });
    return const LiveSmsState();
  }

  /// Starts listening and drains anything captured while the app was away.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (!SmsLiveService.isSupported) return;

    await _service.setTrackingEnabled(true);
    _subscription = _service.events.listen(_onEvent, onError: (Object _) {});
    state = state.copyWith(isListening: true);

    await resume();
  }

  /// Stops listening and clears the queue when the user signs out.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
    await _service.setTrackingEnabled(false);
    state = const LiveSmsState();
  }

  /// Drains the native queue. Called on start and every app resume.
  Future<void> resume() async {
    if (!SmsLiveService.isSupported) return;

    final List<LiveSmsPayment> pending = await _service.consumePending();
    _enqueue(pending);
  }

  void dismiss(String id) {
    state = state.copyWith(
      queue: state.queue
          .where((LiveSmsPayment payment) => payment.id != id)
          .toList(growable: false),
    );
  }

  /// Drops the in-memory queue on sign-out. The native queue is cleared by
  /// [AuthController.logout] at the same time.
  void clear() => state = state.copyWith(queue: const <LiveSmsPayment>[]);

  void _onEvent(LiveSmsPayment payment) {
    _enqueue(<LiveSmsPayment>[payment]);
    unawaited(ref.read(smsSyncControllerProvider.notifier).ingestLive(payment));
  }

  void _enqueue(List<LiveSmsPayment> payments) {
    if (payments.isEmpty) return;

    final Set<String> known = state.queue
        .map((LiveSmsPayment payment) => payment.id)
        .toSet();

    final List<LiveSmsPayment> added = <LiveSmsPayment>[
      for (final LiveSmsPayment payment in payments)
        if (payment.isInflow &&
            payment.amountMinor > 0 &&
            !known.contains(payment.id))
          payment,
    ];
    if (added.isEmpty) return;

    state = state.copyWith(queue: <LiveSmsPayment>[...state.queue, ...added]);
  }
}

final liveSmsControllerProvider =
    NotifierProvider<LiveSmsController, LiveSmsState>(LiveSmsController.new);
