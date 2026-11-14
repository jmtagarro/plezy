import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_source.dart';
import 'package:plezy/services/photo_shuffle/photo_walk_source.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../../test_helpers/media_items.dart';

MediaItem _photo(String id) => testMediaItem(id: id, kind: MediaKind.photo, serverId: 'server-1');
MediaItem _album(String id) => testMediaItem(id: id, kind: MediaKind.photoAlbum, serverId: 'server-1');
MediaItem _folder(String id) => testMediaItem(id: id, kind: MediaKind.folder, serverId: 'server-1');

/// Albums and folders by id, paged as a server pages them. Pages of an album
/// listed in [held] wait until it is completed.
class _TreeClient implements MediaServerClient {
  _TreeClient(this.children, {this.held = const {}, this.failing = const {}});

  final Map<String, List<MediaItem>> children;
  final Map<String, Completer<void>> held;
  final Set<String> failing;
  final fetched = <String>[];

  Future<LibraryPage<MediaItem>> _page(String id, int? start, int? size) async {
    fetched.add('$id@${start ?? 0}');
    await held[id]?.future;
    if (failing.contains(id)) throw StateError('cannot read $id');
    final all = children[id] ?? const [];
    final from = (start ?? 0).clamp(0, all.length);
    final to = (from + (size ?? all.length)).clamp(0, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(String parentId, {int? start, int? size, AbortController? abort}) =>
      _page(parentId, start, size);

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => (await _page(folder.id, 0, null)).items;

  @override
  Future<List<MediaItem>> fetchLibraryFolders(
    String libraryId, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => (await _page(libraryId, 0, null)).items;

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) => _page(collectionId, start, size);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<List<String>> drawAll(PhotoWalkSource source) async {
    final ids = <String>[];
    for (var i = 0; ; i++) {
      final item = await source.loadItemAt(i);
      if (item == null) return ids;
      ids.add(item.id);
    }
  }

  test('goes into nested albums and folders, and draws every photo and clip once', () async {
    final client = _TreeClient({
      'top': [_photo('a'), _album('trip'), _folder('raw'), testMediaItem(id: 'v', kind: MediaKind.clip)],
      'trip': [_photo('b'), _album('day'), _photo('c')],
      'day': [_photo('d')],
      'raw': [_photo('e'), _photo('a')],
    });
    final source = PhotoWalkSource(client: client, target: PhotoShuffleAlbum(_album('top')), random: Random(1));

    expect(await source.start(), isTrue);
    final drawn = await drawAll(source);

    expect(drawn.toSet(), {'a', 'b', 'c', 'd', 'e', 'v'});
    expect(drawn, hasLength(6), reason: 'an item found twice is shown once');
    expect(source.exhausted, isTrue);
    expect(source.length, 6);
  });

  test('starts once 30 items are in, and keeps collecting behind the slideshow', () async {
    final rest = Completer<void>();
    final client = _TreeClient(
      {
        'top': [for (var i = 0; i < 40; i++) _photo('p$i'), _album('more')],
        'more': [for (var i = 0; i < 20; i++) _photo('m$i')],
      },
      held: {'more': rest},
    );
    final source = PhotoWalkSource(client: client, target: PhotoShuffleAlbum(_album('top')), random: Random(2));

    expect(await source.start(), isTrue, reason: 'ready without waiting for the nested album');
    expect(source.exhausted, isFalse);
    final first = [for (var i = 0; i < 40; i++) (await source.loadItemAt(i))!.id];
    expect(first.every((id) => id.startsWith('p')), isTrue);

    final waiting = source.loadItemAt(40);
    rest.complete();
    expect((await waiting)!.id, startsWith('m'));
    expect(await drawAll(source), hasLength(60));
  });

  test('pages through a large album, page by page', () async {
    final client = _TreeClient({
      'big': [for (var i = 0; i < 450; i++) _photo('p$i')],
    });
    final source = PhotoWalkSource(client: client, target: PhotoShuffleAlbum(_album('big')));

    await source.start();
    expect(await drawAll(source), hasLength(450));
    expect(client.fetched, ['big@0', 'big@200', 'big@400']);
  });

  test('going back walks the same order', () async {
    final client = _TreeClient({
      'top': [for (var i = 0; i < 10; i++) _photo('p$i')],
    });
    final source = PhotoWalkSource(client: client, target: PhotoShuffleAlbum(_album('top')));
    await source.start();
    final forward = await drawAll(source);

    expect([for (var i = forward.length - 1; i >= 0; i--) source.itemAt(i)!.id], forward.reversed.toList());
  });

  test('skips a part it cannot read, and walks the rest', () async {
    final client = _TreeClient(
      {
        'top': [_album('broken'), _photo('a')],
        'broken': [_photo('x')],
      },
      failing: {'broken'},
    );
    final source = PhotoWalkSource(client: client, target: PhotoShuffleAlbum(_album('top')));

    expect(await source.start(), isTrue);
    expect(await drawAll(source), ['a']);
  });

  test('walks a library from its folders and a collection from its pages', () async {
    final library = MediaLibrary(
      id: 'lib',
      backend: MediaBackend.plex,
      title: 'Photos',
      kind: MediaKind.photo,
      serverId: 'server-1',
    );
    final client = _TreeClient({
      'lib': [_folder('f')],
      'f': [_photo('a')],
      'col': [_photo('b')],
    });

    final fromLibrary = PhotoWalkSource(client: client, target: PhotoShuffleLibrary(library));
    await fromLibrary.start();
    expect(await drawAll(fromLibrary), ['a']);

    final fromCollection = PhotoWalkSource(
      client: client,
      target: PhotoShuffleCollection(testMediaItem(id: 'col', kind: MediaKind.collection)),
    );
    await fromCollection.start();
    expect(await drawAll(fromCollection), ['b']);
  });

  test('an empty container has nothing to show', () async {
    final source = PhotoWalkSource(client: _TreeClient({'top': []}), target: PhotoShuffleAlbum(_album('top')));
    expect(await source.start(), isFalse);
  });
}
