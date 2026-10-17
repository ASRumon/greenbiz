import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/live_sms_payment.dart';

/// The native side's live SMS feed.
///
/// Android delivers `SMS_RECEIVED` to a `BroadcastReceiver` in this app. The
/// receiver stores every payment confirmation before doing anything else, so
/// the two delivery paths — a live event while Flutter is running, and a queue
/// drained on the next launch — cannot lose a message between them.
class SmsLiveService {
  const SmsLiveService();

  static const EventChannel _events = EventChannel('greenbiz/sms_live');
  static const MethodChannel _methods = MethodChannel(
    'greenbiz/sms_live_methods',
  );

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Messages captured while the app was in the foreground.
  Stream<LiveSmsPayment> get events {
    if (!isSupported) return const Stream<LiveSmsPayment>.empty();

    return _events
        .receiveBroadcastStream()
        .where((Object? event) {
          return event is Map;
        })
        .map((Object? event) {
          return LiveSmsPayment.fromNative(event! as Map<dynamic, dynamic>);
        });
  }

  /// Messages captured since the app last drained the queue.
  Future<List<LiveSmsPayment>> consumePending() async {
    if (!isSupported) return const <LiveSmsPayment>[];

    try {
      final Object? result = await _methods.invokeMethod<Object?>(
        'consumePending',
      );
      if (result is! List) return const <LiveSmsPayment>[];

      return result
          .whereType<Map>()
          .map((Map row) => LiveSmsPayment.fromNative(row))
          .where((LiveSmsPayment payment) => payment.isInflow)
          .where((LiveSmsPayment payment) => payment.amountMinor > 0)
          .toList(growable: false);
    } on MissingPluginException {
      // Desktop and widget tests do not register the Android channel.
      return const <LiveSmsPayment>[];
    } on PlatformException {
      return const <LiveSmsPayment>[];
    }
  }

  /// Turns the native receiver on or off. Off is used while signed out so no
  /// message can be stored for the next account.
  Future<void> setTrackingEnabled(bool enabled) async {
    if (!isSupported) return;

    try {
      await _methods.invokeMethod<void>('setTrackingEnabled', <String, dynamic>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // No native receiver on this platform.
    } on PlatformException {
      // The Dart-side prompt still works while the app is open.
    }
  }

  /// Drops anything still queued. Called on sign-out so a pending payment can
  /// never be shown to the next person who uses the phone.
  Future<void> clearPending() async {
    if (!isSupported) return;

    try {
      await _methods.invokeMethod<void>('clearPending');
    } on MissingPluginException {
      // Nothing to clear on a platform without the receiver.
    } on PlatformException {
      // Best effort: logout must not fail because a queue could not be cleared.
    }
  }
}
