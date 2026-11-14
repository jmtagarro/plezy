import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/photo_shuffle/media_browser_photo_shuffle_source.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_source.dart';

import '../../test_helpers/backend_client_fixtures.dart';
import '../../test_helpers/media_items.dart';

const _jsonHeaders = {'content-type': 'application/json'};

/// Answers `/Items` with pages drawn from [pages] in turn, each a list of item
/// ids, and [total] as the record count.
class _RandomItems {
  _RandomItems(this.pages, {required this.total, this.failAfter});

  final List<List<String>> pages;
  final int total;
  final int? failAfter;
  final requests = <http.Request>[];

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/Items')) {
      requests.add(request);
      final call = requests.length - 1;
      if (failAfter != null && call >= failAfter!) return http.Response('{}', 500, headers: _jsonHeaders);
      final ids = call < pages.length ? pages[call] : const <String>[];
      return http.Response(
        jsonEncode({
          'Items': [
            for (final id in ids)
              {'Id': id, 'Name': id, 'Type': id.startsWith('v') ? 'Video' : 'Photo', 'ServerId': 'server'},
          ],
          'TotalRecordCount': total,
          'StartIndex': int.parse(request.url.queryParameters['StartIndex'] ?? '0'),
        }),
        200,
        headers: _jsonHeaders,
      );
    }
    return http.Response('{}', 200, headers: _jsonHeaders);
  }
}

void main() {
  final album = PhotoShuffleAlbum(testMediaItem(id: 'album-1', kind: MediaKind.photoAlbum, serverId: 'server-1'));

  test('asks for every photo and video under the container, in a random order, a page at a time', () async {
    final server = _RandomItems([
      ['a', 'b'],
      ['c', 'v1'],
    ], total: 4);
    final source = MediaBrowserPhotoShuffleSource(
      client: testJellyfinClient(handler: server.handle),
      target: album,
      pageSize: 2,
    );

    expect(await source.start(), isTrue);
    expect((await source.loadItemAt(3))?.id, 'v1');
    expect(source.itemAt(3)?.kind, MediaKind.clip);

    final first = server.requests.first.url.queryParameters;
    expect(first['ParentId'], 'album-1');
    expect(first['Recursive'], 'true');
    expect(first['SortBy'], 'Random');
    expect(first['IncludeItemTypes'], 'Photo,Video');
    expect(first['StartIndex'], '0');
    expect(first['Limit'], '2');
    expect(server.requests[1].url.queryParameters['StartIndex'], '2');
  });

  test('drops repeats, and ends once every item has been seen', () async {
    final server = _RandomItems([
      ['a', 'b'],
      ['b', 'c'],
      ['a', 'd'],
    ], total: 6);
    final source = MediaBrowserPhotoShuffleSource(
      client: testEmbyClient(handler: server.handle),
      target: album,
      pageSize: 2,
    );

    await source.start();
    final ids = <String>[];
    for (var i = 0; ; i++) {
      final item = await source.loadItemAt(i);
      if (item == null) break;
      ids.add(item.id);
    }
    expect(ids, ['a', 'b', 'c', 'd']);
    expect(source.length, 4);
  });

  test('ends after pages that bring nothing new', () async {
    final server = _RandomItems([
      ['a'],
      ['a'],
      ['a'],
      ['a'],
      ['b'],
    ], total: 100);
    final source = MediaBrowserPhotoShuffleSource(
      client: testJellyfinClient(handler: server.handle),
      target: album,
      pageSize: 1,
    );

    await source.start();
    expect(await source.loadItemAt(1), isNull);
    expect(server.requests, hasLength(4));
  });

  test('fetches the next page ahead near the end of what it has', () async {
    final server = _RandomItems([
      [for (var i = 0; i < 20; i++) 'p$i'],
      [for (var i = 20; i < 40; i++) 'p$i'],
    ], total: 40);
    final source = MediaBrowserPhotoShuffleSource(
      client: testJellyfinClient(handler: server.handle),
      target: album,
      pageSize: 20,
    );
    await source.start();

    source.shown(5);
    await pumpEventQueue();
    expect(server.requests, hasLength(1));
    source.shown(12);
    await pumpEventQueue();
    expect(server.requests, hasLength(2));
    expect(source.itemAt(39)?.id, 'p39');
  });

  test('a failing first page throws, so the launcher can walk the container instead', () async {
    final server = _RandomItems(const [], total: 0, failAfter: 0);
    final source = MediaBrowserPhotoShuffleSource(
      client: testJellyfinClient(handler: server.handle),
      target: album,
    );

    await expectLater(source.start(), throwsA(anything));
  });

  test('a later failure ends the slideshow there', () async {
    final server = _RandomItems(
      [
        ['a'],
      ],
      total: 5,
      failAfter: 1,
    );
    final source = MediaBrowserPhotoShuffleSource(
      client: testJellyfinClient(handler: server.handle),
      target: album,
      pageSize: 1,
    );

    await source.start();
    expect(await source.loadItemAt(1), isNull);
    expect(source.length, 1);
  });
}
