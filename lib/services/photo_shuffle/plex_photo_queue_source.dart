import 'dart:async';

import '../../media/media_item.dart';
import '../../models/plex/play_queue_response.dart';
import '../../utils/app_logger.dart';
import '../plex_client.dart';
import 'photo_shuffle_source.dart';

/// A shuffled Plex play queue of photos, with what nested albums and folders
/// hold (`recursive=1`). The server answers in windows of a few dozen items;
/// the next window is fetched as the slideshow nears the end of the ones it
/// has, and every item fetched stays, so going back needs no request.
class PlexPhotoQueueSource extends PhotoShuffleSource {
  PlexPhotoQueueSource({required this.client, required this.target, this.windowSize = 50, this.fetchAheadMargin = 8});

  final PlexClient client;
  final PhotoShuffleTarget target;

  /// Items asked for per window.
  final int windowSize;

  /// How close to the last item fetched the slideshow gets before the next
  /// window is asked for.
  final int fetchAheadMargin;

  final Map<int, MediaItem> _items = {};
  int _total = 0;
  int _queueId = 0;
  int _lastIndex = -1;
  Future<bool>? _fetching;

  /// The queue's position for the item after the last one fetched could not
  /// be worked out, so the queue ends there.
  bool _stalled = false;

  /// The play-queue uri for [target]. Plex takes a metadata item (album), a
  /// collection, a folder of the folder view, or a whole section.
  static Future<String> uriFor(PlexClient client, PhotoShuffleTarget target) => switch (target) {
    PhotoShuffleAlbum(:final album) => client.buildMetadataUri(album.id),
    PhotoShuffleCollection(:final collection) => client.buildFolderUri('/library/collections/${collection.id}'),
    PhotoShuffleFolder(:final folder) => client.buildFolderUri(folder.backendFolderKey ?? folder.id),
    PhotoShuffleLibrary(:final library) => client.buildFolderUri('/library/sections/${library.id}/all'),
  };

  String? get _libraryId => switch (target) {
    PhotoShuffleLibrary(:final library) => library.id,
    PhotoShuffleFolder(:final libraryId) => libraryId,
    _ => null,
  };

  @override
  Future<bool> start() async {
    final uri = await uriFor(client, target);
    var queue = await client.createPlayQueue(
      uri: uri,
      type: 'photo',
      shuffle: 1,
      recursive: 1,
      continuous: 0,
      librarySectionID: _libraryId,
    );
    _queueId = queue.playQueueID;
    if (queue.items?.isEmpty ?? true) {
      // Creation sometimes answers without the items; read the queue back.
      queue = await client.getPlayQueue(_queueId, window: windowSize, librarySectionID: _libraryId) ?? queue;
    }
    final items = queue.items ?? const <MediaItem>[];
    _total = queue.playQueueTotalCount ?? items.length;
    if (items.isEmpty || _total == 0) {
      appLogger.i('Photo shuffle: the play queue for ${target.logLabel} is empty');
      return false;
    }
    final selectedId = queue.playQueueSelectedItemID;
    final selectedAt = selectedId == null ? -1 : items.indexWhere((item) => _queueItemId(item) == selectedId);
    if (selectedAt < 0) {
      _place(items, anchorAt: 0, anchorIndex: 0);
    } else {
      _place(items, anchorAt: selectedAt, anchorIndex: queue.playQueueSelectedItemOffset ?? selectedAt);
    }
    appLogger.d('Photo shuffle: play queue $_queueId holds $_total items for ${target.logLabel}');
    return true;
  }

  /// Puts [items] in their queue positions: the one at [anchorAt] is at
  /// [anchorIndex], and the others follow it in order.
  void _place(List<MediaItem> items, {required int anchorAt, required int anchorIndex}) {
    for (var i = 0; i < items.length; i++) {
      final index = anchorIndex + i - anchorAt;
      if (index < 0 || index >= _total) continue;
      _items[index] = items[i];
      if (index > _lastIndex) _lastIndex = index;
    }
  }

  static int? _queueItemId(MediaItem? item) => item is PlexMediaItem ? item.playQueueItemId : null;

  @override
  int get length => _total;

  @override
  MediaItem? itemAt(int index) => _items[index];

  @override
  Future<MediaItem?> loadItemAt(int index) async {
    while (!_items.containsKey(index)) {
      if (index < 0 || index >= _total || _stalled) return null;
      if (!await _fetchAhead()) return _items[index];
    }
    return _items[index];
  }

  @override
  void shown(int index) {
    if (_stalled || _lastIndex >= _total - 1) return;
    if (_lastIndex - index <= fetchAheadMargin) unawaited(_fetchAhead());
  }

  /// Fetches the window after the last item fetched, once at a time, and
  /// reports whether it brought anything new.
  Future<bool> _fetchAhead() => _fetching ??= _fetchWindow().whenComplete(() => _fetching = null);

  Future<bool> _fetchWindow() async {
    final anchorIndex = _lastIndex;
    final anchorId = _queueItemId(_items[anchorIndex]);
    if (anchorId == null) {
      _stalled = true;
      return false;
    }
    // Centred on the last item fetched, so the window says where it is in the
    // queue; the items after it are the new ones.
    final PlayQueueResponse? window = await client.getPlayQueue(
      _queueId,
      center: '$anchorId',
      window: windowSize,
      librarySectionID: _libraryId,
    );
    final items = window?.items;
    if (window == null || items == null) {
      appLogger.w('Photo shuffle: could not fetch play queue $_queueId after position $anchorIndex');
      return false;
    }
    final anchorAt = items.indexWhere((item) => _queueItemId(item) == anchorId);
    if (anchorAt < 0) {
      appLogger.w('Photo shuffle: play queue $_queueId window has no item $anchorId; the slideshow ends there');
      _stalled = true;
      return false;
    }
    if (window.playQueueTotalCount case final total?) _total = total;
    final before = _lastIndex;
    _place(items, anchorAt: anchorAt, anchorIndex: anchorIndex);
    return _lastIndex > before;
  }
}
