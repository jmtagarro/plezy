import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../services/device_performance.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import 'photo_viewer_screen.dart';

/// A photo of a [PhotoSequence], with its position in the list it comes from.
typedef PhotoSequenceEntry = ({int index, MediaItem photo});

/// The list a photo was opened from, in the order its grid shows it. The
/// viewer moves through its photos and skips clips and albums in between.
class PhotoSequence {
  PhotoSequence({
    required this.index,
    required this.photo,
    required this._length,
    required this._itemAt,
    required this._loadItemAt,
  });

  /// [photo] on its own, with nothing before or after it.
  PhotoSequence.single(MediaItem photo)
    : this(index: 0, photo: photo, length: () => 1, itemAt: (_) => photo, loadItemAt: (_) async => photo);

  /// Position of the photo shown, read back by the list once the viewer
  /// closes.
  int index;

  /// The photo shown.
  MediaItem photo;

  final int Function() _length;
  final MediaItem? Function(int index) _itemAt;
  final Future<MediaItem?> Function(int index) _loadItemAt;

  /// The nearest photo from [from] in the direction of [step] (-1 or 1),
  /// loading the list as it goes. Null at the end of the list, or when part of
  /// it cannot be loaded.
  Future<PhotoSequenceEntry?> neighbour(int from, int step) async {
    for (var i = from + step; i >= 0 && i < _length(); i += step) {
      final item = _itemAt(i) ?? await _loadItemAt(i);
      if (item == null) {
        appLogger.d('Photo viewer: no item at $i, so the sequence ends there');
        return null;
      }
      if (item.kind == MediaKind.photo) return (index: i, photo: item);
    }
    return null;
  }
}

/// Opens the viewer on the photo [sequence] stands on.
Future<void> openPhotoSequence(BuildContext context, PhotoSequence sequence) {
  return Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PhotoSequenceViewer(sequence: sequence)));
}

/// What the viewer of one photo needs from the sequence around it.
class PhotoNavigation extends InheritedWidget {
  const PhotoNavigation({
    super.key,
    required this.onPrevious,
    required this.onNext,
    required this.keepsImage,
    required super.child,
  });

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
      onPrevious != oldWidget.onPrevious || onNext != oldWidget.onNext || keepsImage != oldWidget.keepsImage;
}

/// Shows the photos of a [PhotoSequence] one at a time, with one
/// [PhotoViewerScreen] per photo, so nothing the viewer keeps about a photo,
/// such as its zoom, carries over to the next one.
class PhotoSequenceViewer extends StatefulWidget {
  final PhotoSequence sequence;

  const PhotoSequenceViewer({super.key, required this.sequence});

  @override
  State<PhotoSequenceViewer> createState() => _PhotoSequenceViewerState();
}

class _PhotoSequenceViewerState extends State<PhotoSequenceViewer> {
  PhotoSequence get _sequence => widget.sequence;

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

  @override
  void initState() {
    super.initState();
    _resolveNeighbours();
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
    _previous = previous != null ? Future.value(previous) : _sequence.neighbour(from, -1);
    _next = next != null ? Future.value(next) : _sequence.neighbour(from, 1);
    if (previous == null) {
      unawaited(
        _previous!.then((entry) {
          if (!mounted || generation != _generation || entry == null) return;
          setState(() => _previousEntry = entry);
          _updateWindow();
        }),
      );
    }
    if (next == null) {
      unawaited(
        _next!.then((entry) {
          if (!mounted || generation != _generation || entry == null) return;
          setState(() => _nextEntry = entry);
          _updateWindow();
        }),
      );
    }
    _updateWindow();
  }

  Future<void> _go(int step) async {
    final target = step < 0 ? _previous : _next;
    if (_moving || target == null) return;
    _moving = true;
    final generation = _generation;
    try {
      final entry = await target;
      if (!mounted || entry == null || generation != _generation) return;
      final left = (index: _sequence.index, photo: _sequence.photo);
      setState(() {
        _sequence
          ..index = entry.index
          ..photo = entry.photo;
        _direction = step;
      });
      // Before the frame that replaces the viewer, so the one leaving keeps the
      // image of the photo it showed, which is now next to the current one.
      _resolveNeighbours(previous: step > 0 ? left : null, next: step < 0 ? left : null);
    } finally {
      _moving = false;
    }
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
    return PhotoNavigation(
      onPrevious: _previous == null ? null : _goPrevious,
      onNext: _next == null ? null : _goNext,
      keepsImage: _keepsImage,
      child: Stack(
        children: [
          Positioned.fill(
            child: PhotoViewerScreen(key: ValueKey(photo.globalKey), photo: photo),
          ),
          if (showButtons && hasPrevious) Positioned.fill(right: null, child: _buildButton(previous: true)),
          if (showButtons && hasNext) Positioned.fill(left: null, child: _buildButton(previous: false)),
        ],
      ),
    );
  }
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
