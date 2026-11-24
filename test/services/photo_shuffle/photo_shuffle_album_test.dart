import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/photo_shuffle/photo_shuffle_album.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../../test_helpers/media_items.dart';

MediaItem _item(String id, MediaKind kind, {String? parentId, String? parentTitle}) =>
    testMediaItem(id: id, kind: kind, title: id, serverId: 'server-1', parentId: parentId, parentTitle: parentTitle);

MediaItem _photo(String id, {String? parentId, String? parentTitle}) =>
    _item(id, MediaKind.photo, parentId: parentId, parentTitle: parentTitle);

/// Albums by id, paged as a server pages them, and the items [fetchItem]
/// knows. A page whose start is in [held] waits until it is completed.
class _AlbumClient implements MediaServerClient {
  _AlbumClient({this.albums = const {}, this.items = const {}});

  final Map<String, List<MediaItem>> albums;
  final Map<String, MediaItem> items;
  final Map<String, Completer<void>> held = {};
  final Set<String> failing = {};
  final fetched = <String>[];
  final lookedUp = <String>[];

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
    if (failing.remove(key)) throw StateError('cannot read $key');
    final all = albums[parentId] ?? const [];
    final from = (start ?? 0).clamp(0, all.length);
    final to = (from + (size ?? all.length)).clamp(0, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    lookedUp.add(id);
    if (failing.contains(id)) throw StateError('cannot read $id');
    return items[id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('the album of an item', () {
    test('is the parent the item names, with its title', () async {
      final albums = PhotoShuffleAlbums(client: _AlbumClient());
      final photo = _photo('x', parentId: 'album-1', parentTitle: 'Summer');

      expect(albums.knownAlbumOf(photo), (id: 'album-1', title: 'Summer'));
      expect(await albums.albumOf(photo), (id: 'album-1', title: 'Summer'));
    });

    test('is none without a parent, or when the parent is the library itself', () async {
      final client = _AlbumClient();
      final albums = PhotoShuffleAlbums(client: client, libraryId: 'library-1');

      expect(await albums.albumOf(_photo('x')), isNull);
      expect(await albums.albumOf(_photo('y', parentId: 'library-1', parentTitle: 'Photos')), isNull);
      expect(await albums.albumOf(_photo('z', parentId: 'library-1')), isNull);
      expect(client.lookedUp, isEmpty);
    });

    test('is looked up once by its id when the item does not carry its name, as in Jellyfin folders', () async {
      final client = _AlbumClient(items: {'folder-1': _item('folder-1', MediaKind.folder).copyWith(title: 'Trip')});
      final albums = PhotoShuffleAlbums(client: client);

      expect(albums.knownAlbumOf(_photo('x', parentId: 'folder-1')), isNull);
      expect(await albums.albumOf(_photo('x', parentId: 'folder-1')), (id: 'folder-1', title: 'Trip'));
      expect(await albums.albumOf(_photo('y', parentId: 'folder-1')), (id: 'folder-1', title: 'Trip'));
      expect(client.lookedUp, ['folder-1']);
    });

    test('is none when the parent is not an album or folder, is missing, or cannot be read', () async {
      final client = _AlbumClient(items: {'collection-1': _item('collection-1', MediaKind.collection)})
        ..failing.add('broken');
      final albums = PhotoShuffleAlbums(client: client);

      expect(await albums.albumOf(_photo('x', parentId: 'collection-1')), isNull);
      expect(await albums.albumOf(_photo('y', parentId: 'gone')), isNull);
      expect(await albums.albumOf(_photo('z', parentId: 'broken')), isNull);
    });
  });

  group('opening an album', () {
    const album = (id: 'album-1', title: 'Summer');
    final children = [
      _photo('p0'),
      _item('sub', MediaKind.photoAlbum),
      _photo('p2'),
      _item('c3', MediaKind.clip),
      _photo('p4'),
      _photo('p5'),
      _photo('p6'),
    ];

    test('stands on the item, at its place in the album, and loops in the album order', () async {
      final client = _AlbumClient(albums: {'album-1': children});
      final albums = PhotoShuffleAlbums(client: client, pageSize: 3);
      final shown = children[3];

      final opened = (await albums.open(album, shown))!;
      final sequence = opened.sequence;

      expect(sequence.index, 3);
      expect(identical(sequence.photo, shown), isTrue, reason: 'the item on screen is the one kept');
      expect(sequence.loops, isTrue);
      expect(opened.total, 7);
      expect((await sequence.neighbour(3, 1))?.photo.id, 'p4');
      expect((await sequence.neighbour(6, 1))?.photo.id, 'p0', reason: 'after the last comes the first');
      expect((await sequence.neighbour(0, 1))?.photo.id, 'p2', reason: 'the sub-album is passed over');
      expect((await sequence.neighbour(0, -1))?.photo.id, 'p6', reason: 'before the first comes the last');
      expect((await sequence.neighbour(2, -1))?.photo.id, 'p0');
      opened.dispose();
    });

    test('opens once the page holding the item is in, and loads the rest behind it', () async {
      final client = _AlbumClient(albums: {'album-1': children});
      final later = client.held['album-1@6'] = Completer<void>();
      final albums = PhotoShuffleAlbums(client: client, pageSize: 3);

      final opened = (await albums.open(album, children[3]))!;
      expect(opened.sequence.index, 3);
      expect(opened.total, 7, reason: 'the server says how many there are before every page is in');
      expect(opened.sequence.length, 7);
      await pumpEventQueue();
      expect(client.fetched, ['album-1@0', 'album-1@3', 'album-1@6']);

      // Past the end, the wrap waits for the page still loading.
      final wrapped = opened.sequence.neighbour(5, 1);
      var done = false;
      unawaited(wrapped.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse);
      later.complete();
      expect((await wrapped)?.photo.id, 'p6');
      expect(client.fetched.where((key) => key == 'album-1@6'), hasLength(1), reason: 'one fetch serves both');
      opened.dispose();
    });

    test('is null when the album does not hold the item, or its pages cannot be read', () async {
      final client = _AlbumClient(albums: {'album-1': children});
      final albums = PhotoShuffleAlbums(client: client, pageSize: 3);

      expect(await albums.open(album, _photo('elsewhere')), isNull);
      client.failing.add('album-1@0');
      expect(await albums.open(album, children[0]), isNull);
    });

    test('asks again for a page that failed, the next time it is needed', () async {
      final client = _AlbumClient(albums: {'album-1': children});
      final albums = PhotoShuffleAlbums(client: client, pageSize: 3);
      client.failing.add('album-1@6');

      final opened = (await albums.open(album, children[0]))!;
      await pumpEventQueue();

      expect((await opened.sequence.neighbour(0, -1))?.photo.id, 'p6');
      expect(client.fetched.where((key) => key == 'album-1@6'), hasLength(2));
      opened.dispose();
    });
  });
}
