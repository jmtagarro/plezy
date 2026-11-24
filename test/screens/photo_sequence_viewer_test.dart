import 'dart:io';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/focus/focus_theme.dart';
import 'package:plezy/focus/focusable_button.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/photo_sequence_viewer.dart';
import 'package:plezy/screens/photo_viewer_screen.dart';
import 'package:plezy/screens/video_player/player_sequence_link.dart';
import 'package:plezy/screens/video_player/wakelock_controller.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_album.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/orientation_helper.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/app_bar_back_button.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

MediaItem _item(String id, MediaKind kind, {MediaBackend backend = MediaBackend.plex}) =>
    testMediaItem(id: id, backend: backend, kind: kind, title: id, thumbPath: '/thumb/$id', serverId: 'server_1');

MediaItem _photo(String id, {MediaBackend backend = MediaBackend.plex}) => _item(id, MediaKind.photo, backend: backend);

/// [items] as a grid would hold them, with [unloaded] positions still to fetch.
/// Every fetch is recorded in [loads], and a fetch for a position in [failing]
/// fails.
PhotoSequence _sequenceOf(
  List<MediaItem> items,
  int index, {
  Set<int> unloaded = const {},
  Set<int> failing = const {},
  List<int>? loads,
}) {
  final loaded = {...unloaded};
  return PhotoSequence(
    index: index,
    photo: items[index],
    length: () => items.length,
    itemAt: (i) => loaded.contains(i) ? null : items[i],
    loadItemAt: (i) async {
      loads?.add(i);
      if (failing.contains(i)) return null;
      loaded.remove(i);
      return items[i];
    },
  );
}

