import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../screens/photo_sequence_viewer.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import 'photo_shuffle_source.dart';

/// Shuffles a container on the device: walks it with the ordinary children
/// and folder fetches, going into nested albums and folders, and draws each
/// next item at random from everything collected so far. The slideshow starts
/// once [readyAfter] items are in, while the walk goes on collecting. Used
/// where the server cannot shuffle the container itself.
class PhotoWalkSource extends PhotoShuffleSource {
  PhotoWalkSource({
    required this.client,
    required this.target,
    Random? random,
    this.readyAfter = 30,
    this.pageSize = 200,
  }) : _random = random ?? Random();

  final MediaServerClient client;
  final PhotoShuffleTarget target;
  final Random _random;

  /// Items collected before the slideshow starts.
  final int readyAfter;

  final int pageSize;

  /// Collected and not drawn yet.
  final List<MediaItem> _pool = [];

  /// Drawn so far, in the order shown.
  final List<MediaItem> _drawn = [];

  final Set<String> _seen = {};
  final AbortController _abort = AbortController();
  bool _walkDone = false;
  Completer<void>? _grew;

  bool get exhausted => _walkDone && _pool.isEmpty;

  @override
  Future<bool> start() async {
    unawaited(_walk());
    while (!_walkDone && _pool.length < readyAfter) {
      await _waitForMore();
    }
    return _pool.isNotEmpty;
  }

  @override
  int get length => _drawn.length + (exhausted ? 0 : 1);

  @override
  MediaItem? itemAt(int index) => index < _drawn.length ? _drawn[index] : null;

  @override
  Future<MediaItem?> loadItemAt(int index) async {
    while (index >= _drawn.length) {
      if (_pool.isNotEmpty) {
        _drawn.add(_pool.removeAt(_random.nextInt(_pool.length)));
      } else if (_walkDone) {
        return null;
      } else {
        await _waitForMore();
      }
    }
    return _drawn[index];
  }

  @override
  void dispose() => _abort.abort();

  Future<void> _waitForMore() => (_grew ??= Completer<void>()).future;

  void _signal() {
    final grew = _grew;
    _grew = null;
    grew?.complete();
  }

  Future<void> _walk() async {
    _pending.add(_readRoot);
    try {
      while (_pending.isNotEmpty && !_abort.isAborted) {
        try {
          await _pending.removeFirst()();
        } catch (error, stackTrace) {
          if (_abort.isAborted) break;
          appLogger.w(
            'Photo shuffle: part of ${target.logLabel} could not be read',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    } finally {
      _walkDone = true;
      appLogger.d('Photo shuffle: walked ${target.logLabel}, ${_seen.length} items');
      _signal();
    }
  }

  /// Containers still to read, in the order found.
  final Queue<Future<void> Function()> _pending = Queue();

  /// Puts the photos and clips of [children] in the pool, and queues the
  /// albums and folders among them to be read in turn.
  void _take(List<MediaItem> children) {
    for (final child in children) {
      if (PhotoSequence.shows(child)) {
        if (_seen.add(child.globalKey)) _pool.add(child);
      } else if (child.kind == MediaKind.photoAlbum) {
        _pending.add(
          () => _readPages((start) => client.fetchChildrenPage(child.id, start: start, size: pageSize, abort: _abort)),
        );
      } else if (child.kind == MediaKind.folder) {
        _pending.add(() async => _take(await client.fetchFolderChildren(child, libraryId: _libraryId)));
      }
    }
    _signal();
  }

  String? get _libraryId => switch (target) {
    PhotoShuffleLibrary(:final library) => library.id,
    PhotoShuffleFolder(:final libraryId) => libraryId,
    _ => null,
  };

  Future<void> _readRoot() async => switch (target) {
    PhotoShuffleAlbum(:final album) => await _readPages(
      (start) => client.fetchChildrenPage(album.id, start: start, size: pageSize, abort: _abort),
    ),
    PhotoShuffleCollection(:final collection) => await _readPages(
      (start) => client.fetchCollectionPage(collection.id, start: start, size: pageSize, abort: _abort),
    ),
    PhotoShuffleFolder(:final folder, :final libraryId, :final libraryTitle) => _take(
      await client.fetchFolderChildren(folder, libraryId: libraryId, libraryTitle: libraryTitle),
    ),
    PhotoShuffleLibrary(:final library) => _take(await client.fetchLibraryFolders(library.id)),
  };

  /// Every page of a paged list, each taken into the pool as it arrives, so
  /// the slideshow can start before a large album is read to its end.
  Future<void> _readPages(Future<LibraryPage<MediaItem>> Function(int start) fetch) async {
    var start = 0;
    while (!_abort.isAborted) {
      final page = await fetch(start);
      _take(page.items);
      start += page.items.length;
      if (page.items.isEmpty || start >= page.totalCount) break;
    }
  }
}
