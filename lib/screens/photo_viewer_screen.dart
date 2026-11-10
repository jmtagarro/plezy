import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import '../focus/dpad_navigator.dart';
import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import '../utils/formatters.dart';
import '../utils/immersive_mode_guard.dart';
import '../utils/media_image_helper.dart';
import '../utils/orientation_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/app_icon.dart';
import 'photo_sequence_viewer.dart';

/// Shows one photo full-screen, sized to the screen, with pinch and scroll zoom.
class PhotoViewerScreen extends StatefulWidget {
  final MediaItem photo;

  const PhotoViewerScreen({super.key, required this.photo});

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();

  /// Longest edge of the screen-sized image: the monitor's long edge in
  /// physical pixels, capped. The window's own edge stands in when it is
  /// larger, or when the platform reports no display size.
  static int screenImageEdge(BuildContext context) {
    final windowEdge = MediaQuery.sizeOf(context).longestSide * MediaQuery.devicePixelRatioOf(context);
    double displayEdge = 0;
    try {
      displayEdge = View.of(context).display.size.longestSide;
    } catch (_) {
      // No display information on this platform.
    }
    return math.min(math.max(windowEdge, displayEdge).ceil(), _PhotoViewerScreenState._maxImageEdge);
  }

  /// The screen-sized image of [path], under the cache key the viewer shows it
  /// with, or null when the server gives no URL for it.
  static ({String url, ImageProvider image})? screenImage(MediaServerClient client, String? path, int edge) {
    final url = client.thumbnailUrl(path, width: edge, height: edge, cover: false);
    if (url.isEmpty) return null;
    return (url: url, image: MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: edge, memHeight: edge));
  }
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  /// Longest edge requested. The decoded bitmap stays within this square,
  /// which keeps a large original from exhausting a low-RAM TV.
  static const int _maxImageEdge = 3840;
  static const double _maxZoom = 5;

  /// Where focus starts, so that Enter on opening does not press Back.
  final FocusNode _photoFocusNode = FocusNode(debugLabel: 'photo_viewer_photo');
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'photo_viewer_back');
  final TransformationController _transformation = TransformationController();

  /// Fixed at open, sized to the monitor rather than the window, and a square,
  /// so turning the phone or resizing or maximising the window does not
  /// refetch the image.
  int? _imageEdge;
  bool _immersive = false;

  /// The sequence this photo belongs to, when the viewer shows one.
  PhotoNavigation? _navigation;

  /// The play button a clip shows instead of zoom, where focus starts on one.
  final FocusNode _playFocusNode = FocusNode(debugLabel: 'photo_viewer_play');

  /// Images this viewer put in the artwork cache, by URL. Each one is the size
  /// of the screen, so their decoded bitmaps leave the memory cache when the
  /// viewer closes, unless the sequence around it still shows them next to the
  /// current photo. Their files stay in the disk cache, so reopening the photo
  /// does not download it again.
  final Map<String, ImageProvider> _screenImages = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entryFocusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _imageEdge ??= PhotoViewerScreen.screenImageEdge(context);
    _navigation = PhotoNavigation.maybeOf(context);
    if (!_immersive && PlatformDetector.isMobile(context)) {
      _immersive = true;
      ImmersiveModeGuard.acquire(this);
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
  }

  @override
  void dispose() {
    // Released before the overlays are shown: the re-show callback that
    // follows must find no owner, or it would hide them again. The viewer of
    // the next photo in a sequence takes over before this one is disposed, and
    // keeps the bars hidden.
    if (_immersive && ImmersiveModeGuard.release(this)) {
      unawaited(
        OrientationHelper.restoreSystemUI().catchError((Object e) {
          appLogger.w('Failed to restore system UI', error: e);
        }),
      );
    }
    for (final MapEntry(key: url, value: image) in _screenImages.entries) {
      // The sequence keeps the photos next to the one it shows.
      if (_navigation?.keepsImage(url) != true) unawaited(image.evict());
    }
    _transformation.dispose();
    _photoFocusNode.dispose();
    _backFocusNode.dispose();
    _playFocusNode.dispose();
    super.dispose();
  }

  /// A clip of a sequence, which plays from its page instead of zooming.
  bool get _isClip => widget.photo.kind == MediaKind.clip && _navigation?.onPlay != null;

  FocusNode get _entryFocusNode => _isClip ? _playFocusNode : _photoFocusNode;

  /// Focus comes back to the play button with the route when the player
  /// closes.
  void _play() => unawaited(_navigation?.onPlay?.call(widget.photo));

  Widget _buildPlayButton(BuildContext context) {
    final durationMs = widget.photo.durationMs;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FocusableButton(
            focusNode: _playFocusNode,
            onPressed: _play,
            child: IconButton.filled(
              onPressed: _play,
              tooltip: t.common.play,
              iconSize: 48,
              padding: const EdgeInsets.all(16),
              style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
              icon: const AppIcon(Symbols.play_arrow_rounded),
            ),
          ),
          if (durationMs != null && durationMs > 0) ...[
            const SizedBox(height: 8),
            Text(
              formatDurationTimestamp(Duration(milliseconds: durationMs)),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  /// The photo's own title, or its album's when it has none.
  String get _title {
    final title = widget.photo.title;
    if (title != null && title.isNotEmpty) return title;
    return widget.photo.parentTitle ?? '';
  }

  /// When the photo was taken, as the server reports it. Shown only: imports
  /// such as Google Takeout can carry the import date instead.
  String? get _dateLabel {
    final date = widget.photo.originallyAvailableAt;
    return date == null || date.isEmpty ? null : formatFullDate(date);
  }

  /// Up and Down move between the photo and the back button. Left and Right
  /// move to the previous and next photo of the sequence, once per press, as
  /// each photo is a new request to the server. They are consumed either way,
  /// so they cannot wander off to the back button.
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (!key.isDpadDirection) return handleBackKeyNavigation(context, event);
    if (event.isActionable) {
      if (key == LogicalKeyboardKey.arrowUp) _backFocusNode.requestFocus();
      if (key == LogicalKeyboardKey.arrowDown) _entryFocusNode.requestFocus();
    }
    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) _navigation?.onPrevious?.call();
      if (key == LogicalKeyboardKey.arrowRight) _navigation?.onNext?.call();
    }
    return KeyEventResult.handled;
  }

  Widget _buildHeaderText(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dateLabel = _dateLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
        if (dateLabel != null)
          Text(
            dateLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          t.errors.unableToLoad(context: _title),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  /// [path] drawn to fit the screen, or whatever [onFailed] builds when it
  /// cannot be loaded.
  Widget _buildImage(MediaServerClient client, String? path, {required Widget Function() onFailed}) {
    final screenImage = PhotoViewerScreen.screenImage(client, path, _imageEdge!);
    if (screenImage == null) return onFailed();
    return Image(
      image: _screenImages.putIfAbsent(screenImage.url, () => screenImage.image),
      fit: BoxFit.contain,
      semanticLabel: _title,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const Center(child: CircularProgressIndicator()),
      errorBuilder: (context, error, stackTrace) => onFailed(),
    );
  }

  Widget _buildPhoto() {
    final client = context.tryGetMediaClientForServer(serverIdOrNull(widget.photo.serverId));
    if (client == null) return _buildError();
    final imagePath = widget.photo.photoImagePath;
    final thumbPath = widget.photo.thumbPath;
    return _buildImage(
      client,
      imagePath,
      onFailed: () => imagePath == thumbPath ? _buildError() : _buildImage(client, thumbPath, onFailed: _buildError),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _handleKeyEvent(event),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Focus(
                focusNode: _photoFocusNode,
                // Select does nothing on the photo for now.
                onKeyEvent: (_, event) =>
                    event.logicalKey.isSelectKey ? KeyEventResult.handled : KeyEventResult.ignored,
                child: InteractiveViewer(
                  transformationController: _transformation,
                  // A clip's thumbnail stands for the video, so it does not zoom.
                  scaleEnabled: !_isClip,
                  maxScale: _maxZoom,
                  child: SizedBox.expand(child: _buildPhoto()),
                ),
              ),
            ),
            // Above the photo but never in its gesture arena, so pinches and
            // pans reach the photo untouched.
            Positioned.fill(
              child: PhotoSwipeDetector(
                canSwipe: () => _transformation.value.getMaxScaleOnAxis() <= 1,
                onPrevious: () => _navigation?.onPrevious?.call(),
                onNext: () => _navigation?.onNext?.call(),
              ),
            ),
            if (_isClip) Positioned.fill(child: _buildPlayButton(context)),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 96,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    AppBarBackButton(focusNode: _backFocusNode),
                    Expanded(
                      // Pinches that start on the title still reach the photo.
                      child: IgnorePointer(child: _buildHeaderText(context)),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
