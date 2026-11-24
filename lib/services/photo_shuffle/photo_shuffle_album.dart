import 'dart:async';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../screens/photo_sequence_viewer.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';

/// The album an item is directly in.
typedef PhotoAlbumRef = ({String id, String title});

/// What a shuffled slideshow knows beyond its sequence: what it shuffles, and
/// how to reach the album of each item it shows.
class PhotoShuffleSession {
  const PhotoShuffleSession({required this.scope, required this.albums});

  /// Names what the slideshow shuffles: an album, folder, collection or
  /// library.
  final String scope;

  final PhotoShuffleAlbums albums;
}

/// Finds the album a shuffled item is directly in, never a grandparent, and
/// opens it as a sequence of its own, in the order its grid shows it.
class PhotoShuffleAlbums {
  PhotoShuffleAlbums({required this.client, this.libraryId, this.pageSize = 200});

  final MediaServerClient client;

  /// The library the shuffle runs in, when known. Its root is not an album,
  /// so the items directly in it have none.
  final String? libraryId;

  final int pageSize;

  /// Parents whose name had to be asked for, by id.
  final Map<String, Future<PhotoAlbumRef?>> _lookups = {};

  /// The album of [item] as far as the item itself says, without asking the
  /// server. Null when it has none, or when only the server knows its name.
  PhotoAlbumRef? knownAlbumOf(MediaItem item) {
    final id = _parentIdOf(item);
    final title = item.parentTitle;
    if (id == null || title == null || title.isEmpty) return null;
    return (id: id, title: title);
  }

  /// The album of [item], asking the server for its name when the item does
  /// not carry it (Jellyfin and Emby folders). Null when it has none, or when
  /// the parent is not an album or folder or cannot be read.
  Future<PhotoAlbumRef?> albumOf(MediaItem item) async {
    final known = knownAlbumOf(item);
    if (known != null) return known;
    final id = _parentIdOf(item);
    if (id == null) return null;
    return _lookups[id] ??= _lookUp(id);
  }

  String? _parentIdOf(MediaItem item) {
    final id = item.parentId;
    if (id == null || id.isEmpty || id == libraryId) return null;
    return id;
  }

  Future<PhotoAlbumRef?> _lookUp(String id) async {
    try {
      final parent = await client.fetchItem(id);
      if (parent == null) {
        appLogger.w('Photo shuffle: album $id was not found');
        return null;
      }
      if (parent.kind != MediaKind.photoAlbum && parent.kind != MediaKind.folder) {
        appLogger.d('Photo shuffle: parent $id is a ${parent.kind.name}, not an album');
        return null;
      }
      return (id: id, title: parent.displayTitle);
    } catch (error, stackTrace) {
      appLogger.w('Photo shuffle: could not read album $id', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Opens [album] as a looping sequence standing on [item], as soon as the
  /// page that holds it is loaded. The pages after it go on loading in the
  /// background. Null when the album cannot be read or does not hold [item].
  Future<PhotoAlbumSequence?> open(PhotoAlbumRef album, MediaItem item) async {
    final listing = _AlbumListing(client: client, albumId: album.id, pageSize: pageSize);
    final index = await listing.find(item);
    if (index == null) {
      appLogger.w('Photo shuffle: ${item.globalKey} could not be found in album ${album.id}');
      listing.dispose();
      return null;
    }
    unawaited(listing.loadRest());
    final sequence = PhotoSequence(
      index: index,
      photo: item,
      length: () => listing.total,
      itemAt: listing.itemAt,
      loadItemAt: listing.loadItemAt,
      loops: true,
    );
    return PhotoAlbumSequence._(album, sequence, listing);
  }
}

/// An album opened from a shuffle, and the sequence through it.
class PhotoAlbumSequence {
  PhotoAlbumSequence._(this.album, this.sequence, this._listing);

  final PhotoAlbumRef album;
  final PhotoSequence sequence;
  final _AlbumListing _listing;

  /// Everything the album holds, as the server counts it.
  int get total => _listing.total;

  /// Stops loading the album.
  void dispose() => _listing.dispose();
}

/// The children of an album, a page at a time, at the positions its grid
/// shows them at.
class _AlbumListing {
  _AlbumListing({required this.client, required this.albumId, required this.pageSize});

  final MediaServerClient client;
  final String albumId;
  final int pageSize;

  /// Taken from the server with every page.
  int total = 0;

  final Map<int, List<MediaItem>> _pages = {};
  final Map<int, Future<List<MediaItem>?>> _loading = {};
  final AbortController _abort = AbortController();

  int get _pageCount => (total + pageSize - 1) ~/ pageSize;

  MediaItem? itemAt(int index) {
    final page = _pages[index ~/ pageSize];
    final offset = index % pageSize;
    return page != null && offset < page.length ? page[offset] : null;
  }

  /// The item at [index], waiting for its page. Null when the page cannot be
  /// loaded.
  Future<MediaItem?> loadItemAt(int index) async {
    if (index < 0 || index >= total) return null;
    await _page(index ~/ pageSize);
    return itemAt(index);
  }

  /// Position of [item], loading pages from the first until the one that
  /// holds it. Null when it is in none of them or a page fails.
  Future<int?> find(MediaItem item) async {
    for (var page = 0; page == 0 || page < _pageCount; page++) {
      final items = await _page(page);
      if (items == null || items.isEmpty) return null;
      final offset = items.indexWhere((child) => child.id == item.id);
      if (offset >= 0) return page * pageSize + offset;
    }
    return null;
  }

  /// Loads the pages not loaded yet, one after the other.
  Future<void> loadRest() async {
    for (var page = 0; page < _pageCount && !_abort.isAborted; page++) {
      await _page(page);
    }
  }

  void dispose() => _abort.abort();

  /// A failed page is asked for again the next time it is needed.
  Future<List<MediaItem>?> _page(int page) => _loading[page] ??= _fetch(page);

  Future<List<MediaItem>?> _fetch(int page) async {
    try {
      final result = await client.fetchChildrenPage(albumId, start: page * pageSize, size: pageSize, abort: _abort);
      total = result.totalCount;
      _pages[page] = result.items;
      return result.items;
    } catch (error, stackTrace) {
      unawaited(_loading.remove(page));
      if (!_abort.isAborted) {
        appLogger.w('Photo shuffle: could not load page $page of album $albumId', error: error, stackTrace: stackTrace);
      }
      return null;
    }
  }
}
