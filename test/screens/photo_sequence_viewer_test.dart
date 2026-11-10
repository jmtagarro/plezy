import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/photo_sequence_viewer.dart';
import 'package:plezy/screens/photo_viewer_screen.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

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
      _item('clip', MediaKind.clip),
      _item('album', MediaKind.photoAlbum),
      _photo('b'),
      _photo('c'),
    ];

    test('skips clips and albums both ways', () async {
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
  Future<void> open(WidgetTester tester, PhotoSequence sequence, {MultiServerProvider? provider}) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              autofocus: true,
              onPressed: () => openPhotoSequence(context, sequence),
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
    _item('clip', MediaKind.clip),
    _photo('b'),
    _item('album', MediaKind.photoAlbum),
    _photo('c'),
  ];

  group('keys', () {
    void runScenarios() {
      for (final backend in MediaBackend.values) {
        testWidgets('Right and Left move between the photos, skipping the rest (${backend.name})', (tester) async {
          final items = [
            _photo('a', backend: backend),
            _item('clip', MediaKind.clip, backend: backend),
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
