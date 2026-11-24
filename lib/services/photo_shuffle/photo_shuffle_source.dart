import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_library.dart';
import '../../screens/photo_sequence_viewer.dart';
import '../../utils/app_logger.dart';

/// Where a photo shuffle starts: everything an album, folder, collection or
/// photo library holds, nested albums and folders included.
sealed class PhotoShuffleTarget {
  const PhotoShuffleTarget();

  String? get serverId;
  MediaBackend get backend;

  /// The id the server knows the container by.
  String get id;

  /// Names the container to the user.
  String get title;

  /// The library the container is in, when known.
  String? get libraryId;

  /// Names the container in logs.
  String get logLabel => '${runtimeType.toString().replaceFirst('PhotoShuffle', '').toLowerCase()} $id';
}

final class PhotoShuffleAlbum extends PhotoShuffleTarget {
  const PhotoShuffleAlbum(this.album);

  final MediaItem album;

  @override
  String? get serverId => album.serverId;
  @override
  MediaBackend get backend => album.backend;
  @override
  String get id => album.id;
  @override
  String get title => album.displayTitle;
  @override
  String? get libraryId => album.libraryId;
}

/// A folder of a library's folder view.
final class PhotoShuffleFolder extends PhotoShuffleTarget {
  const PhotoShuffleFolder(this.folder, {this.libraryId, this.libraryTitle});

  final MediaItem folder;
  @override
  final String? libraryId;
  final String? libraryTitle;

  @override
  String? get serverId => folder.serverId;
  @override
  MediaBackend get backend => folder.backend;
  @override
  String get id => folder.id;
  @override
  String get title => folder.displayTitle;
}

final class PhotoShuffleCollection extends PhotoShuffleTarget {
  const PhotoShuffleCollection(this.collection);

  final MediaItem collection;

  @override
  String? get serverId => collection.serverId;
  @override
  MediaBackend get backend => collection.backend;
  @override
  String get id => collection.id;
  @override
  String get title => collection.displayTitle;
  @override
  String? get libraryId => collection.libraryId;
}

final class PhotoShuffleLibrary extends PhotoShuffleTarget {
  const PhotoShuffleLibrary(this.library);

  final MediaLibrary library;

  @override
  String? get serverId => library.serverId;
  @override
  MediaBackend get backend => library.backend;
  @override
  String get id => library.id;
  @override
  String get title => library.title;
  @override
  String? get libraryId => library.id;
}

/// The photos and clips of a [PhotoShuffleTarget] in a random order, loaded as
/// the slideshow goes. Positions already shown stay where they are, so going
/// back walks the same order.
abstract class PhotoShuffleSource {
  /// Loads the first items. False when there is nothing to show.
  Future<bool> start();

  /// How many positions the viewer may step through: the items known so far,
  /// plus one while more may still come.
  int get length;

  /// The item at [index], when it has been loaded.
  MediaItem? itemAt(int index);

  /// The item at [index], loading it if need be. Null past the end.
  Future<MediaItem?> loadItemAt(int index);

  /// The viewer shows [index], so the items after it may be fetched ahead.
  void shown(int index) {}

  void dispose() {}

  /// Positions [start] passes over before giving up on finding a photo.
  static const int _searchLimit = 200;

  /// A sequence starting at the first photo or clip, or null when there is
  /// none.
  Future<PhotoSequence?> sequence() async {
    for (var i = 0; i < length && i < _searchLimit; i++) {
      final item = itemAt(i) ?? await loadItemAt(i);
      if (item == null) break;
      if (PhotoSequence.shows(item)) {
        return PhotoSequence(
          index: i,
          photo: item,
          length: () => length,
          itemAt: itemAt,
          loadItemAt: loadItemAt,
          onShown: shown,
        );
      }
    }
    appLogger.d('Photo shuffle: nothing to show among the first items');
    return null;
  }
}

/// Server of [target], as the client lookup takes it.
ServerId? photoShuffleServerId(PhotoShuffleTarget target) => serverIdOrNull(target.serverId);
