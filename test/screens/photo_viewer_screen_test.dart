import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/photo_viewer_screen.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/jellyfin_mappers.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_mappers.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

const _partPath = '/library/parts/1/2/photo.jpg';
const _thumbPath = '/library/metadata/1/thumb/2';

/// A 1x1 PNG, so the zoom upgrade has something real to decode.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  // The artwork cache keeps its files here. Downloads in widget tests reach
  // flutter_test's HTTP stub, which answers every request with status 400.
  late Directory artworkCache;
  setUpAll(() => artworkCache = Directory.systemTemp.createTempSync('photo_viewer_test'));
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  Widget wrap(Widget home, {MultiServerProvider? provider}) {
    final app = InputModeTracker(
      child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: home),
    );
    return TranslationProvider(
      child: provider == null ? app : ChangeNotifierProvider<MultiServerProvider>.value(value: provider, child: app),
    );
  }

  testWidgets('a photo whose server is unavailable shows the load error and no Play action', (tester) async {
    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo())));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(t.errors.unableToLoad(context: 'Photo')), findsOneWidget);
    expect(find.byTooltip(t.common.play), findsNothing);
  });

  testWidgets('loads the file at screen size, then the thumb, then reports the failure', (tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.display.size = const Size(1000, 500);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    final client = _RecordingClient();
    final multi = testMultiServer(clients: [client]);

    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
    await tester.pump();

    expect(client.requests, [
      (path: _partPath, width: 1000, height: 1000, cover: false),
      (path: _thumbPath, width: 1000, height: 1000, cover: false),
    ]);
    expect(find.text(t.errors.unableToLoad(context: 'Photo')), findsOneWidget);
  });

  testWidgets('a photo that fails to download falls back to the thumb, then reports the failure', (tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.display.size = const Size(1000, 500);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    final client = _RecordingClient(answersWithUrls: true);
    final multi = testMultiServer(clients: [client]);
    final attempted = <String>[];
    final error = find.text(t.errors.unableToLoad(context: 'Photo'));

    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
    for (var i = 0; i < 500 && error.evaluate().isEmpty; i++) {
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        final url = ((image.image as ResizeImage).imageProvider as CachedNetworkImageProvider).url;
        if (!attempted.contains(url)) attempted.add(url);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }

    expect(attempted, ['https://server$_partPath?edge=1000', 'https://server$_thumbPath?edge=1000']);
    expect(error, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing drops the image from the memory cache', (tester) async {
    final client = _RecordingClient(answersWithUrls: true);
    final multi = testMultiServer(clients: [client]);
    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
    await tester.pump();

    final provider = tester.widget<Image>(find.byType(Image)).image;
    Object? key;
    unawaited(provider.obtainKey(ImageConfiguration.empty).then((value) => key = value));
    await tester.pump();
    final imageCache = PaintingBinding.instance.imageCache;
    expect(imageCache.statusForKey(key!).tracked, isTrue);

    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pump();

    expect(imageCache.statusForKey(key!).tracked, isFalse);
  });

  testWidgets('caps the requested image on very large monitors', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.display.size = const Size(7680, 4320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    final client = _RecordingClient();
    final multi = testMultiServer(clients: [client]);

    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
    await tester.pump();

    expect(client.requests.first.width, 3840);
    expect(client.requests.first.height, 3840);
  });

  group('sized to the monitor', () {
    Future<_RecordingClient> openIn(WidgetTester tester, {required Size window, required Size monitor}) async {
      tester.view.physicalSize = window;
      tester.view.display.size = monitor;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      final client = _RecordingClient();
      final multi = testMultiServer(clients: [client]);
      await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
      await tester.pump();
      return client;
    }

    testWidgets('a small window on a 1920 monitor asks for 1920', (tester) async {
      final client = await openIn(tester, window: const Size(1280, 757), monitor: const Size(1920, 1080));

      expect(client.requests.first.width, 1920);
      expect(client.requests.first.height, 1920);
    });

    testWidgets('a monitor in portrait uses its long edge', (tester) async {
      final client = await openIn(tester, window: const Size(700, 1000), monitor: const Size(1440, 2560));

      expect(client.requests.first.width, 2560);
    });

    testWidgets('the window stands in when no display size is reported', (tester) async {
      final client = await openIn(tester, window: const Size(1280, 757), monitor: Size.zero);

      expect(client.requests.first.width, 1280);
    });
  });

  test('a Plex part goes through the sized transcode endpoint without upscaling', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    PlexApiCache.initialize(database);

    final url = testPlexClient().thumbnailUrl(_partPath, width: 1000, height: 1000, cover: false);

    expect(url, contains('/photo/:/transcode?'));
    expect(url, contains('url=${Uri.encodeComponent('$_partPath?X-Plex-Token=token')}'));
    expect(url, contains('minSize=0'));
    expect(url, contains('upscale=0'));
  });

  testWidgets('BACK returns to the opener with focus restored', (tester) async {
    final openerFocus = FocusNode(debugLabel: 'opener');
    addTearDown(openerFocus.dispose);

    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              focusNode: openerFocus,
              autofocus: true,
              onPressed: () =>
                  Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PhotoViewerScreen(photo: _photo()))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewerScreen), findsNothing);
    expect(FocusManager.instance.primaryFocus, openerFocus);
  });

  group('keyboard and D-pad', () {
    FocusNode? primaryFocus() => FocusManager.instance.primaryFocus;

    /// Opens the viewer from a focused button, so a stray pop has somewhere to
    /// go and focus has somewhere to return to.
    Future<FocusNode> openFromButton(WidgetTester tester) async {
      final opener = FocusNode(debugLabel: 'opener');
      addTearDown(opener.dispose);
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                focusNode: opener,
                autofocus: true,
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => PhotoViewerScreen(photo: _photo())),
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
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
      return opener;
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    void runScenarios() {
      testWidgets('focus starts on the photo', (tester) async {
        await openFromButton(tester);

        expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
      });

      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.gameButtonA,
      ]) {
        testWidgets('${key.keyLabel} on the photo does nothing', (tester) async {
          await openFromButton(tester);

          await press(tester, key);

          expect(find.byType(PhotoViewerScreen), findsOneWidget);
          expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');
        });
      }

      testWidgets('Enter on the photo goes no further than the viewer', (tester) async {
        final reachedAbove = <LogicalKeyboardKey>[];
        await tester.pumpWidget(
          wrap(
            Focus(
              onKeyEvent: (_, event) {
                reachedAbove.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: PhotoViewerScreen(photo: _photo()),
            ),
          ),
        );
        await tester.pump();

        await press(tester, LogicalKeyboardKey.enter);

        expect(reachedAbove, isEmpty);
      });

      testWidgets('Up reaches the back button, and Enter on it closes the viewer', (tester) async {
        final opener = await openFromButton(tester);

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_back');
        expect(find.byType(PhotoViewerScreen), findsOneWidget);

        await press(tester, LogicalKeyboardKey.enter);
        expect(find.byType(PhotoViewerScreen), findsNothing);
        expect(primaryFocus(), opener);
      });

      testWidgets('Down leaves the back button, after which Enter does nothing again', (tester) async {
        await openFromButton(tester);

        await press(tester, LogicalKeyboardKey.arrowUp);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(primaryFocus()?.debugLabel, 'photo_viewer_photo');

        await press(tester, LogicalKeyboardKey.enter);
        expect(find.byType(PhotoViewerScreen), findsOneWidget);
      });

      testWidgets('Left and Right move nothing, from the photo or the back button', (tester) async {
        await openFromButton(tester);

        for (final label in ['photo_viewer_photo', 'photo_viewer_back']) {
          if (label == 'photo_viewer_back') await press(tester, LogicalKeyboardKey.arrowUp);
          await press(tester, LogicalKeyboardKey.arrowLeft);
          await press(tester, LogicalKeyboardKey.arrowRight);
          expect(primaryFocus()?.debugLabel, label);
          expect(find.byType(PhotoViewerScreen), findsOneWidget);
        }
      });

      testWidgets('Escape still closes the viewer from the photo', (tester) async {
        final opener = await openFromButton(tester);

        await press(tester, LogicalKeyboardKey.escape);

        expect(find.byType(PhotoViewerScreen), findsNothing);
        expect(primaryFocus(), opener);
      });
    }

    group('default', runScenarios);

    group('Force TV', () {
      setUp(() async => TvDetectionService.getInstance(forceTv: true));
      tearDown(TvDetectionService.debugReset);

      test('is on', () => expect(PlatformDetector.isTV(), isTrue));

      runScenarios();
    });
  });

  group('header', () {
    setUpAll(() => initializeDateFormatting('en'));

    Future<void> openPhoto(WidgetTester tester, MediaItem photo) async {
      await tester.pumpWidget(wrap(PhotoViewerScreen(photo: photo)));
      await tester.pump();
    }

    testWidgets('shows the title, and the capture date on a second line', (tester) async {
      await openPhoto(
        tester,
        _photo().copyWith(title: 'DSC05369_v1', parentTitle: 'Heri 80', originallyAvailableAt: '2020-12-24'),
      );

      final title = find.text('DSC05369_v1');
      final date = find.text('December 24, 2020');
      expect(title, findsOneWidget);
      expect(date, findsOneWidget);
      expect(find.text('Heri 80'), findsNothing);
      expect(tester.getTopLeft(date).dy, greaterThan(tester.getBottomLeft(title).dy - 1));
      expect(tester.widget<Text>(date).style!.fontSize, lessThan(tester.widget<Text>(title).style!.fontSize!));
    });

    testWidgets('falls back to the album name when the title is empty', (tester) async {
      await openPhoto(tester, _photo().copyWith(title: '', parentTitle: 'Heri 80'));

      expect(find.text('Heri 80'), findsOneWidget);
    });

    testWidgets('shows one line when there is no date', (tester) async {
      await openPhoto(tester, _photo().copyWith(title: 'DSC05369_v1', parentTitle: 'Heri 80'));

      final header = find.ancestor(of: find.text('DSC05369_v1'), matching: find.byType(Column)).first;
      expect(find.descendant(of: header, matching: find.byType(Text)), findsOneWidget);
    });

    testWidgets('shows an unparseable date as the server sent it', (tester) async {
      await openPhoto(tester, _photo().copyWith(originallyAvailableAt: 'sometime'));

      expect(find.text('sometime'), findsOneWidget);
    });

    testWidgets('the load error names the photo by the same title', (tester) async {
      await openPhoto(tester, _photo().copyWith(title: '', parentTitle: 'Heri 80'));

      expect(find.text(t.errors.unableToLoad(context: 'Heri 80')), findsOneWidget);
    });

    testWidgets('a Plex photo row carries its capture date to the header', (tester) async {
      final photo = PlexMappers.mediaItem(
        PlexMetadataDto.fromJsonWithImages({
          'ratingKey': '302855',
          'key': '/library/metadata/302855',
          'type': 'photo',
          'title': 'DSC05369_v1',
          'parentTitle': 'Heri 80',
          'originallyAvailableAt': '2020-12-24',
        }),
      );

      await openPhoto(tester, photo);

      expect(find.text('DSC05369_v1'), findsOneWidget);
      expect(find.text('December 24, 2020'), findsOneWidget);
    });
  });

  testWidgets('hides the system bars on a phone and restores them on close', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') calls.add(call);
      return null;
    });

    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo())));
    expect(calls.map((call) => call.arguments), ['SystemUiMode.immersiveSticky']);

    calls.clear();
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pump();
    expect(calls.map((call) => call.arguments), contains('SystemUiMode.edgeToEdge'));
  });

  testWidgets('a failure to show the system bars again is logged, not thrown', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode' && call.arguments != 'SystemUiMode.immersiveSticky') {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    MemoryLogOutput.clearLogs();

    await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo())));
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(MemoryLogOutput.getLogs().map((entry) => entry.message), contains('Failed to restore system UI'));
  });

  group('zoom', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo())));
      await tester.pump();
    }

    /// The zoom InteractiveViewer applies, read from the transform it paints.
    double scaleOf(WidgetTester tester) => tester
        .widget<Transform>(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Transform)).first)
        .transform
        .getMaxScaleOnAxis();

    testWidgets('a pinch zooms in', (tester) async {
      await open(tester);
      final center = tester.getCenter(find.byType(InteractiveViewer));

      final first = await tester.startGesture(center - const Offset(50, 0));
      final second = await tester.startGesture(center + const Offset(50, 0));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await first.moveBy(const Offset(-10, 0));
        await second.moveBy(const Offset(10, 0));
        await tester.pump();
      }

      expect(scaleOf(tester), greaterThan(2));
      await first.up();
      await second.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the mouse wheel zooms in', (tester) async {
      await open(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byType(InteractiveViewer))));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
      await tester.pump();

      expect(scaleOf(tester), greaterThan(1));
    });

    testWidgets('D-pad keys do not zoom', (tester) async {
      await open(tester);

      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      expect(scaleOf(tester), 1);
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
    });

    testWidgets('maximising the window afterwards does not refetch', (tester) async {
      tester.view.physicalSize = const Size(1280, 757);
      tester.view.display.size = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      final client = _RecordingClient(answersWithUrls: true);
      final multi = testMultiServer(clients: [client]);
      await tester.pumpWidget(wrap(PhotoViewerScreen(photo: _photo()), provider: multi.provider));
      await tester.pump();

      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pump();

      // Rebuilding asks for the same URL again, which the image cache serves.
      expect(client.requests.map((request) => request.width), everyElement(1920));
    });
  });

  group('zoom upgrade', () {
    setUp(() {
      // Holds the screen-sized image in its loading state: tests here assert on
      // the widget it stays in, and no artwork can load without a cache folder.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) => Completer<Object?>().future,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    /// Opens at a screen edge of 1000 pixels.
    Future<_FakeTransport> open(
      WidgetTester tester,
      MediaItem photo, {
      MediaServerClient? client,
      Future<ui.Image> Function(ui.ImmutableBuffer buffer, int edge)? decoder,
    }) async {
      tester.view.physicalSize = const Size(1000, 500);
      tester.view.display.size = const Size(1000, 500);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      final transport = _FakeTransport();
      final multi = testMultiServer(clients: [client ?? _RecordingClient(answersWithUrls: true)]);
      await tester.pumpWidget(
        wrap(
          PhotoViewerScreen(photo: photo, upgradeTransport: transport, upgradeDecoder: decoder),
          provider: multi.provider,
        ),
      );
      await tester.pump();
      return transport;
    }

    TransformationController zoomOf(WidgetTester tester) =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;

    Future<void> zoomTo(WidgetTester tester, double scale) async {
      zoomOf(tester).value = Matrix4.diagonal3Values(scale, scale, 1);
      await tester.pump();
    }

    String screenSizedUrl(WidgetTester tester) {
      final provider = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      return (provider.imageProvider as CachedNetworkImageProvider).url;
    }

    Iterable<RawImage> paintedImages(WidgetTester tester) =>
        tester.widgetList<RawImage>(find.byType(RawImage)).where((image) => image.image != null);

    /// Image decoding needs real time, which widget tests only get in runAsync.
    Future<void> settleDecode(WidgetTester tester, {required bool Function() until}) async {
      for (var i = 0; i < 200 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
    }

    testWidgets('stays on the screen-sized image up to and including 1.5x', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      await zoomTo(tester, 1.2);
      await zoomTo(tester, 1.5);

      expect(transport.requests, isEmpty);
      expect(screenSizedUrl(tester), 'https://server$_partPath?edge=1000');
    });

    testWidgets('requests one image at the original size past 1.5x', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      await zoomTo(tester, 1.51);
      await zoomTo(tester, 1);
      await zoomTo(tester, 3);

      expect(transport.requests.map((request) => request.url.toString()), ['https://server$_partPath?edge=5128']);
    });

    testWidgets('uses the long edge of a portrait original', (tester) async {
      final transport = await open(tester, _photo(width: 3190, height: 5128));

      await zoomTo(tester, 2);

      expect(transport.requests.single.url.queryParameters['edge'], '5128');
    });

    testWidgets('caps the request at 8192', (tester) async {
      final transport = await open(tester, _photo(width: 12000, height: 8000));

      await zoomTo(tester, 2);

      expect(transport.requests.single.url.queryParameters['edge'], '8192');
    });

    testWidgets('a pinch triggers the upgrade once past 1.5x, and zooms from its first movement', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));
      final center = tester.getCenter(find.byType(InteractiveViewer));

      final first = await tester.startGesture(center - const Offset(50, 0));
      await tester.pump();
      final second = await tester.startGesture(center + const Offset(50, 0));
      await tester.pump();

      Future<void> spread(int steps) async {
        for (var i = 0; i < steps; i++) {
          await first.moveBy(const Offset(-10, 0));
          await second.moveBy(const Offset(10, 0));
          await tester.pump();
        }
      }

      // From fingers 100 apart to 140: a double-tap recognizer in the arena
      // would still be holding this back as slop.
      await spread(2);
      expect(zoomOf(tester).value.getMaxScaleOnAxis(), closeTo(1.4, 0.01));
      expect(transport.requests, isEmpty);

      await spread(10);
      expect(zoomOf(tester).value.getMaxScaleOnAxis(), closeTo(3.4, 0.01));
      expect(transport.requests, hasLength(1));

      await first.up();
      await second.up();
      await tester.pump(const Duration(seconds: 1));
      expect(transport.requests, hasLength(1));
    });

    testWidgets('a double tap zooms around the tap, triggers the upgrade, and zooms back out', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));
      final viewer = find.byType(InteractiveViewer);
      final tapped = tester.getTopLeft(viewer) + const Offset(100, 50);

      Future<void> doubleTap() async {
        await tester.tapAt(tapped);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(tapped);
        await tester.pump(kDoubleTapTimeout);
      }

      await doubleTap();
      expect(zoomOf(tester).value.getMaxScaleOnAxis(), 2.5);
      final tappedInViewer = tester.firstRenderObject<RenderBox>(viewer).globalToLocal(tapped);
      expect(MatrixUtils.transformPoint(zoomOf(tester).value, const Offset(100, 50)), tappedInViewer);
      expect(transport.requests, hasLength(1));

      await doubleTap();
      expect(zoomOf(tester).value, Matrix4.identity());
      expect(transport.requests, hasLength(1));
    });

    group('double tap detection', () {
      Future<void> tapAt(WidgetTester tester, Offset position, Duration at) async {
        final gesture = await tester.createGesture();
        await gesture.down(position, timeStamp: at);
        await tester.pump();
        await gesture.up(timeStamp: at + const Duration(milliseconds: 20));
        await tester.pump();
      }

      testWidgets('two taps further apart in time do not zoom', (tester) async {
        await open(tester, _photo(width: 5128, height: 3190));
        final center = tester.getCenter(find.byType(InteractiveViewer));

        await tapAt(tester, center, Duration.zero);
        await tapAt(tester, center, kDoubleTapTimeout + const Duration(milliseconds: 100));

        expect(zoomOf(tester).value, Matrix4.identity());
      });

      testWidgets('two taps far apart on screen do not zoom', (tester) async {
        await open(tester, _photo(width: 5128, height: 3190));
        final center = tester.getCenter(find.byType(InteractiveViewer));

        await tapAt(tester, center - const Offset(150, 0), Duration.zero);
        await tapAt(tester, center + const Offset(150, 0), const Duration(milliseconds: 100));

        expect(zoomOf(tester).value, Matrix4.identity());
      });

      testWidgets('two fingers landing right after a tap do not zoom', (tester) async {
        await open(tester, _photo(width: 5128, height: 3190));
        final center = tester.getCenter(find.byType(InteractiveViewer));

        await tapAt(tester, center, Duration.zero);
        final first = await tester.createGesture(pointer: 11);
        final second = await tester.createGesture(pointer: 12);
        await first.down(center, timeStamp: const Duration(milliseconds: 100));
        await second.down(center + const Offset(40, 0), timeStamp: const Duration(milliseconds: 110));
        await first.up(timeStamp: const Duration(milliseconds: 150));
        await second.up(timeStamp: const Duration(milliseconds: 160));
        await tester.pump();

        expect(zoomOf(tester).value, Matrix4.identity());
      });

      testWidgets('a second press that drags pans instead of zooming', (tester) async {
        await open(tester, _photo(width: 5128, height: 3190));
        final center = tester.getCenter(find.byType(InteractiveViewer));

        await tapAt(tester, center, Duration.zero);
        final drag = await tester.createGesture();
        await drag.down(center, timeStamp: const Duration(milliseconds: 100));
        await tester.pump();
        await drag.moveBy(const Offset(60, 0));
        await tester.pump();
        await drag.up();
        await tester.pump(const Duration(seconds: 1));

        expect(zoomOf(tester).value.getMaxScaleOnAxis(), 1);
      });

      testWidgets('a drag pans a zoomed photo from its first movement', (tester) async {
        await open(tester, _photo(width: 5128, height: 3190));
        await zoomTo(tester, 3);
        zoomOf(tester).value = Matrix4.diagonal3Values(3, 3, 1)..setTranslationRaw(-500, -250, 0);
        final center = tester.getCenter(find.byType(InteractiveViewer));

        final drag = await tester.startGesture(center);
        await tester.pump();
        await drag.moveBy(const Offset(10, 0));
        await tester.pump();

        expect(zoomOf(tester).value.getTranslation().x, greaterThan(-500));
        await drag.up();
        await tester.pump(const Duration(seconds: 1));
      });
    });

    testWidgets('the mouse wheel triggers the upgrade', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byType(InteractiveViewer))));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
      await tester.pump();

      expect(transport.requests, hasLength(1));
    });

    testWidgets('D-pad keys neither zoom nor request anything', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      expect(zoomOf(tester).value, Matrix4.identity());
      expect(transport.requests, isEmpty);
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
    });

    testWidgets('makes no request when the original is no larger than what is loaded', (tester) async {
      final transport = await open(tester, _photo(width: 1000, height: 800));

      await zoomTo(tester, 3);

      expect(transport.requests, isEmpty);
    });

    testWidgets('makes no request when a dimension is missing', (tester) async {
      final transport = await open(tester, _photo(width: 5128));

      await zoomTo(tester, 3);

      expect(transport.requests, isEmpty);
    });

    testWidgets('swaps in the decoded image without moving the zoom or the layout', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));
      final zoom = Matrix4.diagonal3Values(3, 3, 1)..setTranslationRaw(-200, -100, 0);
      zoomOf(tester).value = zoom;
      await tester.pump();
      final sizeBefore = tester.getSize(find.byType(RawImage));

      expect(screenSizedUrl(tester), contains('edge=1000'));
      expect(paintedImages(tester), isEmpty);

      transport.respond(_pngBytes);
      await settleDecode(tester, until: () => paintedImages(tester).isNotEmpty);

      expect(paintedImages(tester).single.image!.width, 1);
      expect(find.byType(Image), findsNothing);
      expect(zoomOf(tester).value, zoom);
      expect(tester.getSize(find.byType(RawImage)), sizeBefore);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed request keeps the screen-sized image and does not retry', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      await zoomTo(tester, 2);
      transport.fail();
      await tester.pump();
      await zoomTo(tester, 1);
      await zoomTo(tester, 4);

      expect(screenSizedUrl(tester), 'https://server$_partPath?edge=1000');
      expect(find.text(t.errors.unableToLoad(context: 'Photo')), findsNothing);
      expect(transport.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an answer that is not an image keeps the screen-sized image', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      await zoomTo(tester, 2);
      transport.respond(utf8.encode('Internal Server Error'), status: 500);
      await settleDecode(tester, until: () => transport.closed);

      expect(screenSizedUrl(tester), 'https://server$_partPath?edge=1000');
      expect(paintedImages(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving the viewer cancels the request', (tester) async {
      final transport = await open(tester, _photo(width: 5128, height: 3190));

      await zoomTo(tester, 2);
      expect(transport.aborted, isFalse);

      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pump();

      expect(transport.aborted, isTrue);
      expect(transport.closed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an image that finishes decoding after the viewer closed is disposed', (tester) async {
      final decoding = Completer<ui.Image>();
      ui.ImmutableBuffer? handedOver;
      final transport = await open(
        tester,
        _photo(width: 5128, height: 3190),
        decoder: (buffer, edge) {
          handedOver = buffer;
          return decoding.future;
        },
      );
      await zoomTo(tester, 2);
      transport.respond(_pngBytes);
      await settleDecode(tester, until: () => handedOver != null);
      expect(handedOver, isNotNull);

      await tester.pumpWidget(wrap(const SizedBox()));
      final image = (await tester.runAsync(() => createTestImage(width: 1, height: 1)))!;
      decoding.complete(image);
      await tester.pump();

      expect(image.debugDisposed, isTrue);
      expect(tester.takeException(), isNull);
      handedOver!.dispose();
    });

    group('decoded size', () {
      setUp(DevicePerformance.debugReset);
      tearDown(DevicePerformance.debugReset);

      /// A PNG [width] by [height], so the decode has a real size to work with.
      Future<List<int>> png(WidgetTester tester, int width, int height) async {
        return (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint());
          final image = await recorder.endRecording().toImage(width, height);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
      }

      Future<ui.Image> decodedAfterServerSends(
        WidgetTester tester,
        MediaItem photo, {
        required int width,
        required int height,
      }) async {
        final bytes = await png(tester, width, height);
        final transport = await open(tester, photo);
        await zoomTo(tester, 2);
        transport.respond(bytes);
        await settleDecode(tester, until: () => paintedImages(tester).isNotEmpty);
        return paintedImages(tester).single.image!;
      }

      testWidgets('stays inside the requested edge when the server sends more', (tester) async {
        final image = await decodedAfterServerSends(tester, _photo(width: 5128, height: 3190), width: 6000, height: 40);

        expect((image.width, image.height), (5128, 34));
      });

      testWidgets('caps a very large original at 8192', (tester) async {
        final image = await decodedAfterServerSends(
          tester,
          _photo(width: 12000, height: 8000),
          width: 9000,
          height: 60,
        );

        expect((image.width, image.height), (8192, 55));
      });

      testWidgets('caps it at 4096 on the reduced tier, in the request and the decode', (tester) async {
        DevicePerformance.debugReset(autoReduced: true);
        expect(DevicePerformance.isReduced, isTrue);
        final bytes = await png(tester, 6000, 40);
        final transport = await open(tester, _photo(width: 12000, height: 8000));

        await zoomTo(tester, 2);
        expect(transport.requests.single.url.queryParameters['edge'], '4096');
        transport.respond(bytes);
        await settleDecode(tester, until: () => paintedImages(tester).isNotEmpty);

        final image = paintedImages(tester).single.image!;
        expect((image.width, image.height), (4096, 27));
      });
    });

    testWidgets('a Plex row asks the transcoder for the Part at the original size', (tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      PlexApiCache.initialize(database);
      final photo = PlexMappers.mediaItem(
        PlexMetadataDto.fromJsonWithImages({
          'ratingKey': '302855',
          'key': '/library/metadata/302855',
          'type': 'photo',
          'title': 'Photo',
          'thumb': '/library/metadata/302855/thumb/1',
          'Media': [
            {
              'id': 1,
              'width': 5128,
              'height': 3190,
              'Part': [
                {'id': 2, 'key': _partPath},
              ],
            },
          ],
        }).copyWith(serverId: ServerId('server_1')),
      );

      final transport = await open(tester, photo, client: testPlexClient(serverId: ServerId('server_1')));
      await zoomTo(tester, 2);

      final url = transport.requests.single.url;
      expect(url.path, '/photo/:/transcode');
      expect(url.queryParameters['width'], '5128');
      expect(url.queryParameters['height'], '5128');
      expect(url.queryParameters['minSize'], '0');
      expect(url.queryParameters['upscale'], '0');
      expect(url.queryParameters['url'], '$_partPath?X-Plex-Token=token');
    });

    testWidgets('a Jellyfin photo with dimensions asks its image route for the original size', (tester) async {
      final transport = await open(
        tester,
        _jellyfinPhoto(mediaVersions: const [MediaVersion(id: '1', width: 5128, height: 3190)]),
        client: testJellyfinClient(),
      );

      await zoomTo(tester, 2);

      final url = transport.requests.single.url;
      expect(url.path, '/Items/1/Images/Primary');
      expect(url.queryParameters['maxWidth'], '5128');
      expect(url.queryParameters['maxHeight'], '5128');
    });

    for (final dialect in MediaBrowserDialect.values) {
      testWidgets('a ${dialect.name} photo row with only its own size is upgraded', (tester) async {
        final photo = JellyfinMappers.mediaItem(
          {
            'Id': '1',
            'Type': 'Photo',
            'Name': 'Photo',
            'Width': 6024,
            'Height': 4024,
            'ImageTags': {'Primary': 'abc'},
          },
          serverId: ServerId('srv-1'),
          absolutizer: null,
          dialect: dialect,
        )!;
        final transport = await open(tester, photo, client: testJellyfinClient());

        await zoomTo(tester, 2);

        final url = transport.requests.single.url;
        expect(url.path, '/Items/1/Images/Primary');
        expect(url.queryParameters['maxWidth'], '6024');
        expect(url.queryParameters['maxHeight'], '6024');
      });
    }

    testWidgets('a Jellyfin photo with no dimensions skips the upgrade', (tester) async {
      final transport = await open(tester, _jellyfinPhoto(), client: testJellyfinClient());

      await zoomTo(tester, 2);

      expect(transport.requests, isEmpty);
    });
  });
}

