import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A two-sided "slide to confirm" control.
///
/// Swipe right for cash, swipe left to choose a mobile-money payment. The drag
/// snaps back after the action fires, so the bar is reusable if the sale fails.
///
/// When a payment message is already attached, the labels name the real method
/// ("Confirm bKash") and the cash side can be disabled, so the owner never has
/// to choose a payment type the app already knows.
class SwipeConfirmBar extends StatefulWidget {
  const SwipeConfirmBar({
    super.key,
    required this.enabled,
    required this.busy,
    required this.onCash,
    required this.onDigital,
    this.cashEnabled = true,
    this.digitalEnabled = true,
    this.cashLabel = 'Cash',
    this.digitalLabel = 'Mobile money',
    this.hint,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onCash;
  final VoidCallback onDigital;
  final bool cashEnabled;
  final bool digitalEnabled;
  final String cashLabel;
  final String digitalLabel;

  /// Sentence under the bar. Defaults to the two-sided instruction.
  final String? hint;

  @override
  State<SwipeConfirmBar> createState() => _SwipeConfirmBarState();
}

class _SwipeConfirmBarState extends State<SwipeConfirmBar> {
  static const double _threshold = 64;
  static const double _maxDrag = 110;

  double _drag = 0;

  bool get _canDrag => widget.enabled && !widget.busy;

  void _finish() {
    final double drag = _drag;
    setState(() => _drag = 0);

    if (drag >= _threshold && widget.cashEnabled) {
      widget.onCash();
    } else if (drag <= -_threshold && widget.digitalEnabled) {
      widget.onDigital();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Semantics(
      label: widget.hint ?? 'Swipe right for cash, swipe left for mobile money',
      button: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: _canDrag
                ? (DragUpdateDetails details) => setState(
                    () => _drag = (_drag + details.delta.dx).clamp(
                      widget.digitalEnabled ? -_maxDrag : 0,
                      widget.cashEnabled ? _maxDrag : 0,
                    ),
                  )
                : null,
            onHorizontalDragEnd: _canDrag
                ? (DragEndDetails details) => _finish()
                : null,
            child: Container(
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: <Color>[
                    GreenBizTheme.inflow.withValues(alpha: 0.16),
                    theme.colorScheme.primary.withValues(alpha: 0.16),
                  ],
                ),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: widget.cashEnabled
                              ? Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.payments_outlined,
                                      size: 18,
                                      color: GreenBizTheme.inflow,
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        widget.cashLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: GreenBizTheme.inflow,
                                            ),
                                      ),
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                        Expanded(
                          child: widget.digitalEnabled
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: <Widget>[
                                    Flexible(
                                      child: Text(
                                        widget.digitalLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.end,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: theme.colorScheme.primary,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.phone_android_rounded,
                                      size: 18,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(_drag, 0),
                    child: Container(
                      height: 46,
                      width: 56,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(13),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: widget.busy
                          ? const Center(
                              child: SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Icon(
                              !widget.cashEnabled
                                  ? Icons.chevron_left_rounded
                                  : !widget.digitalEnabled
                                  ? Icons.chevron_right_rounded
                                  : _drag < 0
                                  ? Icons.chevron_left_rounded
                                  : Icons.chevron_right_rounded,
                              color: theme.colorScheme.primary,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.busy
                ? 'Recording sale…'
                : widget.hint ??
                      'Swipe right for cash · swipe left for mobile money',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
