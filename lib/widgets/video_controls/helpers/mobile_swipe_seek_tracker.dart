import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/gestures.dart' show kTouchSlop;

/// Seek range of a drag across the whole surface width, before the item's own
/// duration caps it.
const Duration kSwipeSeekFullWidthRange = Duration(seconds: 90);

/// Seek offset for a horizontal drag of [fraction] of the surface width.
///
/// The range is [kSwipeSeekFullWidthRange] capped at [duration], so a short
/// clip spends the whole width on its own length instead of a few pixels. The
/// curve `(|f| + f²) / 2` starts at half the linear slope — fine control for
/// the common short rewind — and still reaches the full range at full width.
/// Whole seconds, matching the badge's granularity.
Duration swipeSeekOffset({required double fraction, required Duration duration}) {
  final rangeMs = math.min(kSwipeSeekFullWidthRange.inMilliseconds, duration.inMilliseconds);
  if (rangeMs <= 0 || fraction == 0) return Duration.zero;
  final f = fraction.abs().clamp(0.0, 1.0);
  final shaped = (f + f * f) / 2;
  final seconds = (rangeMs * shaped / 1000).round();
  return Duration(seconds: fraction.isNegative ? -seconds : seconds);
}

enum MobileSwipeSeekEventType { none, activated, update, ended, cancelled }

class MobileSwipeSeekEvent {
  const MobileSwipeSeekEvent._(this.type, {this.deltaFraction = 0.0, this.wasActive = false, this.forward = true});

  const MobileSwipeSeekEvent.none() : this._(MobileSwipeSeekEventType.none);

  const MobileSwipeSeekEvent.activated({required bool forward})
    : this._(MobileSwipeSeekEventType.activated, forward: forward);

  const MobileSwipeSeekEvent.update(double deltaFraction)
    : this._(MobileSwipeSeekEventType.update, deltaFraction: deltaFraction);

  const MobileSwipeSeekEvent.ended(double deltaFraction)
    : this._(MobileSwipeSeekEventType.ended, deltaFraction: deltaFraction);

  const MobileSwipeSeekEvent.cancelled({bool wasActive = false})
    : this._(MobileSwipeSeekEventType.cancelled, wasActive: wasActive);

  final MobileSwipeSeekEventType type;

  /// Horizontal travel since the lock engaged, as a fraction of the surface
  /// width. Positive is rightward (forward).
  final double deltaFraction;
  final bool wasActive;

  /// Direction of the movement that engaged the lock.
  final bool forward;
}

/// Raw-pointer recogniser for a one-finger horizontal swipe over the player.
///
/// The mirror image of `MobileEdgeAdjustmentTracker`, with the same slop and
/// dominance: it locks horizontal exactly where the edge tracker gives up, and
/// gives up exactly where the edge tracker locks vertical, so the two can never
/// both own one drag. Once locked, vertical travel is ignored. A second finger
/// ends tracking until every finger is up, which keeps pinches out.
///
/// It runs outside the gesture arena like the edge tracker, so tap, double tap,
/// long press, pinch and the timeline keep their recognisers untouched.
class MobileSwipeSeekTracker {
  MobileSwipeSeekTracker({this.slop = kTouchSlop, this.dominance = 1.5});

  final double slop;
  final double dominance;

  final Set<int> _activePointers = <int>{};
  int? _trackedPointer;
  Offset? _startPosition;
  double? _lockX;
  double? _width;
  bool _blockedUntilAllPointersUp = false;

  bool get isActive => _lockX != null;

  /// [enabled] false still registers the pointer, so a finger that may not
  /// seek keeps counting towards multi-touch blocking.
  MobileSwipeSeekEvent pointerDown(int pointer, Offset position, Size size, {required bool enabled}) {
    _activePointers.add(pointer);
    if (_blockedUntilAllPointersUp) return const MobileSwipeSeekEvent.none();
    if (_activePointers.length > 1) return _cancelTracking(clearPointers: false, blockUntilAllPointersUp: true);
    if (_trackedPointer != null || !enabled || size.width <= 0) return const MobileSwipeSeekEvent.none();

    _trackedPointer = pointer;
    _startPosition = position;
    _width = size.width;
    _lockX = null;
    return const MobileSwipeSeekEvent.none();
  }

  MobileSwipeSeekEvent pointerMove(int pointer, Offset position) {
    if (pointer != _trackedPointer) return const MobileSwipeSeekEvent.none();
    final start = _startPosition;
    if (start == null) return const MobileSwipeSeekEvent.none();

    if (!isActive) {
      final delta = position - start;
      final absDx = delta.dx.abs();
      final absDy = delta.dy.abs();
      if (absDy >= slop && absDy > absDx * dominance) {
        return _cancelTracking(clearPointers: false, blockUntilAllPointersUp: true);
      }
      if (absDx < slop) return const MobileSwipeSeekEvent.none();
      if (absDx <= absDy * dominance) {
        return _cancelTracking(clearPointers: false, blockUntilAllPointersUp: true);
      }
      // Measure from here, so the readout starts at zero instead of jumping
      // by the slop.
      _lockX = position.dx;
      return MobileSwipeSeekEvent.activated(forward: delta.dx > 0);
    }

    return MobileSwipeSeekEvent.update(_deltaFraction(position));
  }

  MobileSwipeSeekEvent pointerUp(int pointer, Offset position) {
    _activePointers.remove(pointer);
    if (_activePointers.isEmpty) _blockedUntilAllPointersUp = false;
    if (pointer != _trackedPointer) return const MobileSwipeSeekEvent.none();

    final wasActive = isActive;
    final deltaFraction = wasActive ? _deltaFraction(position) : 0.0;
    _resetTracking(clearPointers: false);
    if (!wasActive) return const MobileSwipeSeekEvent.none();
    return MobileSwipeSeekEvent.ended(deltaFraction);
  }

  MobileSwipeSeekEvent pointerCancel(int pointer) {
    _activePointers.remove(pointer);
    if (_activePointers.isEmpty) _blockedUntilAllPointersUp = false;
    if (pointer != _trackedPointer) return const MobileSwipeSeekEvent.none();
    return _cancelTracking(clearPointers: false, blockUntilAllPointersUp: _activePointers.isNotEmpty);
  }

  MobileSwipeSeekEvent cancel() => _cancelTracking(clearPointers: true, blockUntilAllPointersUp: false);

  MobileSwipeSeekEvent _cancelTracking({required bool clearPointers, required bool blockUntilAllPointersUp}) {
    final hadTracking = _trackedPointer != null;
    final wasActive = isActive;
    _resetTracking(clearPointers: clearPointers);
    if (blockUntilAllPointersUp && _activePointers.isNotEmpty) _blockedUntilAllPointersUp = true;
    if (!hadTracking) return const MobileSwipeSeekEvent.none();
    return MobileSwipeSeekEvent.cancelled(wasActive: wasActive);
  }

  double _deltaFraction(Offset position) {
    final lockX = _lockX;
    final width = _width;
    if (lockX == null || width == null || width <= 0) return 0.0;
    return (position.dx - lockX) / width;
  }

  void _resetTracking({required bool clearPointers}) {
    _trackedPointer = null;
    _startPosition = null;
    _lockX = null;
    _width = null;
    if (clearPointers) {
      _activePointers.clear();
      _blockedUntilAllPointersUp = false;
    }
  }
}
