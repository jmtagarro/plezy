import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/dpad_navigator.dart';
import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../services/device_performance.dart';
import '../services/photo_shuffle/photo_shuffle_album.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/video_player_navigation.dart';
import 'video_player/player_sequence_link.dart';
import 'video_player/wakelock_controller.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/app_icon.dart';
import 'photo_viewer_screen.dart';

/// A photo of a [PhotoSequence], with its position in the list it comes from.
typedef PhotoSequenceEntry = ({int index, MediaItem photo});

/// The list a photo was opened from, in the order its grid shows it. The
/// viewer moves through its photos and clips, and skips the albums in between.
class PhotoSequence {
  PhotoSequence({
    required this.index,
    required this.photo,
    required this._length,
    required this._itemAt,
    required this._loadItemAt,
    this.onShown,
    this.loops = false,
  });

  /// [photo] on its own, with nothing before or after it.
  PhotoSequence.single(MediaItem photo)
    : this(index: 0, photo: photo, length: () => 1, itemAt: (_) => photo, loadItemAt: (_) async => photo);

  /// Position of the photo shown, read back by the list once the viewer
  /// closes.
  int index;

  /// The photo shown.
  MediaItem photo;

  /// Whether the viewer shows [item]: photos, and clips, which play from
  /// their page.
  static bool shows(MediaItem item) => item.kind == MediaKind.photo || item.kind == MediaKind.clip;

  final int Function() _length;
  final MediaItem? Function(int index) _itemAt;
  final Future<MediaItem?> Function(int index) _loadItemAt;

  /// Told the position of every item the viewer shows, so a list that loads
  /// in windows can fetch the next one ahead of time.
  final void Function(int index)? onShown;

  /// Goes on from the last item to the first, and back from the first to the
  /// last.
  final bool loops;

  /// Positions in the list, albums included.
  int get length => _length();

  /// The nearest photo or clip from [from] in the direction of [step] (-1 or 1),
  /// loading the list as it goes, and passing over the items [skip] names.
  /// Null at the end of a list that does not loop, when nothing else in a
  /// looping one is shown, or when part of the list cannot be loaded.
  Future<PhotoSequenceEntry?> neighbour(int from, int step, {bool Function(MediaItem item)? skip}) async {
    if (loops) return _neighbourAround(from, step, skip: skip);
    for (var i = from + step; i >= 0 && i < _length(); i += step) {
      final item = _itemAt(i) ?? await _loadItemAt(i);
      if (item == null) {
        appLogger.d('Photo viewer: no item at $i, so the sequence ends there');
        return null;
      }
      if (shows(item) && skip?.call(item) != true) return (index: i, photo: item);
    }
    return null;
  }

  /// [neighbour] in a list that loops: one lap at most, so a list with
  /// nothing else to show ends where it started.
  Future<PhotoSequenceEntry?> _neighbourAround(int from, int step, {bool Function(MediaItem item)? skip}) async {
    for (var taken = 1; taken < _length(); taken++) {
      final i = (from + step * taken) % _length();
      final item = _itemAt(i) ?? await _loadItemAt(i);
      if (item == null) {
        appLogger.d('Photo viewer: no item at $i of a looping sequence');
        return null;
      }
      if (shows(item) && skip?.call(item) != true) return (index: i, photo: item);
    }
    return null;
  }
}

/// Opens the viewer on the photo [sequence] stands on. [autoplayInitialClip]
/// plays it at once when it is a clip and clips play automatically, as for a
/// tap on its card. [slideshow] runs a slideshow through the sequence, and
/// [shuffle] tells it the sequence is a shuffle.
Future<void> openPhotoSequence(
  BuildContext context,
  PhotoSequence sequence, {
  bool autoplayInitialClip = false,
  bool slideshow = false,
  PhotoShuffleSession? shuffle,
}) {
  return Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => PhotoSequenceViewer(
        sequence: sequence,
        autoplayInitialClip: autoplayInitialClip,
        slideshow: slideshow,
        shuffle: shuffle,
      ),
    ),
  );
}

/// The header a slideshow draws over its photos. It stays put while the
/// photos change under it, so focus in it lasts from one photo to the next.
class PhotoSequenceHeader {
  PhotoSequenceHeader({required this.focus, required this.hasFocus});

  /// Up from the photo: shows the header and focuses it.
  final VoidCallback focus;

  /// Whether focus is in the header, where a photo coming in leaves it.
  final bool Function() hasFocus;

  Object? _photoOwner;
  VoidCallback? _focusPhoto;

  /// The viewer of the photo coming in, [owner], is where Down from the
  /// header goes.
  void attachPhoto(Object owner, VoidCallback focusPhoto) {
    _photoOwner = owner;
    _focusPhoto = focusPhoto;
  }

  void detachPhoto(Object owner) {
    if (!identical(owner, _photoOwner)) return;
    _photoOwner = null;
    _focusPhoto = null;
  }

  /// Down from the header.
  void focusPhoto() => _focusPhoto?.call();
}

