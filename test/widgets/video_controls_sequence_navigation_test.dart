import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/video_player/player_sequence_link.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/desktop_video_controls.dart';
import 'package:plezy/widgets/video_controls/mobile_video_controls.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_control_button.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/circular_control_button.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/sequence_control_bar.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// A player opened from a sequence, such as the photos and clips of an album,
/// steps the sequence with next, previous and its track keys. On a phone it
/// trades the large centre controls for a compact bar, and its chrome keeps
/// the photo viewer's timing. Any other player keeps its buttons, keys and
/// chrome as they are.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RemotePlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late ValueNotifier<bool> hasFirstFrame;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(null);
    await TvDetectionService.getInstance(forceTv: false);
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RemotePlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    hasFirstFrame = ValueNotifier<bool>(true);
  });

  tearDown(() async {
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    hasFirstFrame.dispose();
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  Future<void> pumpControls(
    WidgetTester tester, {
    required bool desktop,
    required bool sequenceNavigation,
    VoidCallback? onNext,
    VoidCallback? onPrevious,
    ValueListenable<SequenceMode?>? sequenceMode,
    Size size = const Size(1280, 720),
  }) async {
    if (desktop) PlatformDetector.debugSetIsDesktopOSOverride(true);
    if (size != const Size(1280, 720)) {
      tester.view
        ..physicalSize = size * 3
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }
    final controls = PlexVideoControls(
      player: player,
      volumeController: volume,
      metadata: testMediaItem(id: 'clip'),
      toastController: toast,
      chromeController: chrome,
      hasFirstFrame: hasFirstFrame,
      canNavigateMediaItems: true,
      sequenceNavigation: sequenceNavigation,
      sequenceMode: sequenceMode,
      onNext: onNext,
      onPrevious: onPrevious,
    );
    await tester.pumpWidget(
      InputModeTracker(
        child: MultiProvider(
          providers: [
            Provider<AppDatabase>.value(value: database),
            ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
          ],
          child: MaterialApp(
            theme: ThemeData(
              platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
              extensions: const [testMonoTokens],
            ),
            home: Scaffold(
              body: SizedBox.fromSize(
                size: size,
                child: Focus(autofocus: true, child: controls),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    chrome.show();
    await tester.pumpAndSettle();
    expect(find.byType(desktop ? DesktopVideoControls : MobileVideoControls), findsOneWidget);
  }

  /// Unmounts the controls and lets their timers run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) =>
        (widget is CircularControlButton && widget.semanticLabel == label) ||
        (widget is VideoControlButton && widget.semanticLabel == label),
  );

  testWidgets('desktop: in a sequence only the way with an item has a button', (tester) async {
    var nexts = 0;
    await pumpControls(tester, desktop: true, sequenceNavigation: true, onNext: () => nexts++);

    expect(button(t.videoControls.nextButton), findsOneWidget);
    expect(button(t.videoControls.previousButton), findsNothing);

    await tester.tap(button(t.videoControls.nextButton));
    await tester.pump();
    expect(nexts, 1);
    await finish(tester);
  });

  for (final desktop in [false, true]) {
    final surface = desktop ? 'desktop' : 'phone';

    testWidgets('$surface: outside a sequence both buttons stay, the unavailable one disabled', (tester) async {
      await pumpControls(tester, desktop: desktop, sequenceNavigation: false, onNext: () {});

      expect(button(t.videoControls.nextButton), findsOneWidget);
      expect(button(t.videoControls.previousButton), findsOneWidget);
      await finish(tester);
    });
  }

  group('phone sequence bar', () {
    Finder inBar(Finder finder) => find.descendant(of: find.byType(SequenceControlBar), matching: finder);

    testWidgets('takes the place of the centre controls, with a compact timeline', (tester) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: true, onNext: () {});

      expect(find.byType(CircularControlButton), findsNothing);
      expect(find.byType(SequenceControlBar), findsOneWidget);
      final timeline = tester.widget<VideoTimelineBar>(inBar(find.byType(VideoTimelineBar)));
      expect(timeline.horizontalLayout, isTrue);
      expect(find.byType(VideoTimelineBar), findsOneWidget, reason: 'the full timeline is not shown as well');
      await finish(tester);
    });

    testWidgets('keeps previous and next in place, disabled where there is nowhere to go', (tester) async {
      var nexts = 0;
      await pumpControls(tester, desktop: false, sequenceNavigation: true, onNext: () => nexts++);

      final previous = tester.widget<VideoControlButton>(inBar(button(t.tooltips.previousItem)));
      expect(previous.onPressed, isNull);
      final play = inBar(button(t.videoControls.pauseButton));
      expect(
        tester.getCenter(play).dx,
        moreOrLessEquals(tester.getCenter(find.byType(SequenceControlBar)).dx),
        reason: 'the play button does not shift for the missing previous item',
      );

      await tester.tap(inBar(button(t.tooltips.nextItem)));
      await tester.pump();
      expect(nexts, 1);
      await finish(tester);
    });

    testWidgets('plays and pauses, and follows the player', (tester) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: true);

      await tester.tap(inBar(button(t.videoControls.pauseButton)));
      await tester.pump();
      expect(player.toggles, 1);

      player.setPlaying(false);
      await tester.pump();
      expect(inBar(button(t.videoControls.playButton)), findsOneWidget);
      await finish(tester);
    });

    testWidgets('names previous and next for the sequence, not as episodes', (tester) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: true, onNext: () {});

      expect(inBar(button(t.tooltips.previousItem)), findsOneWidget);
      expect(inBar(button(t.tooltips.nextItem)), findsOneWidget);
      expect(button(t.videoControls.nextButton), findsNothing);
      await finish(tester);
    });

    testWidgets('shows what the sequence goes through, and its switches work while the clip plays', (tester) async {
      final calls = <String>[];
      final mode = ValueNotifier<SequenceMode?>(
        SequenceMode(
          label: 'Shuffle · Holidays',
          album: 'Summer',
          onOpenAlbum: () => calls.add('album'),
          shuffling: true,
          onToggleShuffle: () => calls.add('toggle'),
        ),
      );
      addTearDown(mode.dispose);
      await pumpControls(tester, desktop: false, sequenceNavigation: true, sequenceMode: mode);

      expect(inBar(find.text('Shuffle · Holidays')), findsOneWidget);
      await tester.tap(inBar(find.text('Summer')));
      await tester.pump();
      expect(calls, ['album']);

      mode.value = SequenceMode(label: 'Album · Summer · 2 / 3', onToggleShuffle: () => calls.add('toggle'));
      await tester.pump();
      expect(inBar(find.text('Album · Summer · 2 / 3')), findsOneWidget);
      expect(inBar(find.text('Summer')), findsNothing);
      await tester.tap(inBar(find.byIcon(Symbols.shuffle_rounded)));
      await tester.pump();
      expect(calls, ['album', 'toggle']);
      await finish(tester);
    });

    for (final size in [const Size(915, 412), const Size(800, 360)]) {
      testWidgets('on a ${size.width.round()}x${size.height.round()} phone in landscape, one row under the '
          'timeline keeps the bar within a third of the height', (tester) async {
        final mode = ValueNotifier<SequenceMode?>(
          SequenceMode(label: 'Shuffle · Holidays', album: 'Summer', onOpenAlbum: () {}, onToggleShuffle: () {}),
        );
        addTearDown(mode.dispose);
        await pumpControls(tester, desktop: false, sequenceNavigation: true, sequenceMode: mode, size: size);

        final label = tester.getCenter(inBar(find.text('Shuffle · Holidays')));
        final play = tester.getCenter(inBar(button(t.videoControls.pauseButton)));
        expect(label.dy, moreOrLessEquals(play.dy, epsilon: 1), reason: 'the mode shares the row of the buttons');
        expect(size.height - tester.getRect(find.byType(SequenceControlBar)).top, lessThan(size.height / 3));
        await finish(tester);
      });
    }

    testWidgets('on a phone in portrait, the mode has a row of its own', (tester) async {
      final mode = ValueNotifier<SequenceMode?>(const SequenceMode(label: 'Shuffle · Holidays'));
      addTearDown(mode.dispose);
      await pumpControls(
        tester,
        desktop: false,
        sequenceNavigation: true,
        sequenceMode: mode,
        size: const Size(412, 915),
      );

      final label = tester.getCenter(inBar(find.text('Shuffle · Holidays')));
      final timeline = tester.getCenter(inBar(find.byType(VideoTimelineBar)));
      final play = tester.getCenter(inBar(button(t.videoControls.pauseButton)));
      expect(label.dy, lessThan(timeline.dy));
      expect(timeline.dy, lessThan(play.dy));
      await finish(tester);
    });

    testWidgets('outside a sequence the centre controls and full timeline are unchanged', (tester) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: false, onNext: () {});

      expect(find.byType(SequenceControlBar), findsNothing);
      expect(find.byType(CircularControlButton), findsNWidgets(3));
      expect(tester.widget<VideoTimelineBar>(find.byType(VideoTimelineBar)).horizontalLayout, isFalse);
      await finish(tester);
    });
  });

  group('chrome timing', () {
    testWidgets('a sequence clip hides its bars after the photo viewer delay, and keeps them while paused', (
      tester,
    ) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: true);
      // Playing from the start; the clock starts now.
      chrome.restartAutoHideForCurrentPlaybackState();

      await tester.pump(PlayerSequenceLink.chromeHideDelay - const Duration(milliseconds: 100));
      expect(chrome.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(chrome.controlsVisible, isFalse);
      await tester.pumpAndSettle();

      player.setPlaying(false);
      chrome.show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(chrome.controlsVisible, isTrue, reason: 'paused, the bars stay');
      await finish(tester);
    });

    testWidgets('a desktop sequence clip takes the same delay', (tester) async {
      await pumpControls(tester, desktop: true, sequenceNavigation: true);
      // Playing from the start; the clock starts now.
      chrome.restartAutoHideForCurrentPlaybackState();

      await tester.pump(PlayerSequenceLink.chromeHideDelay - const Duration(milliseconds: 100));
      expect(chrome.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(chrome.controlsVisible, isFalse);
      await finish(tester);
    });

    testWidgets('any other player still hides its paused chrome', (tester) async {
      await pumpControls(tester, desktop: false, sequenceNavigation: false);
      player.setPlaying(false);
      chrome.show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(chrome.controlsVisible, isFalse);
      await finish(tester);
    });
  });

  group('track keys', () {
    final steps = <String>[];
    setUp(steps.clear);

    Future<void> pressTrackKeys(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
      await tester.pump();
    }

    testWidgets('step the sequence where it has an item', (tester) async {
      await pumpControls(
        tester,
        desktop: true,
        sequenceNavigation: true,
        onNext: () => steps.add('next'),
        onPrevious: () => steps.add('previous'),
      );
      await pressTrackKeys(tester);
      expect(steps, ['next', 'previous']);
      await finish(tester);
    });

    testWidgets('keep moving within the clip where the sequence has nothing', (tester) async {
      await pumpControls(tester, desktop: true, sequenceNavigation: true, onNext: () => steps.add('next'));
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
      await tester.pump();
      expect(steps, isEmpty);
      expect(player.seeks, isNotEmpty, reason: 'the key skipped back within the clip');
      await finish(tester);
    });

    testWidgets('outside a sequence still move within the item, as before', (tester) async {
      await pumpControls(
        tester,
        desktop: true,
        sequenceNavigation: false,
        onNext: () => steps.add('next'),
        onPrevious: () => steps.add('previous'),
      );
      await pressTrackKeys(tester);
      expect(steps, isEmpty);
      await finish(tester);
    });
  });
}

class _RemotePlayer implements Player {
  bool _playing = true;
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();

  void setPlaying(bool playing) {
    _playing = playing;
    _playingController.add(playing);
  }

  Future<void> close() => _playingController.close();

  @override
  Future<void> setVolume(double volume) async {}

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    playing: _playing,
    position: const Duration(minutes: 5),
    duration: const Duration(minutes: 45),
    seekable: true,
  );

  final seeks = <Duration>[];
  int toggles = 0;

  @override
  Future<void> playOrPause() async => toggles++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: _playingController.stream,
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
