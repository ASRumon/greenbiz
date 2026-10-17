import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A two-sided "slide to confirm" control.
///
/// Swipe right for cash, swipe left to choose a mobile-money payment. The drag
/// snaps back after the action fires, so the bar is reusable if the sale fails.
class SwipeConfirmBar extends StatefulWidget {
  const SwipeConfirmBar({
    super.key,
    required this.enabled,
    required this.busy,
    required this.onCash,
    required this.onDigital,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onCash;
  final VoidCallback onDigital;

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

    if (drag >= _threshold) {
      widget.onCash();
    } else if (drag <= -_threshold) {
      widget.onDigital();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Semantics(
      label: 'Swipe right for cash, swipe left for mobile money',
      button: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: _canDrag
                ? (DragUpdateDetails details) => setState(
                    () => _drag = (_drag + details.delta.dx).clamp(
                      -_maxDrag,
                      _maxDrag,
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
                        Icon(
                          Icons.payments_outlined,
                          size: 18,
                          color: GreenBizTheme.inflow,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Cash',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: GreenBizTheme.inflow,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Mobile money',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.phone_android_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
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
                              _drag < 0
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
                : 'Swipe right for cash · swipe left for mobile money',
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
