import 'dart:async';

import '../../media/media_item.dart';
import '../../screens/photo_sequence_viewer.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import '../jellyfin_client.dart';
import 'photo_shuffle_source.dart';

/// The photos and videos anywhere under a Jellyfin or Emby container, in the
/// server's random order (`Recursive`, `SortBy=Random`), a page at a time. The
/// order is drawn again for every page, so repeats are dropped; the
/// slideshow ends once every item has been seen, or when pages stop bringing
/// new ones.
class MediaBrowserPhotoShuffleSource extends PhotoShuffleSource {
  MediaBrowserPhotoShuffleSource({
    required this.client,
    required this.target,
    this.pageSize = 100,
    this.fetchAheadMargin = 8,
    this.staleLimit = 3,
  });

  final JellyfinClient client;
  final PhotoShuffleTarget target;
  final int pageSize;
  final int fetchAheadMargin;

  /// Pages in a row with nothing new after which the slideshow ends.
  final int staleLimit;

  final List<MediaItem> _items = [];
  final Set<String> _ids = {};
  final AbortController _abort = AbortController();
  int _nextStart = 0;
  int _total = 0;
  int _stalePages = 0;
  bool _exhausted = false;
  Future<void>? _fetching;

  @override
  Future<bool> start() async {
    await _fetchPage();
    return _items.isNotEmpty;
  }

  @override
  int get length => _items.length + (_exhausted ? 0 : 1);

  @override
  MediaItem? itemAt(int index) => index < _items.length ? _items[index] : null;

  @override
  Future<MediaItem?> loadItemAt(int index) async {
    while (index >= _items.length && !_exhausted) {
      await _fetchAhead();
    }
    return itemAt(index);
  }

  @override
  void shown(int index) {
    if (!_exhausted && _items.length - 1 - index <= fetchAheadMargin) unawaited(_fetchAhead());
  }

  @override
  void dispose() => _abort.abort();

  Future<void> _fetchAhead() => _fetching ??= _fetchPage()
      .catchError((Object error, StackTrace stackTrace) {
        appLogger.w('Photo shuffle: could not fetch more of ${target.logLabel}', error: error, stackTrace: stackTrace);
        _exhausted = true;
      })
      .whenComplete(() => _fetching = null);

  Future<void> _fetchPage() async {
    final page = await client.fetchRandomPhotoDescendantsPage(
      target.id,
      start: _nextStart,
      size: pageSize,
      abort: _abort,
    );
    _total = page.totalCount;
    _nextStart += page.items.length;
    final before = _items.length;
    for (final item in page.items) {
      if (PhotoSequence.shows(item) && _ids.add(item.id)) _items.add(item);
    }
    _stalePages = _items.length == before ? _stalePages + 1 : 0;
    if (page.items.isEmpty || _nextStart >= _total || _ids.length >= _total || _stalePages >= staleLimit) {
      _exhausted = true;
    }
  }
}
