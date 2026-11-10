import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/photo_album_screen.dart';
import 'package:plezy/screens/photo_sequence_viewer.dart';
import 'package:plezy/screens/photo_viewer_screen.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/prefs.dart';

MediaItem _item(String id, MediaKind kind, String title) =>
    testMediaItem(id: id, backend: MediaBackend.plex, kind: kind, title: title, serverId: 'server_1');

final _album = _item('album', MediaKind.photoAlbum, 'Trip');

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  tearDown(ImmersiveModeGuard.resetForTesting);

  Future<Widget> wrap(Widget home, {List<MediaServerClient> clients = const []}) async {
    await SettingsService.getInstance();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    JellyfinApiCache.initialize(database);
    final downloadManager = DownloadManagerService(
      database: database,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    downloadManager.recoveryFuture = Future<void>.value();
    final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: database);
    await downloadProvider.ensureInitialized();
    addTearDown(() async {
      downloadProvider.dispose();
      downloadManager.dispose();
      await database.close();
    });
    final multi = testMultiServer(clients: clients);
    return TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
        ],
        child: InputModeTracker(
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: home),
        ),
      ),
    );
  }

  testWidgets('an album whose server is unavailable shows the load error', (tester) async {
    await tester.pumpWidget(await wrap(PhotoAlbumScreen(album: _album)));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(t.errors.unableToLoad(context: 'Trip')), findsOneWidget);
  });

  testWidgets('lists nested albums, photos and clips together with no actions', (tester) async {
    final client = _AlbumClient({
      'album': [
        _item('nested', MediaKind.photoAlbum, 'Day one'),
        _item('photo', MediaKind.photo, 'Sunset'),
        _item('clip', MediaKind.clip, 'Waves'),
      ],
    });

    await tester.pumpWidget(await wrap(PhotoAlbumScreen(album: _album), clients: [client]));
    await tester.pumpAndSettle();

    expect(find.byType(FocusableMediaCard), findsNWidgets(3));
    expect(find.text('Day one'), findsOneWidget);
    expect(find.text('Sunset'), findsOneWidget);
    expect(find.text('Waves'), findsOneWidget);
  });

  testWidgets('a nested album opens its own children and a photo opens the viewer', (tester) async {
    final client = _AlbumClient({
      'album': [_item('nested', MediaKind.photoAlbum, 'Day one')],
      'nested': [_item('photo', MediaKind.photo, 'Sunset')],
    });

    await tester.pumpWidget(await wrap(PhotoAlbumScreen(album: _album), clients: [client]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Day one'));
    await tester.pumpAndSettle();
    expect(find.text('Sunset'), findsOneWidget);
    expect(client.fetchedParents, ['album', 'nested']);

    await tester.tap(find.text('Sunset'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);
  });

  group('moving through the photos', () {
    String shownPhoto(WidgetTester tester) => tester.widget<PhotoViewerScreen>(find.byType(PhotoViewerScreen)).photo.id;

    FocusNode cardFocus(WidgetTester tester, String title) =>
        tester.widget<FocusableMediaCard>(find.widgetWithText(FocusableMediaCard, title)).focusNode!;

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    /// Opens the card titled [title] with the keyboard, which puts the app in
    /// keyboard mode.
    Future<void> openWithKeyboard(WidgetTester tester, String title) async {
      cardFocus(tester, title).requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(PhotoSequenceViewer), findsOneWidget);
    }

    final children = [
      _item('a', MediaKind.photo, 'A'),
      _item('clip', MediaKind.clip, 'Waves'),
      _item('b', MediaKind.photo, 'B'),
      _item('nested', MediaKind.photoAlbum, 'Day one'),
      _item('c', MediaKind.photo, 'C'),
    ];

    testWidgets('follow the grid, skipping clips and albums', (tester) async {
      await tester.pumpWidget(
        await wrap(
          PhotoAlbumScreen(album: _album),
          clients: [
            _AlbumClient({'album': children}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(shownPhoto(tester), 'a');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownPhoto(tester), 'b');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownPhoto(tester), 'c');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownPhoto(tester), 'c');
    });

    testWidgets('a nested album still opens as its card does, not in the viewer', (tester) async {
      await tester.pumpWidget(
        await wrap(
          PhotoAlbumScreen(album: _album),
          clients: [
            _AlbumClient({'album': children}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Day one'));
      await tester.pumpAndSettle();

      expect(find.byType(PhotoSequenceViewer), findsNothing);
      expect(find.byType(PhotoAlbumScreen, skipOffstage: false), findsNWidgets(2));
    });

    testWidgets('closing the viewer focuses the card of the photo it showed', (tester) async {
      await tester.pumpWidget(
        await wrap(
          PhotoAlbumScreen(album: _album),
          clients: [
            _AlbumClient({'album': children}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await openWithKeyboard(tester, 'A');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.escape);

      expect(find.byType(PhotoSequenceViewer), findsNothing);
      expect(FocusManager.instance.primaryFocus, cardFocus(tester, 'C'));
    });

    group('in a long album', () {
      // A photo first, then clips, with the second photo on the second page.
      final long = [
        for (var i = 0; i < 300; i++)
          i == 0
              ? _item('a', MediaKind.photo, 'A')
              : i == 251
              ? _item('b', MediaKind.photo, 'B')
              : _item('clip$i', MediaKind.clip, 'Clip $i'),
      ];

      void expectOnScreen(WidgetTester tester, String title) {
        final card = tester.getRect(find.widgetWithText(FocusableMediaCard, title));
        final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(screen.contains(card.center), isTrue, reason: '$card on $screen');
      }

      testWidgets('the viewer loads the next page, and closing reveals the card far down', (tester) async {
        final client = _AlbumClient({'album': long});
        await tester.pumpWidget(await wrap(PhotoAlbumScreen(album: _album), clients: [client]));
        await tester.pumpAndSettle();

        await openWithKeyboard(tester, 'A');
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(shownPhoto(tester), 'b');
        expect(client.fetchedStarts, [0, 200]);

        await press(tester, LogicalKeyboardKey.escape);
        expect(FocusManager.instance.primaryFocus, cardFocus(tester, 'B'));
        expectOnScreen(tester, 'B');
      });

      testWidgets('with touch, closing scrolls the card into view', (tester) async {
        await tester.pumpWidget(
          await wrap(
            PhotoAlbumScreen(album: _album),
            clients: [
              _AlbumClient({'album': long}),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.dragFrom(tester.getCenter(find.byType(InteractiveViewer)), const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(shownPhoto(tester), 'b');

        await tester.tap(find.byTooltip(t.common.back));
        await tester.pumpAndSettle();
        expectOnScreen(tester, 'B');
      });
    });
  });
}

class _AlbumClient implements MediaServerClient {
  final Map<String, List<MediaItem>> childrenByParent;
  final fetchedParents = <String>[];
  final fetchedStarts = <int?>[];

  _AlbumClient(this.childrenByParent);

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    fetchedParents.add(parentId);
    fetchedStarts.add(start);
    return fakeLibraryPage(childrenByParent[parentId] ?? const [], start: start, size: size);
  }

  /// No URL: cards and the viewer stay off the network.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => '';

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