MediaItem _photo({int? width, int? height}) =>
    testMediaItem(
      id: '1',
      backend: MediaBackend.plex,
      kind: MediaKind.photo,
      title: 'Photo',
      thumbPath: _thumbPath,
      serverId: 'server_1',
    ).copyWith(
      mediaVersions: [
        MediaVersion(
          id: '1',
          width: width,
          height: height,
          parts: const [MediaPart(id: 'p1', streamPath: _partPath)],
        ),
      ],
    );

MediaItem _jellyfinPhoto({List<MediaVersion>? mediaVersions}) => testMediaItem(
  id: '1',
  backend: MediaBackend.jellyfin,
  kind: MediaKind.photo,
  title: 'Photo',
  thumbPath: '/Items/1/Images/Primary?tag=abc',
  serverId: 'srv-1',
).copyWith(mediaVersions: mediaVersions);

/// Stands in for the platform transport under the real [http.Client] wrapper,
/// and answers only when the test says so.
class _FakeTransport extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final _response = Completer<http.StreamedResponse>();
  var aborted = false;
  var closed = false;

  void respond(List<int> bytes, {int status = 200}) {
    _response.complete(http.StreamedResponse(Stream.value(bytes), status, contentLength: bytes.length));
  }

  void fail() => _response.completeError(http.ClientException('offline'));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          aborted = true;
          if (!_response.isCompleted) _response.completeError(http.RequestAbortedException(request.url));
        }),
      );
    }
    return _response.future;
  }

  @override
  void close() => closed = true;
}

/// Answers every image request with no URL, which the viewer treats as a
/// failed load, so the sequence of attempts shows without touching the network.
class _RecordingClient implements MediaServerClient {
  _RecordingClient({this.answersWithUrls = false});

  /// Answers with a URL naming the requested path and size instead.
  final bool answersWithUrls;
  final requests = <({String? path, int? width, int? height, bool cover})>[];

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
    requests.add((path: path, width: width, height: height, cover: cover));
    return answersWithUrls ? 'https://server$path?edge=$width' : '';
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
