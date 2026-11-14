import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
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

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// A player opened from a sequence, such as the photos and clips of an album,
/// shows next and previous only where the sequence has an item, and its track
/// keys step the sequence. Any other player keeps its buttons and keys as
/// they are.
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
  }) async {
    if (desktop) PlatformDetector.debugSetIsDesktopOSOverride(true);
    final controls = PlexVideoControls(
      player: player,
      volumeController: volume,
      metadata: testMediaItem(id: 'clip'),
      toastController: toast,
      chromeController: chrome,
      hasFirstFrame: hasFirstFrame,
      canNavigateMediaItems: true,
      sequenceNavigation: sequenceNavigation,
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
              body: SizedBox(width: 1280, height: 720, child: Focus(autofocus: true, child: controls)),
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

  for (final desktop in [false, true]) {
    final surface = desktop ? 'desktop' : 'phone';

    testWidgets('$surface: in a sequence only the way with an item has a button', (tester) async {
      var nexts = 0;
      await pumpControls(tester, desktop: desktop, sequenceNavigation: true, onNext: () => nexts++);

      expect(button(t.videoControls.nextButton), findsOneWidget);
      expect(button(t.videoControls.previousButton), findsNothing);

      await tester.tap(button(t.videoControls.nextButton));
      await tester.pump();
      expect(nexts, 1);
      await finish(tester);
    });

    testWidgets('$surface: outside a sequence both buttons stay, the unavailable one disabled', (tester) async {
      await pumpControls(tester, desktop: desktop, sequenceNavigation: false, onNext: () {});

      expect(button(t.videoControls.nextButton), findsOneWidget);
      expect(button(t.videoControls.previousButton), findsOneWidget);
      await finish(tester);
    });
  }

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
