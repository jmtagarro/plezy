import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/photo_shuffle/media_browser_photo_shuffle_source.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_launcher.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_source.dart';
import 'package:plezy/services/photo_shuffle/photo_walk_source.dart';
import 'package:plezy/services/photo_shuffle/plex_photo_queue_source.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/media_items.dart';

const _jsonHeaders = {'content-type': 'application/json'};

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: _jsonHeaders);

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  final album = PhotoShuffleAlbum(testMediaItem(id: '700', kind: MediaKind.photoAlbum, serverId: 'server-1'));

  /// A Plex server whose album holds two photos, and whose play queues answer
  /// [queue].
  Future<http.Response> Function(http.Request) plexServer(http.Response Function() queue) => (request) async {
    if (request.method == 'POST' && request.url.path == '/playQueues') return queue();
    if (request.url.path.startsWith('/playQueues/')) return queue();
    if (request.url.path == '/library/metadata/700/children') {
      return _json({
        'MediaContainer': {
          'size': 2,
          'totalSize': 2,
          'Metadata': [
            for (final id in ['a', 'b'])
              {'ratingKey': id, 'key': '/library/metadata/$id', 'type': 'photo', 'title': id},
          ],
        },
      });
    }
    return _json({
      'MediaContainer': {'machineIdentifier': 'machine-1'},
    });
  };

  test('uses the server play queue when it has items', () async {
    final client = testPlexClient(
      config: testPlexConfig(machineIdentifier: 'machine-1'),
      handler: plexServer(
        () => _json({
          'MediaContainer': {
            'playQueueID': 1,
            'playQueueVersion': 1,
            'playQueueTotalCount': 1,
            'Metadata': [
              {'ratingKey': 'q', 'key': '/library/metadata/q', 'type': 'photo', 'title': 'q', 'playQueueItemID': 5},
            ],
          },
        }),
      ),
    );
    addTearDown(client.close);

    final opened = await PhotoShuffleLauncher.open(client, album);

    expect(opened?.source, isA<PlexPhotoQueueSource>());
    expect(opened?.sequence.photo.id, 'q');
  });

  for (final (name, queue) in [
    ('refuses the queue (400)', () => _json({}, 400)),
    (
      'answers with an empty queue',
      () => _json({
        'MediaContainer': {'playQueueID': 1, 'playQueueVersion': 1, 'playQueueTotalCount': 0, 'Metadata': <Object>[]},
      }),
    ),
  ]) {
    test('walks the album on the device when the server $name', () async {
      final client = testPlexClient(
        config: testPlexConfig(machineIdentifier: 'machine-1'),
        handler: plexServer(queue),
      );
      addTearDown(client.close);

      final opened = await PhotoShuffleLauncher.open(client, album);

      expect(opened?.source, isA<PhotoWalkSource>());
      expect({'a', 'b'}, contains(opened?.sequence.photo.id));
    });
  }

  test('walks a Jellyfin album when the random query fails', () async {
    final client = testJellyfinClient(
      handler: (request) async {
        if (request.url.queryParameters['SortBy'] == 'Random') return _json({}, 500);
        if (request.url.path.endsWith('/Items')) {
          return _json({
            'Items': [
              {'Id': 'a', 'Name': 'a', 'Type': 'Photo'},
            ],
            'TotalRecordCount': 1,
          });
        }
        return _json({});
      },
    );

    final opened = await PhotoShuffleLauncher.open(client, album);

    expect(opened?.source, isA<PhotoWalkSource>());
    expect(opened?.sequence.photo.id, 'a');
  });

  test('uses the Jellyfin random query when it answers', () async {
    final client = testJellyfinClient(
      handler: (request) async => _json({
        'Items': [
          {'Id': 'r', 'Name': 'r', 'Type': 'Photo'},
        ],
        'TotalRecordCount': 1,
      }),
    );

    final opened = await PhotoShuffleLauncher.open(client, album);

    expect(opened?.source, isA<MediaBrowserPhotoShuffleSource>());
  });

  test('nothing anywhere means nothing to open', () async {
    final client = testPlexClient(
      config: testPlexConfig(machineIdentifier: 'machine-1'),
      handler: (request) async => request.method == 'POST'
          ? _json({}, 400)
          : _json({
              'MediaContainer': {'size': 0, 'totalSize': 0, 'Metadata': <Object>[]},
            }),
    );
    addTearDown(client.close);

    expect(await PhotoShuffleLauncher.open(client, album), isNull);
  });
}