/// What the viewer of one photo needs from the sequence around it.
class PhotoNavigation extends InheritedWidget {
  const PhotoNavigation({
    super.key,
    required this.onPrevious,
    required this.onNext,
    required this.keepsImage,
    this.onPlay,
    this.onSelect,
    this.onZoomIn,
    this.header,
    required super.child,
  });

  /// The header the sequence draws in place of the viewer's own, when it
  /// draws one.
  final PhotoSequenceHeader? header;

  /// Enter, Select or a tap on the photo, when the sequence does something
  /// with them: a slideshow pauses or resumes.
  final VoidCallback? onSelect;

  /// The photo was zoomed in, by pinch, scroll or double tap: a slideshow
  /// pauses so it does not move on from what is being looked at.
  final VoidCallback? onZoomIn;

  /// Plays a clip of the sequence, and completes once the player closes.
  final Future<void> Function(MediaItem clip)? onPlay;

  /// Null at the start of the sequence.
  final VoidCallback? onPrevious;

  /// Null at the end of the sequence.
  final VoidCallback? onNext;

  /// Whether the screen-sized image at a URL stays in the memory cache, as the
  /// sequence shows it next to the current photo.
  final bool Function(String url) keepsImage;

  static PhotoNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhotoNavigation>();

  @override
  bool updateShouldNotify(PhotoNavigation oldWidget) =>
      onPrevious != oldWidget.onPrevious ||
      onNext != oldWidget.onNext ||
      keepsImage != oldWidget.keepsImage ||
      onPlay != oldWidget.onPlay ||
      onSelect != oldWidget.onSelect ||
      onZoomIn != oldWidget.onZoomIn ||
      header != oldWidget.header;
}

/// Plays a clip of a sequence, and completes once the player closes. Next and
/// previous in the player go through [link].
typedef PlayClip = Future<void> Function(BuildContext context, MediaItem clip, PlayerSequenceLink link);

/// Shows the photos of a [PhotoSequence] one at a time, with one
/// [PhotoViewerScreen] per photo, so nothing the viewer keeps about a photo,
/// such as its zoom, carries over to the next one.
class PhotoSequenceViewer extends StatefulWidget {
  final PhotoSequence sequence;

  /// Replaces the player a clip opens in. The player moves the sequence
  /// through [PlayerSequenceLink].
  @visibleForTesting
  final PlayClip? playClip;

  /// Plays the clip the viewer opens on at once, when clips play
  /// automatically.
  final bool autoplayInitialClip;

  /// Moves on through the sequence by itself, keeping the screen awake: each
  /// photo for the slideshow duration, each clip as it plays to its end.
  final bool slideshow;

  /// Set when the slideshow is a shuffle: its header then names what it
  /// shuffles and can switch to the album of the item shown and back.
  final PhotoShuffleSession? shuffle;

  const PhotoSequenceViewer({
    super.key,
    required this.sequence,
    this.playClip,
    this.autoplayInitialClip = false,
    this.slideshow = false,
    this.shuffle,
  });

  /// A slideshow hides its header once it has gone on this long without any
  /// input. A paused one always shows it.
  static const headerHideDelay = PlayerSequenceLink.chromeHideDelay;

  static const headerFade = PlayerSequenceLink.chromeFade;

  /// The photos of a slideshow fade from one to the next for this long.
  static const slideshowCrossFade = Duration(milliseconds: 400);

  /// How long a slideshow leaves an item that failed to load on screen
  /// before it moves past it.
  static const failedItemSkipDelay = Duration(seconds: 2);

  /// Failures in a row after which a slideshow pauses rather than going on.
  static const slideshowFailureLimit = 5;

  /// How long the viewer stays on a clip it moved to before playing it, so
  /// clips passed on the way to another item do not start.
  static const clipAutoplayDelay = Duration(milliseconds: 500);

  /// Replaces the player for viewers opened from a grid, which pass no
  /// [playClip].
  @visibleForTesting
  static PlayClip? debugPlayClipOverride;

  /// Replaces loading an item's picture in a slideshow, and reports whether
  /// it loaded.
  @visibleForTesting
  static Future<bool> Function(MediaItem item)? debugLoadsOverride;

  @override
  State<PhotoSequenceViewer> createState() => _PhotoSequenceViewerState();
}

class _PhotoSequenceViewerState extends State<PhotoSequenceViewer> {
  /// The sequence the viewer moves through: the one it opened on, or the
  /// album a shuffle switched to.
  late PhotoSequence _sequence = widget.sequence;

  /// The album a shuffle switched to, while it shows one. The shuffle's own
  /// sequence stays as it was, on the item it was left at.
  PhotoAlbumSequence? _albumMode;

  /// The album of the item a shuffle shows, once known.
  PhotoAlbumRef? _album;

  /// Albums that could not be opened, by id. They are not offered again.
  final Set<String> _unopenedAlbums = {};

  /// An album is being opened; the slideshow holds on the item shown.
  bool _switching = false;

