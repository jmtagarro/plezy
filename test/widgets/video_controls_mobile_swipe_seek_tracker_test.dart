import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/video_controls/helpers/mobile_edge_adjustment_tracker.dart';
import 'package:plezy/widgets/video_controls/helpers/mobile_swipe_seek_tracker.dart';

void main() {
  const size = Size(1000, 600);

  MobileSwipeSeekTracker tracker() => MobileSwipeSeekTracker(slop: 10, dominance: 1.5);

  group('direction lock', () {
    test('locks horizontal once sideways travel passes the slop and dominates', () {
      final t = tracker();
      expect(t.pointerDown(1, const Offset(500, 300), size, enabled: true).type, MobileSwipeSeekEventType.none);
      expect(t.pointerMove(1, const Offset(506, 301)).type, MobileSwipeSeekEventType.none);

      final event = t.pointerMove(1, const Offset(512, 302));
      expect(event.type, MobileSwipeSeekEventType.activated);
      expect(event.forward, isTrue);
      expect(t.isActive, isTrue);
    });

    test('a leftward lock reports a backward direction', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      final event = t.pointerMove(1, const Offset(488, 300));
      expect(event.type, MobileSwipeSeekEventType.activated);
      expect(event.forward, isFalse);
    });

    test('a vertical start cancels and never turns into a seek', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      // Nothing was active, so there is nothing for the caller to undo.
      expect(t.pointerMove(1, const Offset(501, 280)).type, MobileSwipeSeekEventType.cancelled);
      expect(t.pointerMove(1, const Offset(700, 280)).type, MobileSwipeSeekEventType.none);
      expect(t.pointerUp(1, const Offset(700, 280)).type, MobileSwipeSeekEventType.none);
      expect(t.isActive, isFalse);
    });

    test('a diagonal start belongs to neither direction', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      expect(t.pointerMove(1, const Offset(512, 290)).type, MobileSwipeSeekEventType.cancelled);
      expect(t.pointerMove(1, const Offset(800, 290)).type, MobileSwipeSeekEventType.none);
    });

    test('once locked, vertical travel is ignored', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      expect(t.pointerMove(1, const Offset(512, 300)).type, MobileSwipeSeekEventType.activated);

      final event = t.pointerMove(1, const Offset(612, 550));
      expect(event.type, MobileSwipeSeekEventType.update);
      expect(event.deltaFraction, closeTo(0.1, 1e-9));
    });

    test('travel is measured from the lock point, not the touch-down', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      t.pointerMove(1, const Offset(515, 300));
      expect(t.pointerMove(1, const Offset(515, 300)).deltaFraction, 0.0);
      expect(t.pointerUp(1, const Offset(265, 300)).deltaFraction, closeTo(-0.25, 1e-9));
    });

    test('locks exactly where the edge tracker gives up, and vice versa', () {
      // Same slop and dominance on both: any one drag can activate at most one.
      final edge = MobileEdgeAdjustmentTracker(verticalSlop: 10, verticalDominance: 1.5);
      const moves = [Offset(15, 4), Offset(4, 15), Offset(12, 9), Offset(9, 12), Offset(15, 10), Offset(10, 15)];
      for (final move in moves) {
        final seek = tracker()..pointerDown(1, const Offset(40, 300), size, enabled: true);
        edge.cancel();
        edge.pointerDown(1, const Offset(40, 300), size);
        final seekEvent = seek.pointerMove(1, const Offset(40, 300) + move);
        final edgeEvent = edge.pointerMove(1, const Offset(40, 300) + move);
        final bothActivated =
            seekEvent.type == MobileSwipeSeekEventType.activated &&
            edgeEvent.type == MobileEdgeAdjustmentEventType.activated;
        expect(bothActivated, isFalse, reason: 'move $move');
      }
    });
  });

  group('ending and cancelling', () {
    test('lifting an active drag ends it with its travel', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      t.pointerMove(1, const Offset(520, 300));
      final event = t.pointerUp(1, const Offset(620, 300));
      expect(event.type, MobileSwipeSeekEventType.ended);
      expect(event.deltaFraction, closeTo(0.1, 1e-9));
      expect(t.isActive, isFalse);
    });

    test('lifting before the lock is just a tap', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      expect(t.pointerUp(1, const Offset(503, 300)).type, MobileSwipeSeekEventType.none);
    });

    test('a second finger cancels an active drag and blocks until all fingers lift', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      t.pointerMove(1, const Offset(520, 300));

      final event = t.pointerDown(2, const Offset(700, 300), size, enabled: true);
      expect(event.type, MobileSwipeSeekEventType.cancelled);
      expect(event.wasActive, isTrue);
      expect(t.pointerMove(1, const Offset(800, 300)).type, MobileSwipeSeekEventType.none);

      t.pointerUp(2, const Offset(700, 300));
      // Finger 1 is still down: a fresh finger is still blocked.
      expect(t.pointerDown(3, const Offset(500, 300), size, enabled: true).type, MobileSwipeSeekEventType.none);
      expect(t.pointerMove(3, const Offset(600, 300)).type, MobileSwipeSeekEventType.none);
      t.pointerUp(1, const Offset(800, 300));
      t.pointerUp(3, const Offset(600, 300));

      t.pointerDown(4, const Offset(500, 300), size, enabled: true);
      expect(t.pointerMove(4, const Offset(520, 300)).type, MobileSwipeSeekEventType.activated);
    });

    test('a pointer cancel reports whether the drag was active', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      t.pointerMove(1, const Offset(520, 300));
      final event = t.pointerCancel(1);
      expect(event.type, MobileSwipeSeekEventType.cancelled);
      expect(event.wasActive, isTrue);
    });

    test('cancel() drops tracking and every remembered pointer', () {
      final t = tracker()..pointerDown(1, const Offset(500, 300), size, enabled: true);
      t.pointerMove(1, const Offset(520, 300));
      expect(t.cancel().wasActive, isTrue);
      expect(t.isActive, isFalse);
      expect(t.cancel().type, MobileSwipeSeekEventType.none);
    });

    test('a disabled finger tracks nothing but still blocks a second one', () {
      final t = tracker();
      expect(t.pointerDown(1, const Offset(500, 300), size, enabled: false).type, MobileSwipeSeekEventType.none);
      expect(t.pointerMove(1, const Offset(700, 300)).type, MobileSwipeSeekEventType.none);
      t.pointerDown(2, const Offset(300, 300), size, enabled: true);
      expect(t.pointerMove(2, const Offset(100, 300)).type, MobileSwipeSeekEventType.none);
    });
  });

  group('swipeSeekOffset', () {
    const long = Duration(minutes: 45);

    test('the full width is 90 seconds', () {
      expect(swipeSeekOffset(fraction: 1, duration: long), const Duration(seconds: 90));
      expect(swipeSeekOffset(fraction: -1, duration: long), const Duration(seconds: -90));
    });

    test('eases in: half the width is well under half the range', () {
      // (0.5 + 0.25) / 2 * 90 = 33.75
      expect(swipeSeekOffset(fraction: 0.5, duration: long), const Duration(seconds: 34));
      expect(swipeSeekOffset(fraction: 0.25, duration: long), const Duration(seconds: 14));
    });

    test('is symmetric, monotonic and whole-second', () {
      var previous = Duration.zero;
      for (var i = 1; i <= 100; i++) {
        final f = i / 100;
        final forward = swipeSeekOffset(fraction: f, duration: long);
        expect(swipeSeekOffset(fraction: -f, duration: long), -forward);
        expect(forward >= previous, isTrue, reason: 'f=$f');
        expect(forward.inMilliseconds % 1000, 0);
        previous = forward;
      }
    });

    test('a short clip spends the whole width on its own length', () {
      const clip = Duration(seconds: 20);
      expect(swipeSeekOffset(fraction: 1, duration: clip), clip);
      // (0.5 + 0.25) / 2 * 20 = 7.5
      expect(swipeSeekOffset(fraction: 0.5, duration: clip), const Duration(seconds: 8));
    });

    test('no duration or no travel is no offset', () {
      expect(swipeSeekOffset(fraction: 0.5, duration: Duration.zero), Duration.zero);
      expect(swipeSeekOffset(fraction: 0, duration: long), Duration.zero);
    });

    test('travel beyond the width is held at the full range', () {
      expect(swipeSeekOffset(fraction: 1.4, duration: long), const Duration(seconds: 90));
    });
  });
}
