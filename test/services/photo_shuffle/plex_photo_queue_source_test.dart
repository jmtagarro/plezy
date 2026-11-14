import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_source.dart';
import 'package:plezy/services/photo_shuffle/plex_photo_queue_source.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/media_items.dart';

const _jsonHeaders = {'content-type': 'application/json'};
const _machine = 'machine-1';

/// A Plex server holding one shuffled photo queue of [total] items. Creating
/// it answers with the first [firstWindow] items; reading it answers with the
/// window around the centre item asked for, as PMS does.
class _QueueServer {
  _QueueServer({required this.total, this.createStatus = 200});

  final int total;

  /// Items the queue's creation answers with, as PMS sends.
  static const int firstWindow = 21;
  final int createStatus;
  final requests = <http.Request>[];

  /// Holds back the answer to window reads while set.
  Completer<void>? windowGate;

  static int idAt(int index) => 1000 + index;

  Map<String, dynamic> _item(int index) => {
    'ratingKey': 'p$index',
    'key': '/library/metadata/p$index',
    'type': index % 10 == 9 ? 'clip' : 'photo',
    'title': 'Photo $index',
    'playQueueItemID': idAt(index),
  };

  http.Response _container(int from, int to) => http.Response(
    jsonEncode({
      'MediaContainer': {
        'playQueueID': 42,
        'playQueueVersion': 1,
        'playQueueSelectedItemID': idAt(0),
        'playQueueSelectedItemOffset': 0,
        'playQueueTotalCount': total,
        'playQueueShuffled': 1,
        'size': to - from,
        'Metadata': [for (var i = from; i < to; i++) _item(i)],
      },
    }),
    200,
    headers: _jsonHeaders,
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'POST' && request.url.path == '/playQueues') {
      if (createStatus != 200) return http.Response('{}', createStatus, headers: _jsonHeaders);
      return _container(0, firstWindow.clamp(0, total));
    }
    if (request.method == 'GET' && request.url.path == '/playQueues/42') {
      await windowGate?.future;
      final center = int.parse(request.url.queryParameters['center'] ?? '${idAt(0)}') - 1000;
      final window = int.parse(request.url.queryParameters['window']!);
      final from = (center - window ~/ 2).clamp(0, total);
      return _container(from, (from + window).clamp(0, total));
    }
    if (request.url.path == '/') {
      return http.Response(
        jsonEncode({
          'MediaContainer': {'machineIdentifier': _machine},
        }),
        200,
        headers: _jsonHeaders,
      );
    }
    return http.Response('{}', 404, headers: _jsonHeaders);
  }

  List<http.Request> get windowReads => [
    for (final r in requests)
      if (r.method == 'GET' && r.url.path == '/playQueues/42') r,
  ];
}

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  PlexClient clientFor(_QueueServer server) => testPlexClient(
    config: testPlexConfig(machineIdentifier: _machine, clientIdentifier: 'test-client', product: 'Plezy Test'),
    handler: server.handle,
  );

  final album = testMediaItem(id: '700', kind: MediaKind.photoAlbum, serverId: 'server-1');
  final collection = testMediaItem(id: '800', kind: MediaKind.collection, serverId: 'server-1');
  final folder = testMediaItem(
    id: 'folder-9',
    kind: MediaKind.folder,
    serverId: 'server-1',
  ).copyWith(backendFolderKey: '/library/sections/3/folder?parent=9');
  final library = MediaLibrary(
    id: '3',
    backend: MediaBackend.plex,
    title: 'Photos',
    kind: MediaKind.photo,
    serverId: 'server-1',
  );

  group('creates a shuffled, recursive photo queue', () {
    for (final (name, target, uri) in [
      (
        'an album',
        PhotoShuffleAlbum(album) as PhotoShuffleTarget,
        'server://$_machine/com.plexapp.plugins.library/library/metadata/700',
      ),
      (
        'a collection',
        PhotoShuffleCollection(collection),
        'server://$_machine/com.plexapp.plugins.library/library/collections/800',
      ),
      (
        'a folder',
        PhotoShuffleFolder(folder, libraryId: '3'),
        'server://$_machine/com.plexapp.plugins.library/library/sections/3/folder?parent=9',
      ),
      (
        'a library',
        PhotoShuffleLibrary(library),
        'server://$_machine/com.plexapp.plugins.library/library/sections/3/all',
      ),
    ]) {
      test('for $name', () async {
        final server = _QueueServer(total: 30);
        final client = clientFor(server);
        addTearDown(client.close);

        expect(await PlexPhotoQueueSource(client: client, target: target).start(), isTrue);

        final create = server.requests.singleWhere((r) => r.method == 'POST');
        expect(create.url.path, '/playQueues');
        expect(create.url.queryParameters, containsPair('type', 'photo'));
        expect(create.url.queryParameters, containsPair('shuffle', '1'));
        expect(create.url.queryParameters, containsPair('recursive', '1'));
        expect(create.url.queryParameters, containsPair('continuous', '0'));
        expect(create.url.queryParameters['uri'], uri);
        // PMS answers 400 to a queue request without them.
        expect(create.headers['X-Plex-Client-Identifier'], 'test-client');
        expect(create.headers['X-Plex-Product'], 'Plezy Test');
      });
    }
  });

  test('places the first window and the windows after it in queue order', () async {
    final server = _QueueServer(total: 120);
    final client = clientFor(server);
    addTearDown(client.close);
    final source = PlexPhotoQueueSource(client: client, target: PhotoShuffleAlbum(album));
    await source.start();

    expect(source.length, 120);
    expect(source.itemAt(20)?.id, 'p20');
    expect(source.itemAt(21), isNull);

    for (final index in [21, 44, 70, 119]) {
      expect((await source.loadItemAt(index))?.id, 'p$index');
    }
    expect(await source.loadItemAt(120), isNull);
    expect(source.itemAt(0)?.kind, MediaKind.photo);
    expect(source.itemAt(9)?.kind, MediaKind.clip);
  });

  test('fetches the next window ahead as the slideshow nears the end of the ones it has', () async {
    final server = _QueueServer(total: 120);
    final client = clientFor(server);
    addTearDown(client.close);
    final source = PlexPhotoQueueSource(client: client, target: PhotoShuffleAlbum(album));
    await source.start();

    source.shown(5);
    await pumpEventQueue();
    expect(server.windowReads, isEmpty, reason: 'far from the end of the first window');

    server.windowGate = Completer<void>();
    source.shown(13);
    source.shown(14);
    await pumpEventQueue();
    expect(server.windowReads, hasLength(1), reason: 'one window read at a time');
    expect(server.windowReads.single.url.queryParameters['center'], '${_QueueServer.idAt(20)}');

    server.windowGate!.complete();
    await pumpEventQueue();
    expect(source.itemAt(21)?.id, 'p21');
  });

  test('going back serves what was fetched, with no request', () async {
    final server = _QueueServer(total: 120);
    final client = clientFor(server);
    addTearDown(client.close);
    final source = PlexPhotoQueueSource(client: client, target: PhotoShuffleAlbum(album));
    await source.start();
    await source.loadItemAt(60);
    final reads = server.requests.length;

    for (var index = 60; index >= 0; index--) {
      expect((await source.loadItemAt(index))?.id, 'p$index');
    }
    expect(server.requests, hasLength(reads));
  });

  test('a refused queue throws, so the launcher can walk the album instead', () async {
    final server = _QueueServer(total: 10, createStatus: 400);
    final client = clientFor(server);
    addTearDown(client.close);

    await expectLater(
      PlexPhotoQueueSource(client: client, target: PhotoShuffleAlbum(album)).start(),
      throwsA(anything),
    );
  });

  test('an empty queue reports nothing to show', () async {
    final server = _QueueServer(total: 0);
    final client = clientFor(server);
    addTearDown(client.close);

    expect(await PlexPhotoQueueSource(client: client, target: PhotoShuffleAlbum(album)).start(), isFalse);
  });
}