void main() {
  // The artwork cache keeps its files here. Downloads in widget tests reach
  // flutter_test's HTTP stub, which answers every request with status 400.
  late Directory artworkCache;
  setUpAll(() => artworkCache = Directory.systemTemp.createTempSync('photo_sequence_test'));
  tearDownAll(() => artworkCache.deleteSync(recursive: true));

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => artworkCache.path,
    );
  });
  tearDown(() {
    ImmersiveModeGuard.resetForTesting();
    DevicePerformance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  group('PhotoSequence', () {
    final items = [
      _photo('a'),
      _item('album1', MediaKind.photoAlbum),
      _item('album2', MediaKind.photoAlbum),
      _photo('b'),
      _photo('c'),
    ];

    test('keeps photos and clips in grid order, skipping albums both ways', () async {
      final mixed = [
        _photo('a'),
        _item('x', MediaKind.clip),
        _item('album', MediaKind.photoAlbum),
        _item('y', MediaKind.clip),
        _photo('b'),
      ];
      final sequence = _sequenceOf(mixed, 0);

      expect(await sequence.neighbour(0, 1), (index: 1, photo: mixed[1]));
      expect(await sequence.neighbour(1, 1), (index: 3, photo: mixed[3]));
      expect(await sequence.neighbour(3, 1), (index: 4, photo: mixed[4]));
      expect(await sequence.neighbour(4, -1), (index: 3, photo: mixed[3]));
      expect(await sequence.neighbour(3, -1), (index: 1, photo: mixed[1]));
    });

    test('skips albums both ways', () async {
      final sequence = _sequenceOf(items, 0);

      expect(await sequence.neighbour(0, 1), (index: 3, photo: items[3]));
      expect(await sequence.neighbour(3, -1), (index: 0, photo: items[0]));
    });

    test('stops at both ends', () async {
      final sequence = _sequenceOf(items, 0);

      expect(await sequence.neighbour(0, -1), isNull);
      expect(await sequence.neighbour(4, 1), isNull);
    });

    test('loads the positions it has not got yet', () async {
      final loads = <int>[];
      final sequence = _sequenceOf(items, 0, unloaded: {1, 2, 3}, loads: loads);

      expect(await sequence.neighbour(0, 1), (index: 3, photo: items[3]));
      expect(loads, [1, 2, 3]);
    });

    test('ends where the list cannot be loaded', () async {
      final sequence = _sequenceOf(items, 0, unloaded: {2, 3}, failing: {2});

      expect(await sequence.neighbour(0, 1), isNull);
    });

    test('a single photo has nothing on either side', () async {
      final sequence = PhotoSequence.single(items[0]);

      expect(await sequence.neighbour(0, -1), isNull);
      expect(await sequence.neighbour(0, 1), isNull);
    });
  });

  Widget wrap(Widget home, {MultiServerProvider? provider}) {
    final app = InputModeTracker(
      child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: home),
    );
    return TranslationProvider(
      child: provider == null ? app : ChangeNotifierProvider<MultiServerProvider>.value(value: provider, child: app),
    );
  }

  FocusNode? primaryFocus() => FocusManager.instance.primaryFocus;

  /// The photo the viewer shows.
  String? shownTitle(WidgetTester tester) => tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen)).photo.id;

  /// Opens the viewer on [sequence] from a focused button, so that closing it
  /// has somewhere to go.
  Future<void> open(
    WidgetTester tester,
    PhotoSequence sequence, {
    MultiServerProvider? provider,
    PlayClip? playClip,
  }) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              autofocus: true,
              onPressed: () => playClip == null
                  ? openPhotoSequence(context, sequence)
                  : Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PhotoSequenceViewer(sequence: sequence, playClip: playClip),
                      ),
                    ),
              child: const Text('open'),
            ),
          ),
        ),
        provider: provider,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoSequenceViewer), findsOneWidget);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  final album = [
    _photo('a'),
    _item('album1', MediaKind.photoAlbum),
    _photo('b'),
    _item('album', MediaKind.photoAlbum),
    _photo('c'),
  ];

  group('keys', () {
    void runScenarios() {
      for (final backend in MediaBackend.values) {
        testWidgets('Right and Left move between the photos, skipping albums (${backend.name})', (tester) async {
          final items = [
            _photo('a', backend: backend),
            _item('album', MediaKind.photoAlbum, backend: backend),
            _photo('b', backend: backend),
          ];
          final sequence = _sequenceOf(items, 0);
          await open(tester, sequence);

          await press(tester, LogicalKeyboardKey.arrowRight);
          expect(shownTitle(tester), 'b');
          expect(find.text('b'), findsOneWidget);
          expect(sequence.index, 2);

          await press(tester, LogicalKeyboardKey.arrowLeft);
          expect(shownTitle(tester), 'a');
          expect(sequence.index, 0);
        });
      }

      testWidgets('nothing happens past either end', (tester) async {
        await open(tester, _sequenceOf(album, 0));

        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(shownTitle(tester), 'a');

        await press(tester, LogicalKeyboardKey.arrowRight);
        await press(tester, LogicalKeyboardKey.arrowRight);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(shownTitle(tester), 'c');
      });

      testWidgets('a held key moves one photo', (tester) async {
        await open(tester, _sequenceOf(album, 0));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();

        expect(shownTitle(tester), 'b');
      });

      testWidgets('focus is on the new photo, and Up still reaches the back button', (tester) async {
        await open(tester, _sequenceOf(album, 0));

        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_back');

        // Moving from the back button is fine too, and focus starts on the photo.
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(shownTitle(tester), 'c');
        expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');

        await press(tester, LogicalKeyboardKey.arrowUp);
        await press(tester, LogicalKeyboardKey.enter);
        expect(find.byType(PhotoSequenceViewer), findsNothing);
      });

      testWidgets('Enter does nothing on the photo, and Escape closes the viewer', (tester) async {
        final sequence = _sequenceOf(album, 0);
        await open(tester, sequence);
        await press(tester, LogicalKeyboardKey.arrowRight);

        await press(tester, LogicalKeyboardKey.enter);
        expect(shownTitle(tester), 'b');

        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(PhotoSequenceViewer), findsNothing);
        expect(sequence.index, 2);
      });
    }

    group('default', runScenarios);

    group('Force TV', () {
      setUp(() async => TvDetectionService.getInstance(forceTv: true));
      tearDown(TvDetectionService.debugReset);

      runScenarios();
    });
  });

  group('buttons', () {
    final previousButton = find.byTooltip('Previous photo');
    final nextButton = find.byTooltip('Next photo');

    testWidgets('show on the sides that have a photo, and move', (tester) async {
      await open(tester, _sequenceOf(album, 0));
      expect(previousButton, findsNothing);
      expect(nextButton, findsOneWidget);

      await tester.tap(nextButton);
      await tester.pumpAndSettle();
      expect(shownTitle(tester), 'b');
      expect(previousButton, findsOneWidget);
      expect(nextButton, findsOneWidget);

      await tester.tap(nextButton);
      await tester.pumpAndSettle();
      expect(shownTitle(tester), 'c');
      expect(nextButton, findsNothing);

      await tester.tap(previousButton);
      await tester.pumpAndSettle();
      expect(shownTitle(tester), 'b');
    });

    testWidgets('stay out of the focus order', (tester) async {
      await open(tester, _sequenceOf(album, 2));

      for (final button in [previousButton, nextButton]) {
        expect(find.ancestor(of: button, matching: find.byType(ExcludeFocus)), findsOneWidget);
      }
    });

    testWidgets('do not show on TV', (tester) async {
      await TvDetectionService.getInstance(forceTv: true);
      addTearDown(TvDetectionService.debugReset);
      await open(tester, _sequenceOf(album, 2));

      expect(previousButton, findsNothing);
      expect(nextButton, findsNothing);
    });
  });

  group('swipe', () {
    Offset center(WidgetTester tester) => tester.getCenter(find.byType(InteractiveViewer));

    testWidgets('left moves to the next photo, right to the previous one', (tester) async {
      await open(tester, _sequenceOf(album, 2));

      await tester.dragFrom(center(tester), const Offset(-200, 10));
      await tester.pumpAndSettle();
      expect(shownTitle(tester), 'c');

      await tester.dragFrom(center(tester), const Offset(200, -10));
      await tester.pumpAndSettle();
      expect(shownTitle(tester), 'b');
    });

    testWidgets('short, steep and mouse drags do not move', (tester) async {
      await open(tester, _sequenceOf(album, 2));

      await tester.dragFrom(center(tester), const Offset(-40, 0));
      await tester.dragFrom(center(tester), const Offset(-100, 80));
      await tester.dragFrom(center(tester), const Offset(-200, 0), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(shownTitle(tester), 'b');
    });

    testWidgets('a zoomed photo pans instead', (tester) async {
      await open(tester, _sequenceOf(album, 2));
      Matrix4 transform() => tester
          .widget<Transform>(
            find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Transform)).first,
          )
          .transform;

      final first = await tester.startGesture(center(tester) - const Offset(50, 0));
      final second = await tester.startGesture(center(tester) + const Offset(50, 0));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await first.moveBy(const Offset(-10, 0));
        await second.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      final zoomed = transform();
      expect(zoomed.getMaxScaleOnAxis(), greaterThan(2));

      await tester.dragFrom(center(tester), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(shownTitle(tester), 'b');
      expect(transform().getMaxScaleOnAxis(), closeTo(zoomed.getMaxScaleOnAxis(), 0.01));
      expect(transform().getTranslation().x, isNot(closeTo(zoomed.getTranslation().x, 1)));
    });
  });

  testWidgets('the zoom of one photo does not carry over to the next', (tester) async {
    await open(tester, _sequenceOf(album, 0));
    double scale() => tester
        .widget<Transform>(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Transform)).first)
        .transform
        .getMaxScaleOnAxis();
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byType(InteractiveViewer))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
    await tester.pump();
    expect(scale(), greaterThan(1));

    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(shownTitle(tester), 'b');
    expect(scale(), 1);
  });

  group('images loaded ahead', () {
    // Sized so that the screen-sized image is 1000 pixels on its long edge.
    void setScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      tester.view.display.size = const Size(1000, 600);
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
    }

    final photos = [
      for (final id in ['a', 'b', 'c', 'd', 'e']) _photo(id),
    ];

    /// Puts a decoded image in the memory cache for each photo, under the key
    /// the viewer would show it with, and returns those keys by photo.
    Future<Map<String, Object>> seedCache(WidgetTester tester, _UrlClient client) async {
      final keys = <String, Object>{};
      for (final photo in photos) {
        final image = PhotoViewerScreen.screenImage(client, photo.thumbPath, 1000)!.image;
        final key = await image.obtainKey(ImageConfiguration.empty);
        final decoded = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
        imageCache.putIfAbsent(key, () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: decoded))));
        keys[photo.id] = key;
      }
      client.requests.clear();
      return keys;
    }

    tearDown(() => imageCache.clear());

    Map<String, bool> tracked(Map<String, Object> keys) => {
      for (final MapEntry(key: id, value: key) in keys.entries) id: imageCache.statusForKey(key).tracked,
    };

    testWidgets('are the photos on either side, at screen size, and leave the cache as the viewer moves on', (
      tester,
    ) async {
      setScreen(tester);
      final client = _UrlClient();
      final multi = testMultiServer(clients: [client]);
      final keys = await seedCache(tester, client);
      final sequence = _sequenceOf(photos, 2);
      await open(tester, sequence, provider: multi.provider);

      expect(client.requests, containsAll(['/thumb/b?edge=1000', '/thumb/d?edge=1000']));
      expect(client.requests, isNot(contains('/thumb/e?edge=1000')));

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownTitle(tester), 'd');
      expect(tracked(keys), {'a': true, 'b': false, 'c': true, 'd': true, 'e': true});

      await press(tester, LogicalKeyboardKey.escape);
      expect(tracked(keys), {'a': true, 'b': false, 'c': false, 'd': false, 'e': false});
    });

    testWidgets('on the reduced tier, only the next photo in the direction of travel', (tester) async {
      DevicePerformance.debugReset(autoReduced: true);
      setScreen(tester);
      final client = _UrlClient();
      final multi = testMultiServer(clients: [client]);
      final keys = await seedCache(tester, client);
      await open(tester, _sequenceOf(photos, 2), provider: multi.provider);

      expect(client.requests, contains('/thumb/d?edge=1000'));
      expect(client.requests, isNot(contains('/thumb/b?edge=1000')));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shownTitle(tester), 'b');
      expect(client.requests, contains('/thumb/a?edge=1000'));
      expect(tracked(keys), {'a': true, 'b': true, 'c': false, 'd': false, 'e': true});
    });
  });

  testWidgets('moving on a phone keeps the system bars hidden, and closing shows them once', (tester) async {
    final calls = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') calls.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await open(tester, _sequenceOf(album, 0));
    calls.clear();

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(calls, everyElement('SystemUiMode.immersiveSticky'));

    calls.clear();
    await press(tester, LogicalKeyboardKey.escape);
    expect(calls.where((mode) => mode == 'SystemUiMode.edgeToEdge'), hasLength(1));
  });

  testWidgets('a photo opened on its own has no buttons and ignores Left and Right', (tester) async {
    await open(tester, PhotoSequence.single(_photo('a')));

    expect(find.byTooltip('Previous photo'), findsNothing);
    expect(find.byTooltip('Next photo'), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(shownTitle(tester), 'a');
    expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
  });

  group('clips', () {
    MediaItem clip(String id, {MediaBackend backend = MediaBackend.plex}) =>
        _item(id, MediaKind.clip, backend: backend).copyWith(durationMs: 65000, originallyAvailableAt: '2020-12-24');
    final mixed = [_photo('a'), clip('x'), _item('album', MediaKind.photoAlbum), clip('y'), _photo('b')];
    final played = <String>[];
    setUp(() async {
      played.clear();
      // As before clips played automatically; that has its own group below.
      resetSharedPreferencesForTest(initialAsync: const {'photo_clip_autoplay': false});
      await SettingsService.getInstance();
    });

    /// Plays in [_StandInPlayer], which closes on Escape, or when [ends]
    /// completes.
    PlayClip player({Future<void>? ends}) => (context, item, _) async {
      played.add(item.id);
      await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => _StandInPlayer(ends: ends)));
    };

    double scale(WidgetTester tester) => tester
        .widget<Transform>(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Transform)).first)
        .transform
        .getMaxScaleOnAxis();

    testWidgets('a clip shows its title, date, duration and a play button, and does not zoom', (tester) async {
      await open(tester, _sequenceOf(mixed, 0), playClip: player());

      await press(tester, LogicalKeyboardKey.arrowRight);

      expect(shownTitle(tester), 'x');
      expect(find.text('x'), findsOneWidget);
      expect(find.text('1:05'), findsOneWidget);
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(primaryFocus()?.debugLabel, 'photo_viewer_play');

      // Away from the play button in the middle.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getTopLeft(find.byType(InteractiveViewer)) + const Offset(40, 200)),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
      await tester.pump();
      expect(scale(tester), 1);
    });

    for (final (name, start) in <(String, Future<void> Function(WidgetTester))>[
      ('Enter', (tester) => press(tester, LogicalKeyboardKey.enter)),
      ('Select', (tester) => press(tester, LogicalKeyboardKey.select)),
      (
        'a tap',
        (tester) async {
          await tester.tap(find.byTooltip('Play'));
          await tester.pumpAndSettle();
        },
      ),
    ]) {
      testWidgets('$name plays the clip once, and closing the player returns to it with focus on play', (tester) async {
        final sequence = _sequenceOf(mixed, 1);
        await open(tester, sequence, playClip: player());

        await start(tester);
        expect(played, ['x']);
        expect(find.byType(_StandInPlayer), findsOneWidget);

        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(_StandInPlayer), findsNothing);
        expect(shownTitle(tester), 'x');
        expect(primaryFocus()?.debugLabel, 'photo_viewer_play');
        expect(played, ['x']);
      });
    }

    testWidgets('a clip that plays to the end returns to its page, and Left and Right go on from there', (
      tester,
    ) async {
      final ends = Completer<void>();
      final sequence = _sequenceOf(mixed, 1);
      await open(tester, sequence, playClip: player(ends: ends.future));

      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(_StandInPlayer), findsOneWidget);
      ends.complete();
      await tester.pumpAndSettle();

      expect(find.byType(_StandInPlayer), findsNothing);
      expect(shownTitle(tester), 'x');
      expect(primaryFocus()?.debugLabel, 'photo_viewer_play');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownTitle(tester), 'y');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownTitle(tester), 'b');
      expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shownTitle(tester), 'x');
      expect(sequence.index, 1);
    });

    testWidgets('a player that fails to open leaves the clip page as it was', (tester) async {
      await open(tester, _sequenceOf(mixed, 1), playClip: (_, _, _) async => throw StateError('no player'));

      await press(tester, LogicalKeyboardKey.enter);

      expect(tester.takeException(), isNull);
      expect(shownTitle(tester), 'x');
      expect(primaryFocus()?.debugLabel, 'photo_viewer_play');
    });

    group('on TV', () {
      setUp(() async => TvDetectionService.getInstance(forceTv: true));
      tearDown(TvDetectionService.debugReset);

      testWidgets('play shows its focus, Enter plays, Up reaches Back and Down returns to play', (tester) async {
        await open(tester, _sequenceOf(mixed, 0), playClip: player());
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_play');

        final chrome = find.descendant(of: find.byType(FocusableButton), matching: find.byType(AnimatedContainer));
        final focused = FocusTheme.focusDecoration(tester.element(chrome), isFocused: true, borderRadius: 100);
        expect(tester.widget<AnimatedContainer>(chrome).decoration, focused);

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_back');
        expect(tester.widget<AnimatedContainer>(chrome).decoration, isNot(focused));
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_play');

        await press(tester, LogicalKeyboardKey.enter);
        expect(played, ['x']);
      });
    });

    group('system bars on a phone', () {
      late List<Object?> modes;
      setUp(() => modes = []);

      void recordModes(WidgetTester tester) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') modes.add(call.arguments);
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
      }

      int restores() => modes.where((mode) => mode == 'SystemUiMode.edgeToEdge').length;

      testWidgets('stay hidden from the viewer to the player and back, and show once when the viewer closes', (
        tester,
      ) async {
        recordModes(tester);
        await open(tester, _sequenceOf(mixed, 1), playClip: player());
        modes.clear();

        await press(tester, LogicalKeyboardKey.enter);
        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(_StandInPlayer), findsNothing);
        expect(modes, everyElement('SystemUiMode.immersiveSticky'));
        expect(ImmersiveModeGuard.isOwned, isTrue);

        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(PhotoSequenceViewer), findsNothing);
        expect(restores(), 1);
        expect(ImmersiveModeGuard.isOwned, isFalse);
      });

      testWidgets('a clip that ends hands the bars back hidden too', (tester) async {
        recordModes(tester);
        final ends = Completer<void>();
        await open(tester, _sequenceOf(mixed, 1), playClip: player(ends: ends.future));
        modes.clear();

        await press(tester, LogicalKeyboardKey.enter);
        ends.complete();
        await tester.pumpAndSettle();

        expect(restores(), 0);
        expect(ImmersiveModeGuard.isOwned, isTrue);
      });

      group('leave no owner behind', () {
        testWidgets('when everything above the opener is popped while the player is open', (tester) async {
          recordModes(tester);
          await open(tester, _sequenceOf(mixed, 1), playClip: player());
          await press(tester, LogicalKeyboardKey.enter);
          modes.clear();

          Navigator.of(tester.element(find.byType(_StandInPlayer))).popUntil((route) => route.isFirst);
          await tester.pumpAndSettle();

          expect(find.byType(PhotoSequenceViewer), findsNothing);
          expect(restores(), 1);
          expect(ImmersiveModeGuard.isOwned, isFalse);
        });

        testWidgets('when the viewer route is removed under the player, then the player closes', (tester) async {
          recordModes(tester);
          await open(tester, _sequenceOf(mixed, 1), playClip: player());
          final viewerRoute = ModalRoute.of(tester.element(find.byType(PhotoSequenceViewer)))!;
          await press(tester, LogicalKeyboardKey.enter);
          modes.clear();

          Navigator.of(tester.element(find.byType(_StandInPlayer))).removeRoute(viewerRoute);
          await tester.pumpAndSettle();
          expect(restores(), 0, reason: 'the player still owns immersive mode');

          await press(tester, LogicalKeyboardKey.escape);
          expect(find.byType(_StandInPlayer), findsNothing);
          expect(restores(), 1);
          expect(ImmersiveModeGuard.isOwned, isFalse);
        });

        testWidgets('when the whole app is torn down while the player is open', (tester) async {
          recordModes(tester);
          await open(tester, _sequenceOf(mixed, 1), playClip: player());
          await press(tester, LogicalKeyboardKey.enter);
          modes.clear();

          await tester.pumpWidget(const SizedBox());
          await tester.pump();

          expect(restores(), 1);
          expect(ImmersiveModeGuard.isOwned, isFalse);
        });

        testWidgets('when the player fails to open', (tester) async {
          recordModes(tester);
          await open(tester, _sequenceOf(mixed, 1), playClip: (_, _, _) async => throw StateError('no player'));
          await press(tester, LogicalKeyboardKey.enter);
          modes.clear();

          await press(tester, LogicalKeyboardKey.escape);

          expect(restores(), 1);
          expect(ImmersiveModeGuard.isOwned, isFalse);
        });

        testWidgets('after moving between photos and clips and closing', (tester) async {
          recordModes(tester);
          await open(tester, _sequenceOf(mixed, 0), playClip: player());
          for (var i = 0; i < 3; i++) {
            await press(tester, LogicalKeyboardKey.arrowRight);
          }
          await press(tester, LogicalKeyboardKey.arrowLeft);
          await press(tester, LogicalKeyboardKey.enter);
          await press(tester, LogicalKeyboardKey.escape);
          modes.clear();

          await press(tester, LogicalKeyboardKey.escape);

          expect(restores(), 1);
          expect(ImmersiveModeGuard.isOwned, isFalse);
        });
      });
    });
  });

  group('the player moves the sequence', () {
    MediaItem clip(String id) =>
        _item(id, MediaKind.clip).copyWith(durationMs: 65000, originallyAvailableAt: '2020-12-24');
    final items = [_photo('a'), clip('x'), _item('album', MediaKind.photoAlbum), clip('y'), _photo('b'), clip('z')];
    final played = <String>[];
    final links = <PlayerSequenceLink>[];
    setUp(() async {
      played.clear();
      links.clear();
      // Moves by the player play at once whether or not clips autoplay.
      resetSharedPreferencesForTest(initialAsync: const {'photo_clip_autoplay': false});
      await SettingsService.getInstance();
    });

    PlayClip player() => (context, item, link) async {
      played.add(item.id);
      links.add(link);
      await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const _StandInPlayer()));
    };

    /// Next or previous in the player: it asks for the move and closes.
    Future<void> step(WidgetTester tester, int step) async {
      links.last.request(step);
      Navigator.of(tester.element(find.byType(_StandInPlayer))).pop();
      await tester.pumpAndSettle();
    }

    testWidgets('the player knows which ways the sequence goes on', (tester) async {
      await open(tester, _sequenceOf(items, 1), playClip: player());
      await press(tester, LogicalKeyboardKey.enter);
      expect((links.last.hasPrevious, links.last.hasNext), (true, true));
      await press(tester, LogicalKeyboardKey.escape);

      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownTitle(tester), 'z');
      await press(tester, LogicalKeyboardKey.enter);
      expect((links.last.hasPrevious, links.last.hasNext), (true, false));
    });

    testWidgets('next and previous in the player move the sequence, and a clip moved to plays at once', (tester) async {
      final sequence = _sequenceOf(items, 1);
      await open(tester, sequence, playClip: player());
      await press(tester, LogicalKeyboardKey.enter);

      // The viewer sits under the next clip's player.
      await step(tester, 1);
      expect(sequence.photo.id, 'y');
      expect(played, ['x', 'y']);
      expect(find.byType(_StandInPlayer), findsOneWidget);

      await step(tester, -1);
      expect(sequence.photo.id, 'x');
      expect(played, ['x', 'y', 'x']);

      await press(tester, LogicalKeyboardKey.escape);
      expect(shownTitle(tester), 'x');
    });

    testWidgets('a photo moved to from the player is shown, with nothing playing', (tester) async {
      await open(tester, _sequenceOf(items, 3), playClip: player());
      await press(tester, LogicalKeyboardKey.enter);

      await step(tester, 1);
      expect(shownTitle(tester), 'b');
      expect(played, ['y']);
      expect(find.byType(_StandInPlayer), findsNothing);
      expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
    });

    testWidgets('closing the player without a move stays on the clip', (tester) async {
      await open(tester, _sequenceOf(items, 1), playClip: player());
      await press(tester, LogicalKeyboardKey.enter);

      await press(tester, LogicalKeyboardKey.escape);
      expect(shownTitle(tester), 'x');
      expect(played, ['x']);
    });

    testWidgets('an item found next to the clip while it plays reaches the player', (tester) async {
      final next = Completer<void>();
      final sequence = PhotoSequence(
        index: 1,
        photo: items[1],
        length: () => items.length,
        itemAt: (i) => i == 3 ? null : items[i],
        loadItemAt: (i) async {
          await next.future;
          return items[i];
        },
      );
      await open(tester, sequence, playClip: player());
      await press(tester, LogicalKeyboardKey.enter);
      expect(links.last.hasNext, isFalse);

      next.complete();
      await tester.pumpAndSettle();
      expect(links.last.hasNext, isTrue);
    });
  });

  group('slideshow', () {
    MediaItem clip(String id) =>
        _item(id, MediaKind.clip).copyWith(durationMs: 65000, originallyAvailableAt: '2020-12-24');
    final played = <String>[];
    final links = <PlayerSequenceLink>[];
    final failing = <String>{};
    final gates = <String, Completer<void>>{};

    /// The sequence of the slideshow open, and the item it is on.
    late PhotoSequence show;
    String current() => show.photo.id;

    setUp(() async {
      played.clear();
      links.clear();
      failing.clear();
      gates.clear();
      resetSharedPreferencesForTest(initialAsync: const {'photo_slideshow_seconds': 3, 'photo_clip_autoplay': false});
      await SettingsService.getInstance();
      PhotoSequenceViewer.debugLoadsOverride = (item) async {
        await gates[item.id]?.future;
        return !failing.contains(item.id);
      };
    });
    tearDown(() => PhotoSequenceViewer.debugLoadsOverride = null);

    /// Plays in [_StandInPlayer]. [ends] plays the clip to its end; [fails]
    /// makes it a clip that cannot play.
    PlayClip player({Completer<void>? ends, bool fails = false}) => (context, item, link) async {
      played.add(item.id);
      links.add(link);
      if (fails) {
        link.markFailed();
        return;
      }
      unawaited(ends?.future.then((_) => link.markEnded()));
      await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => _StandInPlayer(ends: ends?.future)));
    };

    /// Opens a slideshow on [items] from a focused button.
    Future<PhotoSequence> openShow(
      WidgetTester tester,
      List<MediaItem> items, {
      int index = 0,
      PlayClip? playClip,
    }) async {
      final sequence = show = _sequenceOf(items, index);
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                autofocus: true,
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PhotoSequenceViewer(sequence: sequence, slideshow: true, playClip: playClip),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return sequence;
    }

    /// Lets exactly [seconds] pass.
    Future<void> wait(WidgetTester tester, num seconds) async {
      await tester.pump(Duration(milliseconds: (seconds * 1000).round()));
      await tester.pump();
    }

    bool pausedBadge() => find
        .byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.pause_rounded)
        .evaluate()
        .isNotEmpty;

    final photos = [_photo('a'), _photo('b'), _photo('c'), _photo('d')];

    for (final seconds in SettingsService.photoSlideshowChoices) {
      testWidgets('shows each photo for $seconds s, then the next', (tester) async {
        await SettingsService.instance.write(SettingsService.photoSlideshowSeconds, seconds);
        await openShow(tester, photos);

        await wait(tester, seconds - 1);
        expect(current(), 'a');
        await wait(tester, 1);
        expect(current(), 'b');
        await wait(tester, seconds);
        expect(current(), 'c');
      });
    }

    testWidgets('fades the next photo in over the one before, and only the one coming in takes focus', (tester) async {
      await openShow(tester, photos);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PhotoViewerScreen), findsNWidgets(2));
      await tester.pump(PhotoSequenceViewer.slideshowCrossFade);
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
      expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
    });

    for (final (name, toggle) in <(String, Future<void> Function(WidgetTester))>[
      ('Enter', (tester) => press(tester, LogicalKeyboardKey.enter)),
      ('Select', (tester) => press(tester, LogicalKeyboardKey.select)),
      (
        'a tap',
        (tester) async {
          await tester.tap(find.byType(InteractiveViewer));
          // A single tap acts once no second tap can make it a double one.
          await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
        },
      ),
    ]) {
      testWidgets('$name pauses and resumes, with a paused badge while paused', (tester) async {
        await openShow(tester, photos);

        await wait(tester, 1);
        await toggle(tester);
        expect(pausedBadge(), isTrue);
        await wait(tester, 20);
        expect(current(), 'a');

        await toggle(tester);
        expect(pausedBadge(), isFalse);
        await wait(tester, 2.5);
        expect(current(), 'a', reason: 'resuming gives the photo a full duration');
        await wait(tester, 0.6);
        expect(current(), 'b');
      });
    }

    group('zoom', () {
      Offset center(WidgetTester tester) => tester.getCenter(find.byType(InteractiveViewer));

      double scale(WidgetTester tester) => tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis();

      /// Two fingers moving [spread] apart each, or together when negative.
      Future<void> pinch(WidgetTester tester, double spread) async {
        final first = await tester.startGesture(center(tester) - const Offset(40, 0));
        final second = await tester.startGesture(center(tester) + const Offset(40, 0));
        for (var i = 0; i < 5; i++) {
          await first.moveBy(Offset(-spread / 5, 0));
          await second.moveBy(Offset(spread / 5, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await first.up();
        await second.up();
        await tester.pump();
      }

      testWidgets('pinching in pauses the slideshow, and pinching back out leaves it paused', (tester) async {
        await openShow(tester, photos);

        await wait(tester, 1);
        await pinch(tester, 60);
        expect(scale(tester), greaterThan(1));
        expect(pausedBadge(), isTrue);
        await wait(tester, 10);
        expect(current(), 'a');

        await pinch(tester, -35);
        expect(scale(tester), lessThanOrEqualTo(1));
        expect(pausedBadge(), isTrue, reason: 'zooming out does not resume');
        await wait(tester, 10);
        expect(current(), 'a');

        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
        expect(pausedBadge(), isFalse, reason: 'a single tap still resumes');
      });

      testWidgets('a zoom set on the photo, as a double tap sets it, pauses too', (tester) async {
        await openShow(tester, photos);

        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value =
            Matrix4.diagonal3Values(2, 2, 1);
        await tester.pump();

        expect(pausedBadge(), isTrue);
      });

      testWidgets('a double tap pauses only by the zoom it makes, never through the single tap', (tester) async {
        await openShow(tester, photos);

        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
        // Where a double tap zooms the photo, zooming in pauses; nothing else
        // about it pauses or resumes.
        expect(pausedBadge(), scale(tester) > 1);

        final paused = pausedBadge();
        await tester.tap(find.byType(InteractiveViewer));
        await tester.pump(const Duration(milliseconds: 100));
        expect(pausedBadge(), paused, reason: 'not before the double-tap wait is over');
        await tester.pump(kDoubleTapTimeout);
        expect(pausedBadge(), !paused);
      });
    });

    testWidgets('moving by hand restarts the timer, and a paused slideshow stays paused', (tester) async {
      await openShow(tester, photos);

      await wait(tester, 2);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(current(), 'b');
      await wait(tester, 2);
      expect(current(), 'b');
      await wait(tester, 1);
      expect(current(), 'c');

      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(current(), 'b');
      await wait(tester, 10);
      expect(current(), 'b');
      expect(pausedBadge(), isTrue);
    });

    testWidgets('keeps the photo shown until the next one has loaded', (tester) async {
      gates['b'] = Completer<void>();
      await openShow(tester, photos);

      await wait(tester, 10);
      expect(current(), 'a');

      gates['b']!.complete();
      await wait(tester, 0);
      expect(current(), 'b');
    });

    testWidgets('waits for the next item of a list still being fetched', (tester) async {
      final window = Completer<void>();
      final sequence = PhotoSequence(
        index: 0,
        photo: photos[0],
        length: () => photos.length,
        itemAt: (i) => i == 0 ? photos[0] : null,
        loadItemAt: (i) async {
          await window.future;
          return photos[i];
        },
      );
      await tester.pumpWidget(wrap(PhotoSequenceViewer(sequence: show = sequence, slideshow: true)));
      await tester.pump();

      await wait(tester, 10);
      expect(current(), 'a');
      window.complete();
      await wait(tester, 0);
      expect(current(), 'b');
    });

    testWidgets('tells the list each position it shows, so it can fetch the next window ahead', (tester) async {
      final shownAt = <int>[];
      final sequence = show = PhotoSequence(
        index: 0,
        photo: photos[0],
        length: () => photos.length,
        itemAt: (i) => photos[i],
        loadItemAt: (i) async => photos[i],
        onShown: shownAt.add,
      );
      await tester.pumpWidget(wrap(PhotoSequenceViewer(sequence: sequence, slideshow: true)));
      await tester.pump();

      await wait(tester, 3);
      await wait(tester, 3);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shownAt, [0, 1, 2, 1]);
    });

    testWidgets('passes over a next photo that does not load', (tester) async {
      failing.add('b');
      await openShow(tester, photos);

      await wait(tester, 3);
      expect(current(), 'c');
    });

    testWidgets('a photo that fails on screen stays up for 2 s, then the slideshow goes past it, both ways', (
      tester,
    ) async {
      failing.add('c');
      await openShow(tester, photos, index: 2);

      await wait(tester, 1.2);
      expect(current(), 'c');
      await wait(tester, 1);
      expect(current(), 'd');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(current(), 'b', reason: 'going back passes over the photo that failed');
    });

    testWidgets('pauses with the error after 5 failures in a row, and a photo that loads starts the count again', (
      tester,
    ) async {
      final items = [_photo('a'), for (var i = 0; i < 6; i++) _photo('f$i'), _photo('z')];
      failing.addAll([for (var i = 0; i < 6; i++) 'f$i']);
      await openShow(tester, items);

      await wait(tester, 3);
      expect(current(), 'a');
      expect(pausedBadge(), isTrue);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(t.errors.unableToLoad(context: 'a')),
        ),
        findsOneWidget,
      );

      await press(tester, LogicalKeyboardKey.enter);
      expect(pausedBadge(), isFalse);
      await wait(tester, 3);
      expect(current(), 'z');
    });

    group('clips', () {
      final items = [_photo('a'), clip('x'), _photo('b'), _photo('c')];

      testWidgets('a clip plays when the slideshow reaches it, and its end moves straight on', (tester) async {
        final ends = Completer<void>();
        await openShow(tester, items, playClip: player(ends: ends));

        await wait(tester, 3);
        expect(played, ['x']);
        expect(find.byType(_StandInPlayer), findsOneWidget);
        await wait(tester, 60);
        expect(find.byType(_StandInPlayer), findsOneWidget, reason: 'the slideshow waits while the clip plays');

        ends.complete();
        await wait(tester, 0);
        expect(current(), 'b');
      });

      testWidgets('Back in the player leaves the clip page up for a photo duration, then goes on', (tester) async {
        await openShow(tester, items, playClip: player());

        await wait(tester, 3);
        await press(tester, LogicalKeyboardKey.escape);
        expect(current(), 'x');
        await wait(tester, 2);
        expect(current(), 'x');
        expect(played, ['x'], reason: 'the clip does not play again');
        await wait(tester, 1.2);
        expect(current(), 'b');
      });

      testWidgets('next in the player moves on, and the slideshow carries on from there', (tester) async {
        await openShow(tester, items, playClip: player());

        await wait(tester, 3);
        links.last.request(1);
        Navigator.of(tester.element(find.byType(_StandInPlayer))).pop();
        await wait(tester, 0);
        expect(current(), 'b');
        await wait(tester, 3);
        expect(current(), 'c');
      });

      testWidgets('a clip that cannot play is passed over', (tester) async {
        await openShow(tester, items, playClip: player(fails: true));

        await wait(tester, 3);
        expect(played, ['x']);
        await wait(tester, 0);
        expect(current(), 'b');
        expect(links.single.leavesOnFailure, isTrue);
      });
    });

    group('screen awake', () {
      testWidgets('held while the slideshow runs and let go at its end', (tester) async {
        await openShow(tester, [_photo('a'), _photo('b')]);
        expect(WakelockController.shared.isHeld, isTrue);

        await wait(tester, 3);
        expect(current(), 'b');
        await wait(tester, 3);
        expect(current(), 'b', reason: 'the slideshow stops on the last item');
        expect(WakelockController.shared.isHeld, isFalse);

        await press(tester, LogicalKeyboardKey.enter);
        expect(pausedBadge(), isFalse, reason: 'there is nothing left to pause');
      });

      testWidgets('Back ends the slideshow, lets go and returns focus to where it started', (tester) async {
        await openShow(tester, photos);
        expect(WakelockController.shared.isHeld, isTrue);

        await press(tester, LogicalKeyboardKey.escape);
        expect(find.byType(PhotoSequenceViewer), findsNothing);
        expect(WakelockController.shared.isHeld, isFalse);
        expect(Focus.of(tester.element(find.text('open'))).hasPrimaryFocus, isTrue);
        await tester.pump(const Duration(seconds: 10));
      });

      testWidgets('stays held while a clip plays over the slideshow and its player lets go', (tester) async {
        await openShow(tester, [_photo('a'), clip('x'), _photo('b')], playClip: player());
        await wait(tester, 3);
        // What the player does as it closes.
        unawaited(WakelockController.shared.setEnabled(false));
        await press(tester, LogicalKeyboardKey.escape);
        expect(WakelockController.shared.isHeld, isTrue);
      });
    });
  });

  group('clips play automatically', () {
    MediaItem clip(String id) =>
        _item(id, MediaKind.clip).copyWith(durationMs: 65000, originallyAvailableAt: '2020-12-24');
    final items = [_photo('a'), clip('x'), clip('y'), clip('z'), _photo('b'), clip('w')];
    final played = <String>[];
    setUp(() async {
      played.clear();
      resetSharedPreferencesForTest();
      await SettingsService.getInstance();
    });

    PlayClip player({Future<void>? ends}) => (context, item, _) async {
      played.add(item.id);
      await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => _StandInPlayer(ends: ends)));
    };

    /// Presses [key] and waits [after], without settling, so the autoplay
    /// timer is only as far along as the test says.
    Future<void> tap(WidgetTester tester, LogicalKeyboardKey key, {Duration after = Duration.zero}) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(after);
    }

    testWidgets('a clip moved to plays once the viewer has stayed on it for the delay', (tester) async {
      await open(tester, _sequenceOf(items, 0), playClip: player());

      await tap(tester, LogicalKeyboardKey.arrowRight, after: const Duration(milliseconds: 400));
      expect(shownTitle(tester), 'x');
      expect(played, isEmpty);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(played, ['x']);
      expect(find.byType(_StandInPlayer), findsOneWidget);
    });

    testWidgets('clips passed on the way do not play, the one stopped on does', (tester) async {
      await open(tester, _sequenceOf(items, 0), playClip: player());

      for (var i = 0; i < 4; i++) {
        await tap(tester, LogicalKeyboardKey.arrowRight, after: const Duration(milliseconds: 300));
      }
      expect(shownTitle(tester), 'b');
      await tester.pump(const Duration(seconds: 2));
      expect(played, isEmpty);

      await tap(tester, LogicalKeyboardKey.arrowRight, after: PhotoSequenceViewer.clipAutoplayDelay);
      await tester.pumpAndSettle();
      expect(played, ['w']);
    });

    testWidgets('a swipe or a button counts as a move too', (tester) async {
      await open(tester, _sequenceOf(items, 0), playClip: player());

      await tester.tap(find.byTooltip('Next photo'));
      await tester.pump(const Duration(milliseconds: 200));
      // Below the play button in the middle.
      await tester.dragFrom(
        tester.getCenter(find.byType(InteractiveViewer)) + const Offset(0, 150),
        const Offset(-200, 10),
      );
      await tester.pump();
      expect(shownTitle(tester), 'y');
      await tester.pump(const Duration(milliseconds: 400));
      expect(played, isEmpty);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(played, ['y']);
    });

    testWidgets('a clip reached with the arrow key still held waits for it to be let go', (tester) async {
      await open(tester, _sequenceOf(items, 0), playClip: player());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(shownTitle(tester), 'x');
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(shownTitle(tester), 'x');
      expect(played, isEmpty);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      expect(played, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(played, ['x']);
    });

    for (final (name, close) in <(String, Future<void> Function(WidgetTester, Completer<void>))>[
      ('Back', (tester, _) => press(tester, LogicalKeyboardKey.escape)),
      (
        'the clip ending',
        (tester, ends) async {
          ends.complete();
          await tester.pumpAndSettle();
        },
      ),
    ]) {
      testWidgets('after $name the clip does not play again until the viewer comes back to it', (tester) async {
        final ends = Completer<void>();
        await open(tester, _sequenceOf(items, 0), playClip: player(ends: ends.future));

        await tap(tester, LogicalKeyboardKey.arrowRight, after: PhotoSequenceViewer.clipAutoplayDelay);
        await tester.pumpAndSettle();
        expect(played, ['x']);

        await close(tester, ends);
        expect(find.byType(_StandInPlayer), findsNothing);
        expect(shownTitle(tester), 'x');
        expect(primaryFocus()?.debugLabel, 'photo_viewer_play');
        await tester.pump(const Duration(seconds: 2));
        expect(played, ['x']);

        await tap(tester, LogicalKeyboardKey.arrowLeft, after: const Duration(milliseconds: 100));
        await tap(tester, LogicalKeyboardKey.arrowRight, after: PhotoSequenceViewer.clipAutoplayDelay);
        await tester.pumpAndSettle();
        expect(played, ['x', 'x']);
      });
    }

    testWidgets('a clip the viewer opens on plays at once only when it was opened to play', (tester) async {
      await open(tester, _sequenceOf(items, 1), playClip: player());
      await tester.pump(const Duration(seconds: 1));
      expect(played, isEmpty);
    });

    testWidgets('nothing plays by itself with the setting off', (tester) async {
      await SettingsService.instance.write(SettingsService.photoClipAutoplay, false);
      await open(tester, _sequenceOf(items, 0), playClip: player());

      await tap(tester, LogicalKeyboardKey.arrowRight, after: const Duration(seconds: 2));
      expect(shownTitle(tester), 'x');
      expect(played, isEmpty);
      expect(find.byTooltip('Play'), findsOneWidget);
    });

    testWidgets('a screen opened over the viewer before the delay keeps the clip from playing', (tester) async {
      await open(tester, _sequenceOf(items, 0), playClip: player());

      await tap(tester, LogicalKeyboardKey.arrowRight, after: const Duration(milliseconds: 100));
      unawaited(
        Navigator.of(
          tester.element(find.byType(PhotoViewerScreen)),
        ).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('over')))),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(played, isEmpty);
    });
  });

  group('shuffle', () {
    final loaded = <String>[];
    final gates = <String, Completer<void>>{};

    setUp(() async {
      loaded.clear();
      gates.clear();
      resetSharedPreferencesForTest(initialAsync: const {'photo_slideshow_seconds': 3, 'photo_clip_autoplay': false});
      await SettingsService.getInstance();
      PhotoSequenceViewer.debugLoadsOverride = (item) async {
        loaded.add(item.id);
        await gates[item.id]?.future;
        return true;
      };
    });
    tearDown(() => PhotoSequenceViewer.debugLoadsOverride = null);

    MediaItem inSummer(String id) => _photo(id).copyWith(parentId: 'summer', parentTitle: 'Summer');

    final x = inSummer('x').copyWith(grandparentId: 'years', grandparentTitle: 'Years');
    final summer = [_photo('p0'), _item('sub', MediaKind.photoAlbum), _photo('p2'), x, _photo('p4')];
    final shuffled = [_photo('s0'), x, _photo('s2'), _photo('s3')];

    /// The shuffle sequence of the slideshow open.
    late PhotoSequence show;
    late _AlbumClient client;

    Future<void> openShuffle(
      WidgetTester tester, {
      List<MediaItem>? items,
      int index = 1,
      _AlbumClient? albums,
      int pageSize = 200,
    }) async {
      client = albums ?? _AlbumClient({'summer': summer});
      final sequence = show = _sequenceOf(items ?? shuffled, index);
      final session = PhotoShuffleSession(
        scope: 'Holidays',
        albums: PhotoShuffleAlbums(client: client, pageSize: pageSize),
      );
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                autofocus: true,
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PhotoSequenceViewer(sequence: sequence, slideshow: true, shuffle: session),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> wait(WidgetTester tester, num seconds) async {
      await tester.pump(Duration(milliseconds: (seconds * 1000).round()));
      await tester.pump();
    }

    /// The item coming in, while one fades out under it.
    String onScreen(WidgetTester tester) =>
        tester.widgetList<PhotoViewerScreen>(find.byType(PhotoViewerScreen)).last.photo.id;

    bool pausedBadge() => find
        .byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.pause_rounded)
        .evaluate()
        .isNotEmpty;

    Finder albumButton() => find.text('Summer');
    Finder shuffleToggle() => find.byWidgetPredicate((widget) => widget is IconButton && widget.isSelected != null);
    bool shuffling(WidgetTester tester) => tester.widget<IconButton>(shuffleToggle()).isSelected!;

    double headerOpacity(WidgetTester tester) => tester
        .widgetList<AnimatedOpacity>(
          find.ancestor(of: find.byType(AppBarBackButton), matching: find.byType(AnimatedOpacity)),
        )
        .first
        .opacity;

    Future<void> tapPhoto(WidgetTester tester) async {
      await tester.tap(find.byType(InteractiveViewer).last);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
    }

    Future<void> switchMode(WidgetTester tester, Finder button) async {
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('the header names the shuffle and offers the album the item is directly in', (tester) async {
      await openShuffle(tester);

      expect(find.text('x'), findsOneWidget);
      expect(find.text('Shuffle · Holidays'), findsOneWidget);
      expect(albumButton(), findsOneWidget);
      expect(find.text('Years'), findsNothing, reason: 'never a grandparent');
      expect(shuffling(tester), isTrue);

      await wait(tester, 3);
      expect(onScreen(tester), 's2');
      expect(albumButton(), findsNothing, reason: 's2 has no album');
      expect(tester.widget<IconButton>(shuffleToggle()).onPressed, isNull);
      expect(find.text('Shuffle · Holidays'), findsOneWidget);
    });

    testWidgets('an album the item does not name is looked up, as for Jellyfin folders', (tester) async {
      final unnamed = _photo('x').copyWith(parentId: 'summer');
      await openShuffle(
        tester,
        items: [_photo('s0'), unnamed, _photo('s2')],
        albums: _AlbumClient(
          {'summer': summer},
          items: {'summer': _item('summer', MediaKind.folder).copyWith(title: 'Summer')},
        ),
      );

      expect(albumButton(), findsOneWidget);
      expect(client.lookedUp, ['summer']);
    });

    testWidgets('switching to the album keeps the item on screen as it is, and goes through the album in its order', (
      tester,
    ) async {
      await openShuffle(tester);
      final viewer = tester.state(find.byType(PhotoViewerScreen));
      final loadsOfX = loaded.where((id) => id == 'x').length;

      await wait(tester, 1);
      await switchMode(tester, albumButton());

      expect(identical(tester.state(find.byType(PhotoViewerScreen)), viewer), isTrue);
      expect(loaded.where((id) => id == 'x'), hasLength(loadsOfX), reason: 'the item is not loaded again');
      expect(find.text('Album · Summer · 4 / 5'), findsOneWidget);
      expect(albumButton(), findsNothing);
      expect(shuffling(tester), isFalse);
      expect((show.index, show.photo.id), (1, 'x'), reason: 'the shuffle stays where it was left');

      final order = <String>[];
      for (var i = 0; i < 5; i++) {
        await wait(tester, 3);
        order.add(onScreen(tester));
      }
      expect(order, ['p4', 'p0', 'p2', 'x', 'p4'], reason: 'past the last comes the first, the sub-album skipped');
      expect(find.text('Album · Summer · 5 / 5'), findsOneWidget);
      expect((show.index, show.photo.id), (1, 'x'));
    });

    testWidgets('in the album, previous from the first item goes to the last, and next from there to the first', (
      tester,
    ) async {
      await openShuffle(
        tester,
        albums: _AlbumClient({
          'summer': [x, _photo('p1'), _item('sub', MediaKind.photoAlbum), _photo('p3')],
        }),
      );
      await switchMode(tester, albumButton());
      expect(find.text('Album · Summer · 1 / 4'), findsOneWidget);
      expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(onScreen(tester), 'p3');
      expect(find.text('Album · Summer · 4 / 4'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(onScreen(tester), 'x');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(onScreen(tester), 'p1');
    });

    testWidgets('on the last item of the album, the first is loaded ahead, and shown once it has loaded', (
      tester,
    ) async {
      await openShuffle(
        tester,
        albums: _AlbumClient({
          'summer': [_photo('p0'), _photo('p1'), x],
        }),
      );
      final p0 = gates['p0'] = Completer<void>();
      await switchMode(tester, albumButton());

      expect(find.text('Album · Summer · 3 / 3'), findsOneWidget);
      expect(loaded, contains('p0'));

      await wait(tester, 5);
      expect(onScreen(tester), 'x', reason: 'the first item has not loaded yet');

      p0.complete();
      await tester.pumpAndSettle();
      expect(onScreen(tester), 'p0');
      expect(find.text('Album · Summer · 1 / 3'), findsOneWidget);
    });

    testWidgets(
      'back to shuffle returns to the item it was left at, goes on with the next one, and keeps the history',
      (tester) async {
        await openShuffle(tester, index: 0);
        await wait(tester, 3);
        expect(onScreen(tester), 'x');

        await switchMode(tester, albumButton());
        await wait(tester, 3);
        expect(onScreen(tester), 'p4');

        await switchMode(tester, shuffleToggle());
        expect(onScreen(tester), 'x');
        expect(shuffling(tester), isTrue);
        expect(find.text('Shuffle · Holidays'), findsOneWidget);
        expect(albumButton(), findsOneWidget);

        await wait(tester, 3);
        expect(onScreen(tester), 's2', reason: 'the next shuffled item, nothing repeated');
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(onScreen(tester), 'x');
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(onScreen(tester), 's0');
      },
    );

    testWidgets('switching to the album or back to shuffle resumes a paused slideshow', (tester) async {
      await openShuffle(tester);

      await press(tester, LogicalKeyboardKey.enter);
      expect(pausedBadge(), isTrue);
      await switchMode(tester, albumButton());
      expect(pausedBadge(), isFalse);
      await wait(tester, 3);
      expect(onScreen(tester), 'p4');

      await press(tester, LogicalKeyboardKey.enter);
      expect(pausedBadge(), isTrue);
      await switchMode(tester, shuffleToggle());
      expect(pausedBadge(), isFalse);
      await wait(tester, 3);
      expect(onScreen(tester), 's2');
    });

    testWidgets('an album that cannot be opened is no longer offered, and the shuffle goes on', (tester) async {
      await openShuffle(tester, albums: _AlbumClient({'summer': summer}, failing: {'summer'}));

      await switchMode(tester, albumButton());

      expect(albumButton(), findsNothing);
      expect(find.text('Shuffle · Holidays'), findsOneWidget);
      expect(tester.widget<IconButton>(shuffleToggle()).onPressed, isNull);
      await wait(tester, 3);
      expect(onScreen(tester), 's2');
    });

    testWidgets('the header hides after 4 s without input while playing, and shows while paused', (tester) async {
      await SettingsService.instance.write(SettingsService.photoSlideshowSeconds, 30);
      await openShuffle(tester);
      expect(headerOpacity(tester), 1);

      // Any input starts the wait again.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await wait(tester, 3.9);
      expect(headerOpacity(tester), 1);
      await wait(tester, 0.2);
      expect(headerOpacity(tester), 0);

      await tapPhoto(tester);
      expect(pausedBadge(), isTrue, reason: 'one tap pauses and shows the header');
      expect(headerOpacity(tester), 1);
      await wait(tester, 20);
      expect(headerOpacity(tester), 1);

      await tapPhoto(tester);
      expect(pausedBadge(), isFalse);
      await wait(tester, 3.9);
      expect(headerOpacity(tester), 1);
      await wait(tester, 0.2);
      expect(headerOpacity(tester), 0);
    });

    testWidgets('on TV, Up shows and focuses the header, Left and Right move along it, and Down goes back', (
      tester,
    ) async {
      await TvDetectionService.getInstance(forceTv: true);
      addTearDown(TvDetectionService.debugReset);
      await SettingsService.instance.write(SettingsService.photoSlideshowSeconds, 30);
      await openShuffle(tester);
      await wait(tester, 4.1);
      expect(headerOpacity(tester), 0);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(headerOpacity(tester), 1);
      expect(primaryFocus()?.debugLabel, 'photo_slideshow_album');
      expect(InputModeTracker.isKeyboardMode(tester.element(find.byType(PhotoSequenceViewer)), listen: false), isTrue);

      final path = <String?>[];
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await press(tester, key);
        path.add(primaryFocus()?.debugLabel);
      }
      expect(path, [
        'photo_slideshow_back',
        'photo_slideshow_back',
        'photo_slideshow_album',
        'photo_slideshow_shuffle',
        'photo_slideshow_shuffle',
        'photo_slideshow_album',
      ]);
      expect(onScreen(tester), 'x', reason: 'Left and Right in the header do not move the slideshow');
      await wait(tester, 10);
      expect(headerOpacity(tester), 1, reason: 'the header stays while it has focus');

      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text('Album · Summer · 4 / 5'), findsOneWidget);
      expect(primaryFocus()?.debugLabel, 'photo_slideshow_shuffle');

      await wait(tester, 30);
      expect(onScreen(tester), 'p4');
      expect(primaryFocus()?.debugLabel, 'photo_slideshow_shuffle', reason: 'focus stays as the photo changes');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
      await wait(tester, 3.9);
      expect(headerOpacity(tester), 1);
      await wait(tester, 0.2);
      expect(headerOpacity(tester), 0);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(primaryFocus()?.debugLabel, 'photo_slideshow_shuffle');
      await press(tester, LogicalKeyboardKey.enter);
      expect(onScreen(tester), 'x');
      expect(find.text('Shuffle · Holidays'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(PhotoSequenceViewer), findsNothing, reason: 'Back ends the whole slideshow');
    });

    testWidgets('a large album switches once the page holding the item is in, and holds the item until then', (
      tester,
    ) async {
      final big = [_photo('p0'), _photo('p1'), x, _photo('p3'), _photo('p4'), _photo('p5')];
      final albums = _AlbumClient({'summer': big});
      final xPage = albums.held['summer@2'] = Completer<void>();
      final lastPage = albums.held['summer@4'] = Completer<void>();
      await openShuffle(tester, albums: albums, pageSize: 2);

      await tester.tap(albumButton());
      await wait(tester, 5);
      expect(onScreen(tester), 'x');
      expect(find.text('Shuffle · Holidays'), findsOneWidget, reason: 'still loading the page with the item');

      xPage.complete();
      await tester.pumpAndSettle();
      expect(find.text('Album · Summer · 3 / 6'), findsOneWidget, reason: 'the total comes from the server');
      expect(client.fetched, ['summer@0', 'summer@2', 'summer@4']);

      await wait(tester, 3);
      expect(onScreen(tester), 'p3');
      await wait(tester, 5);
      expect(onScreen(tester), 'p3', reason: 'the next page is still loading');

      lastPage.complete();
      await tester.pumpAndSettle();
      expect(onScreen(tester), 'p4');
      expect(find.text('Album · Summer · 5 / 6'), findsOneWidget);
    });

    testWidgets('going round a large album waits for the pages still loading', (tester) async {
      final big = [x, _photo('p1'), _photo('p2'), _photo('p3'), _photo('p4'), _photo('p5')];
      final albums = _AlbumClient({'summer': big});
      final middle = albums.held['summer@2'] = Completer<void>();
      final last = albums.held['summer@4'] = Completer<void>();
      await openShuffle(tester, albums: albums, pageSize: 2);

      await switchMode(tester, albumButton());
      expect(find.text('Album · Summer · 1 / 6'), findsOneWidget, reason: 'switched with only the first page in');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(onScreen(tester), 'x', reason: 'the last page is still loading');

      last.complete();
      await tester.pumpAndSettle();
      expect(onScreen(tester), 'p5');
      expect(find.text('Album · Summer · 6 / 6'), findsOneWidget);
      middle.complete();
    });
  });
}

/// Answers image requests with a URL naming the path and size, and records
/// them.
class _UrlClient implements MediaServerClient {
  final requests = <String>[];

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    final request = '$path?edge=$width';
    requests.add(request);
    return 'https://server$request';
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Takes immersive mode over from the viewer and hands it back the way
/// VideoPlayerScreen does: it acquires the guard when it opens, and on close
/// releases it and shows the system UI only when no screen below still owns it.
class _StandInPlayer extends StatefulWidget {
  const _StandInPlayer({this.ends});

  /// Completes when the video plays to its end, which closes the player.
  final Future<void>? ends;

  @override
  State<_StandInPlayer> createState() => _StandInPlayerState();
}

class _StandInPlayerState extends State<_StandInPlayer> {
  @override
  void initState() {
    super.initState();
    ImmersiveModeGuard.acquire(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.ends?.then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    ImmersiveModeGuard.release(this);
    if (!ImmersiveModeGuard.isOwned) OrientationHelper.restoreSystemUI();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    // Back on key up, as every screen does, so the key down does not also
    // reach the viewer below.
    onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
    child: const Scaffold(body: Text('player')),
  );
}

/// Albums by id, paged as a server pages them, and the items [fetchItem]
/// knows. A page whose start is in [held] waits until it is completed; the
/// albums in [failing] cannot be read.
class _AlbumClient implements MediaServerClient {
  _AlbumClient(this.albums, {this.items = const {}, this.failing = const {}});

  final Map<String, List<MediaItem>> albums;
  final Map<String, MediaItem> items;
  final Set<String> failing;
  final Map<String, Completer<void>> held = {};
  final fetched = <String>[];
  final lookedUp = <String>[];

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final key = '$parentId@${start ?? 0}';
    fetched.add(key);
    await held[key]?.future;
    if (failing.contains(parentId)) throw StateError('cannot read $parentId');
    final all = albums[parentId] ?? const [];
    final from = (start ?? 0).clamp(0, all.length);
    final to = (from + (size ?? all.length)).clamp(0, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    lookedUp.add(id);
    return items[id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