  /// Whether the slideshow's header shows while the slideshow plays.
  bool _headerShown = true;
  Timer? _headerTimer;
  late final PhotoSequenceHeader _header = PhotoSequenceHeader(focus: _focusHeader, hasFocus: () => _headerHasFocus);
  final FocusNode _headerBackNode = FocusNode(debugLabel: 'photo_slideshow_back');
  final FocusNode _albumNode = FocusNode(debugLabel: 'photo_slideshow_album');
  final FocusNode _shuffleNode = FocusNode(debugLabel: 'photo_slideshow_shuffle');

  /// The photos on either side, kept as futures so that a move made while one
  /// is still loading waits for it.
  Future<PhotoSequenceEntry?>? _previous;
  Future<PhotoSequenceEntry?>? _next;
  PhotoSequenceEntry? _previousEntry;
  PhotoSequenceEntry? _nextEntry;

  /// Bumped on every move, so neighbours found for an earlier photo are dropped.
  int _generation = 0;
  bool _moving = false;

  /// Direction of the last move. Devices on the reduced tier load ahead only
  /// that way.
  int _direction = 1;

  int? _imageEdge;

  /// Screen-sized images of the current photo and the ones loaded ahead, by
  /// URL. They stay in the memory cache while in this window, and leave it as
  /// they drop out of it or when the viewer closes.
  final Map<String, ImageProvider> _window = {};

  /// Plays the clip moved to once the viewer has stayed on it for
  /// [PhotoSequenceViewer.clipAutoplayDelay].
  Timer? _clipAutoplay;

  /// The clip whose autoplay waits for the arrow key still held down.
  String? _clipAutoplayAfterKeyUp;

  /// Tells the player of the clip playing which ways the sequence goes on.
  PlayerSequenceLink? _playerLink;

  /// A slideshow that has not reached its end, paused or not.
  bool _showRunning = false;
  bool _paused = false;

  /// Moves the slideshow on once the current photo has had its time.
  Timer? _slideTimer;

  /// Moves the slideshow past an item that failed to load.
  Timer? _skipTimer;

  /// The next item of the slideshow, once its picture is loaded, or null at
  /// the end. The slideshow only moves to an item that is ready.
  Future<PhotoSequenceEntry?>? _ready;

  /// Items of the slideshow that could not be loaded, by global key. The
  /// slideshow passes over them both ways.
  final Set<String> _failed = {};

  /// Failures in a row since an item last loaded.
  int _failureRun = 0;

  /// Items whose picture the slideshow has seen load, by global key.
  final Set<String> _loaded = {};

