import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/device_adjustment_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/double_tap_feedback.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// VLC-style horizontal swipe-to-seek on the touch player surface: an opt-in
/// gesture that previews its target while the finger is down (direct play
/// only) and commits one exact seek on release, without disturbing any of the
/// surface's other touch gestures.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const adjustmentChannel = MethodChannel('com.plezy/device_adjustment');

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late SettingsService settings;
  late List<MethodCall> adjustmentCalls;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();

    // Phone layout: the touch pointer pipeline is wired only when
    // isMobile(context) && !isTV().
    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    adjustmentCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(adjustmentChannel, (
      call,
    ) async {
      adjustmentCalls.add(call);
      return switch (call.method) {
        'getBrightness' || 'getMediaVolume' => 0.5,
        _ => null,
      };
    });

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(adjustmentChannel, null);
    TvDetectionService.debugSetAppleTVOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  const surface = Size(800, 600);

  Future<void> pumpControls(
    WidgetTester tester, {
    bool isTranscoding = false,
    bool Function(Duration)? onSeekPreviewRequested,
    bool chromeVisible = false,
  }) async {
    DeviceAdjustmentService.instance.resetForTesting();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: surface.width,
              height: surface.height,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'swipe-seek'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                canControl: true,
                isTranscoding: isTranscoding,
                onSeekPreviewRequested: onSeekPreviewRequested,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    if (chromeVisible) {
      chrome.show();
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      chrome.cancelAutoHide();
      expect(chrome.controlsVisible, isTrue);
    } else {
      chrome.hide();
      chrome.markControlsHidden();
      await tester.pump();
      expect(chrome.controlsVisible, isFalse);
    }
  }

  Future<void> settle(WidgetTester tester) async {
    chrome.cancelAutoHide();
    toast.hide();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Offset at(WidgetTester tester, double x, double y) =>
      tester.getRect(find.byType(PlexVideoControls)).topLeft + Offset(x, y);

  /// Down in the middle of the picture, then 20px right to engage the lock at
  /// x=420. Every later x is measured from there: +200px (a quarter of the
  /// 800px surface) is (0.25 + 0.0625) / 2 * 90 s = 14 s.
  Future<TestGesture> lockedSwipe(WidgetTester tester, {double y = 300}) async {
    final gesture = await tester.startGesture(at(tester, 400, y));
    await tester.pump();
    await gesture.moveTo(at(tester, 420, y));
    await tester.pump();
    return gesture;
  }

  Future<void> enableSwipeSeek() => settings.write(SettingsService.gestureSwipeSeek, true);

  Finder badge() => find.byType(DoubleTapFeedback);

  testWidgets('the gesture is off by default', (tester) async {
    await pumpControls(tester);

    final gesture = await lockedSwipe(tester);
    await gesture.moveTo(at(tester, 620, 300));
    await tester.pump();
    expect(badge(), findsNothing);
    await gesture.up();
    await tester.pump();

    expect(player.seeks, isEmpty);
    expect(player.fastSeeks, isEmpty);
    await settle(tester);
  });

  group('swipe-seek', () {
    setUp(enableSwipeSeek);

    testWidgets('previews its target while dragging and commits one exact seek on release', (tester) async {
      await pumpControls(tester);

      final gesture = await lockedSwipe(tester);
      expect(badge(), findsOneWidget, reason: 'the readout goes up with the lock');
      await gesture.moveTo(at(tester, 620, 300));
      await tester.pump();

      expect(find.text('14s'), findsOneWidget);
      expect(find.text('10:14 / 45:00'), findsOneWidget);
      expect(player.fastSeeks, [const Duration(minutes: 10, seconds: 14)]);
      expect(player.seeks, isEmpty, reason: 'nothing exact until the finger lifts');

      await gesture.up();
      await tester.pump();

      expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
      expect(find.text('10:14 / 45:00'), findsNothing, reason: 'the caption belongs to the drag');
      expect(find.text('14s'), findsOneWidget, reason: 'the amount stays up as confirmation');

      await tester.pump(const Duration(seconds: 2));
      expect(badge(), findsNothing);
      await settle(tester);
    });

    testWidgets('a leftward drag seeks back', (tester) async {
      await pumpControls(tester);

      final gesture = await lockedSwipe(tester);
      await gesture.moveTo(at(tester, 220, 300));
      await tester.pump();
      expect(find.text('9:46 / 45:00'), findsOneWidget);
      await gesture.up();
      await tester.pump();

      expect(player.seeks, [const Duration(minutes: 9, seconds: 46)]);
      await settle(tester);
    });

    testWidgets('a drag back past the start stops at 0:00 and reports only that', (tester) async {
      player.position = const Duration(seconds: 5);
      await pumpControls(tester);

      final gesture = await lockedSwipe(tester);
      await gesture.moveTo(at(tester, 220, 300));
      await tester.pump();
      expect(find.text('5s'), findsOneWidget);
      expect(find.text('0:00 / 45:00'), findsOneWidget);
      await gesture.up();
      await tester.pump();

      expect(player.seeks, [Duration.zero]);
      await settle(tester);
    });

    testWidgets('a short clip spends the width on its own length', (tester) async {
      player
        ..duration = const Duration(seconds: 30)
        ..position = Duration.zero;
      await pumpControls(tester);

      final gesture = await tester.startGesture(at(tester, 100, 300));
      await tester.pump();
      await gesture.moveTo(at(tester, 120, 300));
      await tester.pump();
      // Half the width: (0.5 + 0.25) / 2 * 30 s = 11 s, not the 34 s a
      // 90 s range would give.
      await gesture.moveTo(at(tester, 520, 300));
      await tester.pump();
      expect(find.text('0:11 / 0:30'), findsOneWidget);
      await gesture.up();
      await tester.pump();

      expect(player.seeks, [const Duration(seconds: 11)]);
      await settle(tester);
    });

    group('direction lock', () {
      testWidgets('a drag that starts vertical stays vertical', (tester) async {
        await pumpControls(tester);

        final gesture = await tester.startGesture(at(tester, 400, 300));
        await tester.pump();
        await gesture.moveTo(at(tester, 402, 340));
        await tester.pump();
        await gesture.moveTo(at(tester, 650, 340));
        await tester.pump();
        expect(badge(), findsNothing);
        await gesture.up();
        await tester.pump();

        expect(player.seeks, isEmpty);
        expect(player.fastSeeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a drag that starts horizontal ignores later vertical travel', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 520));
        await tester.pump();
        expect(find.text('10:14 / 45:00'), findsOneWidget);
        await gesture.up();
        await tester.pump();

        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });
    });

    group('cancel', () {
      testWidgets('a second finger cancels and returns a previewed picture to the origin', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        expect(player.fastSeeks, isNotEmpty);

        final second = await tester.startGesture(at(tester, 200, 300));
        await tester.pump();
        expect(badge(), findsNothing);
        expect(player.seeks, [const Duration(minutes: 10)], reason: 'back where the swipe started');

        await gesture.up();
        await second.up();
        await tester.pump(const Duration(seconds: 1));
        expect(player.seeks, [const Duration(minutes: 10)], reason: 'lifting a cancelled drag commits nothing');
        await settle(tester);
      });

      testWidgets('a pointer cancel aborts the seek', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.cancel();
        await tester.pump();

        expect(badge(), findsNothing);
        expect(player.seeks, [const Duration(minutes: 10)]);
        await settle(tester);
      });

      testWidgets('dragging back to the lock point lands where it started', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump(const Duration(milliseconds: 250));
        await gesture.moveTo(at(tester, 420, 300));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(badge(), findsNothing);
        expect(player.seeks, [const Duration(minutes: 10)]);
        await settle(tester);
      });

      testWidgets('without a preview a cancel seeks nowhere', (tester) async {
        await pumpControls(tester, onSeekPreviewRequested: (_) => false);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.cancel();
        await tester.pump();

        expect(player.seeks, isEmpty);
        await settle(tester);
      });
    });

    group('live preview', () {
      testWidgets('throttles preview seeks to one per 200 ms, always to the newest target', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        // +80px: (0.1 + 0.01) / 2 * 90 s = 5 s, previewed at once.
        await gesture.moveTo(at(tester, 500, 300));
        await tester.pump();
        expect(player.fastSeeks, [const Duration(minutes: 10, seconds: 5)]);

        // Inside the window: held back, and only the newest survives.
        await gesture.moveTo(at(tester, 600, 300));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.fastSeeks, hasLength(1));

        await tester.pump(const Duration(milliseconds: 100));
        expect(player.fastSeeks, [const Duration(minutes: 10, seconds: 5), const Duration(minutes: 10, seconds: 14)]);

        // Nothing new to show: the window lapses without another seek.
        await tester.pump(const Duration(milliseconds: 400));
        expect(player.fastSeeks, hasLength(2));

        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));
        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        expect(player.fastSeeks, hasLength(2), reason: 'a held-back preview never fires after the release');
        await settle(tester);
      });

      testWidgets('a release inside the window drops the pending preview for the exact seek', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 500, 300));
        await tester.pump();
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));

        expect(player.fastSeeks, [const Duration(minutes: 10, seconds: 5)]);
        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });

      testWidgets('routes previews through the owning screen when it supplies a handler', (tester) async {
        final requested = <Duration>[];
        await pumpControls(
          tester,
          onSeekPreviewRequested: (target) {
            requested.add(target);
            return true;
          },
        );

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(requested, [const Duration(minutes: 10, seconds: 14)]);
        expect(player.fastSeeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a transcoded stream keeps release-only seeking', (tester) async {
        await pumpControls(tester, isTranscoding: true);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('10:14 / 45:00'), findsOneWidget);
        await gesture.up();
        await tester.pump();

        expect(player.fastSeeks, isEmpty);
        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });

      testWidgets('a Watch Together session keeps release-only seeking', (tester) async {
        watchTogether.dispose();
        watchTogether = _InSessionWatchTogether();
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump(const Duration(milliseconds: 500));
        await gesture.up();
        await tester.pump();

        expect(player.fastSeeks, isEmpty);
        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });

      testWidgets('a cancelled release-only drag never seeks', (tester) async {
        await pumpControls(tester, isTranscoding: true);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.cancel();
        await tester.pump();

        expect(player.seeks, isEmpty);
        await settle(tester);
      });
    });

    group('existing gestures stay intact', () {
      Iterable<MethodCall> callsTo(String method) => adjustmentCalls.where((c) => c.method == method);

      Future<void> edgeSwipe(WidgetTester tester, {required double x}) async {
        final gesture = await tester.startGesture(at(tester, x, 400));
        await tester.pump();
        await gesture.moveTo(at(tester, x, 316));
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      testWidgets('a left-edge vertical swipe adjusts brightness and never seeks', (tester) async {
        await pumpControls(tester);
        adjustmentCalls.clear();

        await edgeSwipe(tester, x: 40);

        expect(callsTo('setBrightness'), isNotEmpty);
        expect(player.seeks, isEmpty);
        expect(player.fastSeeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a right-edge vertical swipe adjusts volume and never seeks', (tester) async {
        await pumpControls(tester);
        adjustmentCalls.clear();

        await edgeSwipe(tester, x: surface.width - 40);

        expect(callsTo('setMediaVolume'), isNotEmpty);
        expect(player.seeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a horizontal drag from an edge zone seeks instead of adjusting', (tester) async {
        await pumpControls(tester);
        adjustmentCalls.clear();

        final gesture = await tester.startGesture(at(tester, 40, 300));
        await tester.pump();
        await gesture.moveTo(at(tester, 60, 300));
        await tester.pump();
        await gesture.moveTo(at(tester, 260, 300));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(callsTo('setBrightness'), isEmpty);
        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });

      testWidgets('a double tap in a skip zone still skips', (tester) async {
        await pumpControls(tester);

        await tester.tapAt(at(tester, 700, 300));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at(tester, 700, 300));
        await tester.pump();

        expect(player.seeks, [const Duration(minutes: 10, seconds: 10)]);
        expect(player.fastSeeks, isEmpty);
        expect(find.text('10s'), findsOneWidget);
        expect(find.textContaining(' / 45:00'), findsNothing, reason: 'no swipe caption on a double tap');
        await tester.pump(const Duration(seconds: 2));
        await settle(tester);
      });

      testWidgets('a single tap still toggles the chrome', (tester) async {
        await pumpControls(tester);

        await tester.tapAt(at(tester, 400, 300));
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

        expect(chrome.controlsVisible, isTrue);
        expect(player.seeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a swipe leaves no tap behind to toggle the chrome', (tester) async {
        await pumpControls(tester);

        final gesture = await lockedSwipe(tester);
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        await gesture.up();
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

        expect(chrome.controlsVisible, isFalse);
        await settle(tester);
      });

      testWidgets('a timeline drag scrubs without starting a swipe-seek', (tester) async {
        await pumpControls(tester, chromeVisible: true);
        final slider = find.byType(TimelineSlider);
        expect(slider, findsOneWidget);
        final rect = tester.getRect(slider);

        final gesture = await tester.startGesture(rect.center);
        await tester.pump();
        await gesture.moveTo(rect.center + const Offset(30, 0));
        await tester.pump();
        await gesture.moveTo(rect.center + const Offset(150, 0));
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.textContaining(' / 45:00'), findsNothing);
        expect(player.fastSeeks, isEmpty);

        await gesture.up();
        await tester.pump(const Duration(milliseconds: 250));
        expect(player.seeks, isNotEmpty, reason: 'the timeline still scrubs');
        expect(player.fastSeeks, isEmpty);
        await settle(tester);
      });

      testWidgets('with the chrome up a drag over the picture still seeks', (tester) async {
        await pumpControls(tester, chromeVisible: true);

        final gesture = await lockedSwipe(tester, y: 220);
        await gesture.moveTo(at(tester, 620, 220));
        await tester.pump();
        expect(find.text('10:14 / 45:00'), findsOneWidget);
        await gesture.up();
        await tester.pump();

        expect(player.seeks, [const Duration(minutes: 10, seconds: 14)]);
        await settle(tester);
      });

      testWidgets('a pinch never seeks', (tester) async {
        await pumpControls(tester);

        final left = await tester.startGesture(at(tester, 350, 300), pointer: 1);
        final right = await tester.startGesture(at(tester, 450, 300), pointer: 2);
        await tester.pump();
        for (var step = 1; step <= 5; step++) {
          await left.moveTo(at(tester, 350 - step * 30.0, 300));
          await right.moveTo(at(tester, 450 + step * 30.0, 300));
          await tester.pump();
        }
        expect(badge(), findsNothing);
        await left.up();
        await right.up();
        await tester.pump(const Duration(seconds: 1));

        expect(player.seeks, isEmpty);
        expect(player.fastSeeks, isEmpty);
        await settle(tester);
      });

      testWidgets('a sideways drift during a 2x hold does not seek', (tester) async {
        await pumpControls(tester);

        final gesture = await tester.startGesture(at(tester, 400, 300));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
        expect(player.rates, [2.0]);

        await gesture.moveTo(at(tester, 420, 300));
        await tester.pump();
        await gesture.moveTo(at(tester, 620, 300));
        await tester.pump();
        expect(badge(), findsNothing);
        await gesture.up();
        await tester.pump();

        expect(player.seeks, isEmpty);
        expect(player.rates, [2.0, 1.0], reason: 'the hold still ends normally');
        await settle(tester);
      });
    });
  });
}

class _InSessionWatchTogether extends WatchTogetherProvider {
  @override
  bool get isInSession => true;
}

/// [Player] that records exact and keyframe seeks separately and applies them
/// at once, against a configurable item.
class _RecordingPlayer implements Player {
  final List<Duration> seeks = [];
  final List<Duration> fastSeeks = [];
  final List<double> rates = [];
  final StreamController<Duration?> _jumps = StreamController<Duration?>.broadcast();

  Duration position = const Duration(minutes: 10);
  Duration duration = const Duration(minutes: 45);
  double _rate = 1.0;

  Future<void> close() => _jumps.close();

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: true, position: position, duration: duration, seekable: true, rate: _rate);

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
    playheadJump: _jumps.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  /// Mirrors [PlayerBase.runSeek]: the target is written and announced at once.
  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    position = target;
    _jumps.add(target);
  }

  @override
  Future<void> seekFast(Duration target) async {
    fastSeeks.add(target);
    position = target;
    _jumps.add(target);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    _rate = rate;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