  @override
  void initState() {
    super.initState();
    _resolveNeighbours();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    if (widget.slideshow) {
      _showRunning = true;
      unawaited(WakelockController.shared.setEnabled(true, owner: this));
      _armHeaderHide();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _arrive();
      });
    } else {
      _sequence.onShown?.call(_sequence.index);
    }
    if (widget.autoplayInitialClip && _clipsAutoplay && _sequence.photo.kind == MediaKind.clip) {
      final clip = _sequence.photo;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sequence.photo.globalKey == clip.globalKey) unawaited(_play(clip));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_imageEdge == null) {
      _imageEdge = PhotoViewerScreen.screenImageEdge(context);
      _updateWindow();
    }
  }

  @override
  void dispose() {
    _clipAutoplay?.cancel();
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    _headerTimer?.cancel();
    _albumMode?.dispose();
    _headerBackNode.dispose();
    _albumNode.dispose();
    _shuffleNode.dispose();
    if (widget.slideshow) unawaited(WakelockController.shared.setEnabled(false, owner: this));
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    for (final image in _window.values) {
      unawaited(image.evict());
    }
    super.dispose();
  }

  /// Finds the photos on either side of the current one, taking [previous] and
  /// [next] as they are when the move already knows them.
  void _resolveNeighbours({PhotoSequenceEntry? previous, PhotoSequenceEntry? next}) {
    final generation = ++_generation;
    final from = _sequence.index;
    _previousEntry = previous;
    _nextEntry = next;
    _previous = previous != null ? Future.value(previous) : _sequence.neighbour(from, -1, skip: _isFailed);
    _next = next != null ? Future.value(next) : _sequence.neighbour(from, 1, skip: _isFailed);
    if (previous == null) {
      unawaited(
        _previous!.then((entry) {
          if (!mounted || generation != _generation || entry == null) return;
          setState(() => _previousEntry = entry);
          _syncPlayerLink();
          _updateWindow();
        }),
      );
    }
    if (next == null) {
      unawaited(
        _next!.then((entry) {
          if (!mounted || generation != _generation || entry == null) return;
          setState(() => _nextEntry = entry);
          _syncPlayerLink();
          _updateWindow();
        }),
      );
    }
    _updateWindow();
  }

  /// Moves by [step], and reports whether it moved.
  Future<bool> _go(int step) async {
    final target = step < 0 ? _previous : _next;
    if (_moving || target == null) return false;
    _moving = true;
    final generation = _generation;
    try {
      final entry = await target;
      if (!mounted || entry == null || generation != _generation) return false;
      _moveTo(entry, step);
      return true;
    } finally {
      _moving = false;
    }
  }

  void _moveTo(PhotoSequenceEntry entry, int step) {
    final left = (index: _sequence.index, photo: _sequence.photo);
    setState(() {
      _sequence
        ..index = entry.index
        ..photo = entry.photo;
      _direction = step;
    });
    // Before the frame that replaces the viewer, so the one leaving keeps the
    // image of the photo it showed, which is now next to the current one.
    final known = _isFailed(left.photo) ? null : left;
    _resolveNeighbours(previous: step > 0 ? known : null, next: step < 0 ? known : null);
    if (widget.slideshow) {
      _arrive();
    } else {
      _sequence.onShown?.call(_sequence.index);
      _scheduleClipAutoplay();
    }
  }

  bool _isFailed(MediaItem item) => _failed.contains(item.globalKey);

  static int get _slideSeconds =>
      SettingsService.instanceOrNull?.read(SettingsService.photoSlideshowSeconds) ??
      SettingsService.photoSlideshowSeconds.defaultValue;

  /// The slideshow reached the item shown: a clip plays at once, a photo stays
  /// up for the slideshow duration. Either way the next item starts loading.
  void _arrive() {
    _sequence.onShown?.call(_sequence.index);
    _refreshAlbum();
    if (!_showRunning) return;
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    _lookAhead();
    final item = _sequence.photo;
    if (_isFailed(item)) return _scheduleSkip();
    // Reached by hand or first shown, so not loaded ahead: check it now.
    if (!_loaded.contains(item.globalKey)) unawaited(_checkShown(item, _generation));
    if (item.kind == MediaKind.clip) {
      // A paused slideshow leaves a clip moved to by hand on its page.
      if (!_paused) unawaited(_play(item));
    } else {
      _startSlideTimer();
    }
  }

  /// Starts loading the item after the current one.
  void _lookAhead() {
    final ready = _readyNext(_generation);
    // Awaited only when the slideshow moves on; a failure nobody waits for
    // is not an error.
    ready.ignore();
    _ready = ready;
  }

  void _startSlideTimer() {
    _slideTimer?.cancel();
    if (!_showRunning || _paused) return;
    _slideTimer = Timer(Duration(seconds: _slideSeconds), () => unawaited(_advance()));
  }

  /// Moves to the next item once it is ready, or ends the slideshow when
  /// there is none.
  Future<void> _advance() async {
    final generation = _generation;
    final ready = _ready;
    if (!_showRunning || _paused || _switching || ready == null) return;
    final PhotoSequenceEntry? entry;
    try {
      entry = await ready;
    } on _TooManyFailures {
      if (mounted && generation == _generation) _pauseForFailures();
      return;
    }
    if (!mounted || generation != _generation || !_showRunning || _paused || _switching) return;
    // A move by hand under way arrives on its own; should it go nowhere, the
    // slideshow tries again after another duration.
    if (_moving) return _startSlideTimer();
    if (entry == null) {
      // An album only ends when the user leaves it; with nothing else to
      // show, or a page that would not load, it stays and tries again.
      if (_sequence.loops) {
        _lookAhead();
        return _startSlideTimer();
      }
      return _endShow();
    }
    _moveTo(entry, 1);
  }

  /// The item after the current one whose picture has loaded. Items that fail
  /// to load on the way are passed over, until too many fail in a row.
  Future<PhotoSequenceEntry?> _readyNext(int generation) async {
    var from = _sequence.index;
    while (true) {
      final entry = await _sequence.neighbour(from, 1, skip: _isFailed);
      if (entry == null || !mounted || generation != _generation) return entry;
      if (await _loads(entry.photo)) {
        _failureRun = 0;
        _loaded.add(entry.photo.globalKey);
        return entry;
      }
      if (!mounted || generation != _generation) return null;
      _recordFailure(entry.photo);
      if (_failureRun >= PhotoSequenceViewer.slideshowFailureLimit) throw const _TooManyFailures();
      from = entry.index;
    }
  }

  /// Loads and decodes the screen-sized picture of [item], and reports
  /// whether it loaded. A clip whose picture fails can still play.
  Future<bool> _loads(MediaItem item) async {
    final override = PhotoSequenceViewer.debugLoadsOverride;
    if (override != null) return await override(item) || item.kind == MediaKind.clip;
    final edge = _imageEdge;
    if (edge == null) return true;
    final image = _screenImageOf(item, edge);
    if (image == null) return item.kind == MediaKind.clip;
    var loaded = true;
    await precacheImage(image.image, context, onError: (error, _) => loaded = false);
    return loaded || item.kind == MediaKind.clip;
  }

  void _recordFailure(MediaItem item) {
    _failed.add(item.globalKey);
    _failureRun++;
    appLogger.w('Photo slideshow: ${item.kind.name} ${item.globalKey} could not be loaded, so it is skipped');
  }

  /// The item on screen failed: it stays up for a moment, then the slideshow
  /// moves past it the way it was going.
  void _scheduleSkip() {
    _skipTimer?.cancel();
    if (!_showRunning || _paused) return;
    final generation = _generation;
    _skipTimer = Timer(PhotoSequenceViewer.failedItemSkipDelay, () async {
      if (!mounted || generation != _generation || _paused) return;
      if (_direction < 0 && await _go(-1)) return;
      await _advance();
    });
  }

  /// Checks that the item shown loads; one that does not is skipped like
  /// any other failure.
  Future<void> _checkShown(MediaItem item, int generation) async {
    final loads = await _loads(item);
    if (!mounted || generation != _generation || !_showRunning) return;
    if (loads) {
      _loaded.add(item.globalKey);
      _failureRun = 0;
      return;
    }
    _recordFailure(item);
    _slideTimer?.cancel();
    if (_failureRun >= PhotoSequenceViewer.slideshowFailureLimit) return _pauseForFailures();
    _scheduleSkip();
  }

  void _pauseForFailures() {
    if (!mounted) return;
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    setState(() => _paused = true);
    final title = _sequence.photo.title ?? _sequence.photo.parentTitle ?? '';
    showErrorSnackBar(context, t.errors.unableToLoad(context: title));
  }

  /// Enter, Select or a tap: pauses the slideshow, or resumes it with a full
  /// duration for the photo shown.
  void _togglePause() {
    if (!_showRunning) return;
    if (_paused) {
      setState(() => _paused = false);
      _failureRun = 0;
      // A run of failures may have left the next item unfound; look again.
      _lookAhead();
      if (_isFailed(_sequence.photo)) {
        _scheduleSkip();
      } else if (_sequence.photo.kind == MediaKind.clip) {
        unawaited(_play(_sequence.photo));
      } else {
        _startSlideTimer();
      }
      _armHeaderHide();
    } else {
      _slideTimer?.cancel();
      _skipTimer?.cancel();
      setState(() => _paused = true);
    }
  }

  /// Zooming in pauses the slideshow; zooming back out leaves it paused.
  void _pauseForZoom() {
    if (!_showRunning || _paused) return;
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    setState(() => _paused = true);
  }

  void _endShow() {
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    setState(() => _showRunning = false);
    unawaited(WakelockController.shared.setEnabled(false, owner: this));
  }

  /// Loads the neighbours' screen-sized images ahead, and drops the ones that
  /// are no longer next to the current photo.
  void _updateWindow() {
    final edge = _imageEdge;
    if (edge == null) return;
    final ahead = DevicePerformance.isReduced
        ? [_direction < 0 ? _previousEntry : _nextEntry]
        : [_previousEntry, _nextEntry];
    final current = _screenImageOf(_sequence.photo, edge);
    final wanted = <String, ImageProvider>{if (current != null) current.url: current.image};
    for (final entry in ahead) {
      final image = entry == null ? null : _screenImageOf(entry.photo, edge);
      if (image != null) wanted[image.url] = image.image;
    }
    for (final MapEntry(key: url, value: image) in _window.entries) {
      if (!wanted.containsKey(url)) unawaited(image.evict());
    }
    for (final MapEntry(key: url, value: image) in wanted.entries) {
      // The current photo loads in its own viewer.
      if (_window.containsKey(url) || url == current?.url) continue;
      unawaited(
        precacheImage(
          image,
          context,
          onError: (error, _) => appLogger.d('Photo viewer: could not load the next photo ahead', error: error),
        ),
      );
    }
    _window
      ..clear()
      ..addAll(wanted);
  }

  ({String url, ImageProvider image})? _screenImageOf(MediaItem photo, int edge) {
    final client = context.tryGetMediaClientForServer(serverIdOrNull(photo.serverId));
    return client == null ? null : PhotoViewerScreen.screenImage(client, photo.photoImagePath, edge);
  }

  bool _keepsImage(String url) => _window.containsKey(url);

  static bool get _clipsAutoplay =>
      SettingsService.instanceOrNull?.read(SettingsService.photoClipAutoplay) ??
      SettingsService.photoClipAutoplay.defaultValue;

  /// Arms the autoplay of the clip just moved to. Every move rearms it, so a
  /// clip passed within the delay never plays. Coming back from the player
  /// does not rearm it, so the clip does not play again until the viewer
  /// moves back to it.
  void _scheduleClipAutoplay() {
    _clipAutoplay?.cancel();
    _clipAutoplay = null;
    _clipAutoplayAfterKeyUp = null;
    final clip = _sequence.photo;
    if (clip.kind != MediaKind.clip || !_clipsAutoplay) return;
    _clipAutoplay = Timer(PhotoSequenceViewer.clipAutoplayDelay, () => _autoplayClip(clip));
  }

  void _autoplayClip(MediaItem clip) {
    _clipAutoplay = null;
    if (!mounted || _sequence.photo.globalKey != clip.globalKey) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    // An arrow key held down is on its way somewhere else.
    if (HardwareKeyboard.instance.logicalKeysPressed.any((key) => key.isDpadDirection)) {
      _clipAutoplayAfterKeyUp = clip.globalKey;
      return;
    }
    unawaited(_play(clip));
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent && widget.slideshow && (ModalRoute.of(context)?.isCurrent ?? false)) _noteInput();
    if (event is KeyUpEvent &&
        _clipAutoplayAfterKeyUp == _sequence.photo.globalKey &&
        !HardwareKeyboard.instance.logicalKeysPressed.any((key) => key.isDpadDirection)) {
      _clipAutoplayAfterKeyUp = null;
      final clip = _sequence.photo;
      _clipAutoplay = Timer(PhotoSequenceViewer.clipAutoplayDelay, () => _autoplayClip(clip));
    }
    return false;
  }

  void _syncPlayerLink() {
    _playerLink
      ?..hasPrevious = _previousEntry != null
      ..hasNext = _nextEntry != null;
  }

  /// Plays [clip] in the player, and stays on its page for when the player
  /// closes or the clip ends. Next or previous in the player close it and
  /// move the sequence; a clip moved to that way plays at once.
  Future<void> _play(MediaItem clip) async {
    _clipAutoplay?.cancel();
    _clipAutoplay = null;
    _clipAutoplayAfterKeyUp = null;
    // Left for the garbage collector rather than disposed: the player may
    // still be letting go of it after its route has closed.
    final link = PlayerSequenceLink(
      hasPrevious: _previousEntry != null,
      hasNext: _nextEntry != null,
      leavesOnFailure: widget.slideshow,
    );
    _playerLink = link;
    try {
      final playClip = widget.playClip ?? PhotoSequenceViewer.debugPlayClipOverride;
      if (playClip != null) {
        await playClip(context, clip, link);
      } else {
        await navigateToVideoPlayer(context, metadata: clip, sequenceLink: link);
      }
    } catch (error, stackTrace) {
      appLogger.w('Photo viewer: the clip did not play', error: error, stackTrace: stackTrace);
    } finally {
      if (identical(_playerLink, link)) _playerLink = null;
    }
    if (!mounted || _sequence.photo.globalKey != clip.globalKey) return;
    final step = link.requestedStep;
    if (step != null) {
      // A slideshow takes it from there on its own.
      if (!await _go(step) || !mounted || widget.slideshow) return;
      final next = _sequence.photo;
      if (next.kind == MediaKind.clip) unawaited(_play(next));
      return;
    }
    if (!_showRunning) return;
    if (link.failed) {
      _recordFailure(clip);
      if (_failureRun >= PhotoSequenceViewer.slideshowFailureLimit) return _pauseForFailures();
      return unawaited(_advance());
    }
    _failureRun = 0;
    // A clip that played to its end hands straight on; one closed with Back
    // gets a photo's time on its page first.
    if (link.ended && !_paused) return unawaited(_advance());
    _startSlideTimer();
  }

  /// Offers the album of the item a shuffle shows, as soon as it is known.
  void _refreshAlbum() {
    final albums = widget.shuffle?.albums;
    if (albums == null || _albumMode != null) return;
    final photo = _sequence.photo;
    final known = albums.knownAlbumOf(photo);
    _setAlbum(known);
    if (known != null || photo.parentId == null) return;
    unawaited(
      albums.albumOf(photo).then((album) {
        if (mounted && _albumMode == null && _sequence.photo.globalKey == photo.globalKey) _setAlbum(album);
      }),
    );
  }

  void _setAlbum(PhotoAlbumRef? album) {
    final offered = album == null || _unopenedAlbums.contains(album.id) ? null : album;
    if (offered == _album) return;
    // The album button goes; focus on it moves along the header first.
    if (offered == null && _albumNode.hasFocus) _shuffleNode.requestFocus();
    setState(() => _album = offered);
  }

  void _toggleShuffle() => _albumMode == null ? unawaited(_openAlbum()) : _backToShuffle();

  /// Switches the shuffle to the album of the item shown, at that item. The
  /// slideshow holds on it until the album's page with it has loaded; a move
  /// by hand meanwhile drops the switch.
  Future<void> _openAlbum() async {
    final album = _album;
    final albums = widget.shuffle?.albums;
    if (album == null || albums == null || _albumMode != null || _switching) return;
    final photo = _sequence.photo;
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    setState(() => _switching = true);
    final opened = await albums.open(album, photo);
    if (!mounted) return opened?.dispose();
    setState(() => _switching = false);
    if (opened != null && _albumMode == null && _sequence.photo.globalKey == photo.globalKey) {
      // The album button gives way to the album; focus on it moves to the
      // way back.
      if (_albumNode.hasFocus) _shuffleNode.requestFocus();
      _albumMode = opened;
      return _enter(opened.sequence);
    }
    if (opened == null) {
      _unopenedAlbums.add(album.id);
      _setAlbum(null);
    }
    opened?.dispose();
    _restartShown();
  }

  /// Back to the shuffle, at the item it was left at.
  void _backToShuffle() {
    final album = _albumMode;
    if (album == null || _switching) return;
    _albumMode = null;
    album.dispose();
    _enter(widget.sequence);
  }

  /// Makes [sequence] the one the slideshow goes through, on the item it
  /// stands on, which stays on screen as it is. A slideshow paused or ended
  /// before the switch goes on.
  void _enter(PhotoSequence sequence) {
    _slideTimer?.cancel();
    _skipTimer?.cancel();
    if (!_showRunning) unawaited(WakelockController.shared.setEnabled(true, owner: this));
    setState(() {
      _sequence = sequence;
      _paused = false;
      _showRunning = true;
      _direction = 1;
    });
    _failureRun = 0;
    _resolveNeighbours();
    _sequence.onShown?.call(_sequence.index);
    _refreshAlbum();
    _restartShown();
    _armHeaderHide();
  }

  /// Gives the item shown a full duration, or moves past it when it failed.
  /// A clip is not played again.
  void _restartShown() {
    if (!_showRunning || _paused) return;
    _lookAhead();
    if (_isFailed(_sequence.photo)) return _scheduleSkip();
    _startSlideTimer();
  }

  bool get _headerHasFocus => _headerBackNode.hasFocus || _albumNode.hasFocus || _shuffleNode.hasFocus;

  bool get _headerVisible => !_showRunning || _paused || _switching || _headerShown || _headerHasFocus;

  /// Input of any kind shows the header, which hides again once the
  /// slideshow has gone on without any for a while.
  void _noteInput() {
    if (!widget.slideshow || !mounted) return;
    if (!_headerShown) setState(() => _headerShown = true);
    _armHeaderHide();
  }

  void _armHeaderHide() {
    _headerTimer?.cancel();
    _headerTimer = Timer(PhotoSequenceViewer.headerHideDelay, () {
      if (mounted && _headerShown) setState(() => _headerShown = false);
    });
  }

  /// The controls of the header, from left to right.
  List<FocusNode> get _headerNodes => [
    _headerBackNode,
    if (_albumMode == null && _album != null) _albumNode,
    if (widget.shuffle != null) _shuffleNode,
  ];

  /// Up from the photo lands on the album, or on the way back to the shuffle,
  /// where the header has them.
  void _focusHeader() {
    _noteInput();
    final nodes = _headerNodes;
    (nodes.length > 1 ? nodes[1] : nodes.first).requestFocus();
  }

  KeyEventResult _handleHeaderKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (!key.isDpadDirection) return handleBackKeyNavigation(context, event);
    if (event.isActionable) {
      if (key == LogicalKeyboardKey.arrowDown) _header.focusPhoto();
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        final nodes = _headerNodes;
        final at = nodes.indexWhere((node) => node.hasFocus);
        final to = at + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        if (at >= 0 && to >= 0 && to < nodes.length) nodes[to].requestFocus();
      }
    }
    return KeyEventResult.handled;
  }

  String? get _modeLabel {
    final shuffle = widget.shuffle;
    if (shuffle == null) return null;
    final album = _albumMode;
    if (album == null) return t.libraries.slideshowShuffleMode(scope: shuffle.scope);
    return t.libraries.slideshowAlbumMode(name: album.album.title, index: _sequence.index + 1, total: album.total);
  }

  /// Back, the title and date of the item shown, what the slideshow goes
  /// through, and for a shuffle the switch to the album and back.
  Widget _buildHeader(BuildContext context) {
    final visible = _headerVisible;
    final photo = _sequence.photo;
    final textTheme = Theme.of(context).textTheme;
    final date = PhotoViewerScreen.dateLabelOf(photo);
    final mode = _modeLabel;
    final album = _album;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: PhotoSequenceViewer.headerFade,
        // Over the photos' own scaffolds, so it brings its own material.
        child: Material(
          type: MaterialType.transparency,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _handleHeaderKey,
            onFocusChange: (_) => _noteInput(),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 24),
                  child: Row(
                    children: [
                      AppBarBackButton(focusNode: _headerBackNode),
                      Expanded(
                        // Pinches that start on the title still reach the photo.
                        child: IgnorePointer(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                PhotoViewerScreen.titleOf(photo),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleMedium?.copyWith(color: Colors.white),
                              ),
                              for (final line in [?date, ?mode])
                                Text(
                                  line,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(color: Colors.white70),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_albumMode == null && album != null) ...[const SizedBox(width: 8), _buildAlbumButton(album)],
                      if (widget.shuffle != null) ...[const SizedBox(width: 8), _buildShuffleToggle()],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumButton(PhotoAlbumRef album) {
    void open() => unawaited(_openAlbum());
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: FocusableButton(
        focusNode: _albumNode,
        onPressed: open,
        autoScroll: false,
        child: Tooltip(
          message: t.tooltips.playPhotoAlbum,
          child: TextButton.icon(
            onPressed: open,
            style: TextButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
            icon: _switching
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const AppIcon(Symbols.photo_album_rounded),
            label: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  /// On while the shuffle plays; off plays the album of the item shown, in
  /// order, and on again goes back to the shuffle.
  Widget _buildShuffleToggle() {
    final shuffling = _albumMode == null;
    return FocusableButton(
      focusNode: _shuffleNode,
      // Stays focusable when there is no album to switch to, so focus does
      // not drop out of the header as the items change.
      onPressed: _toggleShuffle,
      autoScroll: false,
      child: IconButton(
        onPressed: shuffling && _album == null ? null : _toggleShuffle,
        isSelected: shuffling,
        tooltip: shuffling ? t.tooltips.playPhotoAlbum : t.tooltips.backToShuffle,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black38,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white54,
        ),
        icon: const AppIcon(Symbols.shuffle_rounded),
        selectedIcon: const AppIcon(Symbols.shuffle_on_rounded),
      ),
    );
  }

  void _goPrevious() => unawaited(_go(-1));
  void _goNext() => unawaited(_go(1));

  Widget _buildButton({required bool previous}) {
    return Align(
      alignment: previous ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        // The arrow keys move between photos, so the buttons stay out of the
        // focus order.
        child: ExcludeFocus(
          child: IconButton(
            onPressed: previous ? _goPrevious : _goNext,
            tooltip: previous ? t.tooltips.previousPhoto : t.tooltips.nextPhoto,
            style: IconButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
            icon: AppIcon(previous ? Symbols.chevron_left_rounded : Symbols.chevron_right_rounded),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = _sequence.photo;
    final hasPrevious = _previousEntry != null;
    final hasNext = _nextEntry != null;
    // TV moves with the D-pad alone.
    final showButtons = !PlatformDetector.isTV();
    final viewer = PhotoViewerScreen(key: ValueKey(photo.globalKey), photo: photo);
    return PhotoNavigation(
      onPrevious: _previous == null ? null : _goPrevious,
      onNext: _next == null ? null : _goNext,
      keepsImage: _keepsImage,
      onPlay: _play,
      onSelect: widget.slideshow ? _togglePause : null,
      onZoomIn: widget.slideshow ? _pauseForZoom : null,
      header: widget.slideshow ? _header : null,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _noteInput(),
        onPointerHover: (_) => _noteInput(),
        child: Stack(
          children: [
            Positioned.fill(child: widget.slideshow ? _crossFade(viewer) : viewer),
            if (showButtons && hasPrevious) Positioned.fill(right: null, child: _buildButton(previous: true)),
            if (showButtons && hasNext) Positioned.fill(left: null, child: _buildButton(previous: false)),
            if (_paused) _buildPausedBadge(context),
            if (widget.slideshow) Positioned(top: 0, left: 0, right: 0, child: _buildHeader(context)),
          ],
        ),
      ),
    );
  }

  /// Fades each photo of a slideshow in over the one before. Only the photo
  /// coming in takes focus and touches.
  Widget _crossFade(PhotoViewerScreen viewer) {
    return AnimatedSwitcher(
      duration: DevicePerformance.isReduced ? Duration.zero : PhotoSequenceViewer.slideshowCrossFade,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        final leaving = child.key != viewer.key;
        return FadeTransition(
          opacity: animation,
          child: ExcludeFocus(
            excluding: leaving,
            child: IgnorePointer(ignoring: leaving, child: child),
          ),
        );
      },
      child: viewer,
    );
  }

  Widget _buildPausedBadge(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: Semantics(
          label: t.tooltips.slideshowPaused,
          child: const DecoratedBox(
            decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: AppIcon(Symbols.pause_rounded, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// A slideshow found too many items in a row that would not load.
class _TooManyFailures implements Exception {
  const _TooManyFailures();
}

/// Reports a horizontal swipe made with one finger. A listener, not a gesture
/// recognizer, so it takes nothing from the gestures of the photo below.
class PhotoSwipeDetector extends StatefulWidget {
  const PhotoSwipeDetector({super.key, required this.canSwipe, required this.onPrevious, required this.onNext});

  /// Whether a swipe would change photo now. Checked when the finger lands and
  /// when it lifts, so a zoom in between keeps the drag a pan.
  final bool Function() canSwipe;

  /// A swipe to the right.
  final VoidCallback onPrevious;

  /// A swipe to the left.
  final VoidCallback onNext;

  /// Shortest horizontal travel that counts as a swipe.
  static const double minDistance = 64;

  @override
  State<PhotoSwipeDetector> createState() => _PhotoSwipeDetectorState();
}

class _PhotoSwipeDetectorState extends State<PhotoSwipeDetector> {
  final Set<int> _pointers = {};

  /// Where the one finger down landed, while the touch can still be a swipe.
  Offset? _start;

  static bool _isTouch(PointerEvent event) =>
      event.kind == PointerDeviceKind.touch ||
      event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus;

  void _down(PointerDownEvent event) {
    if (!_isTouch(event)) return;
    _pointers.add(event.pointer);
    _start = _pointers.length == 1 && widget.canSwipe() ? event.position : null;
  }

  void _up(PointerUpEvent event) {
    if (!_pointers.remove(event.pointer)) return;
    final start = _start;
    _start = null;
    if (start == null || !widget.canSwipe()) return;
    final travel = event.position - start;
    if (travel.dx.abs() < PhotoSwipeDetector.minDistance || travel.dx.abs() <= travel.dy.abs() * 2) return;
    travel.dx < 0 ? widget.onNext() : widget.onPrevious();
  }

  void _cancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _start = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _cancel,
    );
  }
}
