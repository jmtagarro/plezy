import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kDoubleTapSlop, kDoubleTapTimeout, kPrimaryButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../services/device_performance.dart';
import '../utils/app_logger.dart';
import '../utils/formatters.dart';
import '../utils/immersive_mode_guard.dart';
import '../utils/media_image_helper.dart';
import '../utils/media_server_http_client.dart';
import '../utils/orientation_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_bar_back_button.dart';

/// Shows one photo full-screen, with pinch, double-tap and scroll zoom. The
/// image is sized to the screen, then replaced by one sized to the original the
/// first time the zoom passes [_PhotoViewerScreenState._upgradeZoom].
class PhotoViewerScreen extends StatefulWidget {
  final MediaItem photo;

  /// Replaces the platform transport for the zoom upgrade request.
  @visibleForTesting
  final http.Client? upgradeTransport;

  /// Replaces the decoder for the zoom upgrade, so a test can decide when the
  /// decode finishes.
  @visibleForTesting
  final Future<ui.Image> Function(ui.ImmutableBuffer buffer, int edge)? upgradeDecoder;

  const PhotoViewerScreen({super.key, required this.photo, this.upgradeTransport, this.upgradeDecoder});

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  /// Longest edge requested on open. The decoded bitmap stays within this
  /// square, which keeps a large original from exhausting a low-RAM TV.
  static const int _maxImageEdge = 3840;
  static const double _maxZoom = 5;
  static const double _doubleTapZoom = 2.5;
  static const double _upgradeZoom = 1.5;

  /// Longest edge requested and decoded by the zoom upgrade. A decoded 8192
  /// square image can take 256 MB, too much for the low-RAM devices on the
  /// reduced tier.
  static int get _maxUpgradeEdge => DevicePerformance.isReduced ? 4096 : 8192;

  /// Most the upgrade buffers. A transcoded PNG at the largest edge can be tens
  /// of megabytes, and a larger answer is not worth holding in memory.
  static const int _maxUpgradeBytes = 128 * 1024 * 1024;

  /// Where focus starts, so that Enter on opening does not press Back.
  final FocusNode _photoFocusNode = FocusNode(debugLabel: 'photo_viewer_photo');
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'photo_viewer_back');
  final TransformationController _transformation = TransformationController();

  /// Fixed at open, sized to the monitor rather than the window, and a square,
  /// so turning the phone or resizing or maximising the window does not
  /// refetch the image.
  int? _imageEdge;
  bool _immersive = false;

  /// Images this viewer put in the artwork cache, by URL. Each one is the size
  /// of the screen, so their decoded bitmaps leave the memory cache when the
  /// viewer closes. Their files stay in the disk cache, so reopening the photo
  /// does not download it again.
  final Map<String, ImageProvider> _screenImages = {};

  final _DoubleTapTracker _doubleTapTracker = _DoubleTapTracker();

  /// Set while the upgrade downloads. Closing it aborts the download.
  MediaServerHttpClient? _upgradeHttp;

  /// Decoded here rather than through the artwork cache, and disposed with the
  /// viewer, so the large image never outlives it.
  ui.Image? _largeImage;

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_onTransformChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _photoFocusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _imageEdge ??= math.min(_screenEdge(), _maxImageEdge);
    if (!_immersive && PlatformDetector.isMobile(context)) {
      _immersive = true;
      ImmersiveModeGuard.acquire(this);
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
  }

  @override
  void dispose() {
    if (_immersive) {
      // Before the overlays are shown: the re-show callback that follows must
      // find no owner, or it would hide them again.
      ImmersiveModeGuard.release(this);
      unawaited(
        OrientationHelper.restoreSystemUI().catchError((Object e) {
          appLogger.w('Failed to restore system UI', error: e);
        }),
      );
    }
    for (final image in _screenImages.values) {
      unawaited(image.evict());
    }
    _upgradeHttp?.close();
    _upgradeHttp = null;
    _largeImage?.dispose();
    _transformation.dispose();
    _photoFocusNode.dispose();
    _backFocusNode.dispose();
    super.dispose();
  }

  /// Longest edge of the monitor in physical pixels. The window's own edge
  /// stands in when it is larger, or when the platform reports no display size.
  int _screenEdge() {
    final windowEdge = MediaQuery.sizeOf(context).longestSide * MediaQuery.devicePixelRatioOf(context);
    double displayEdge = 0;
    try {
      displayEdge = View.of(context).display.size.longestSide;
    } catch (_) {
      // No display information on this platform.
    }
    return math.max(windowEdge, displayEdge).ceil();
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

  /// Up and Down move between the photo and the back button. Left and Right do
  /// nothing yet, and are consumed so they cannot wander off to the back button.
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (!key.isDpadDirection) return handleBackKeyNavigation(context, event);
    if (event.isActionable) {
      if (key == LogicalKeyboardKey.arrowUp) _backFocusNode.requestFocus();
      if (key == LogicalKeyboardKey.arrowDown) _photoFocusNode.requestFocus();
    }
    return KeyEventResult.handled;
  }

  void _onTransformChanged() {
    if (_transformation.value.getMaxScaleOnAxis() <= _upgradeZoom) return;
    // Once per photo, whatever comes of the request.
    _transformation.removeListener(_onTransformChanged);
    final request = _upgradeRequest();
    if (request != null) unawaited(_loadLargeImage(request.url, request.edge));
  }

  /// The image sized to the original, with the edge it is sized to, or null
  /// when it would add nothing or the original's size is unknown.
  ///
  /// Jellyfin and Emby follow the same rule, as their image route takes the
  /// `maxWidth`/`maxHeight` that [MediaServerClient.thumbnailUrl] sends. Their
  /// photos take the size from `MediaSources`, or from the item's own `Width`
  /// and `Height`; one with neither skips the upgrade.
  ({String url, int edge})? _upgradeRequest() {
    final version = widget.photo.mediaVersions?.firstOrNull;
    final width = version?.width;
    final height = version?.height;
    if (width == null || height == null) return null;
    final edge = math.min(math.max(width, height), _maxUpgradeEdge);
    if (edge <= _imageEdge!) return null;
    final client = context.tryGetMediaClientForServer(serverIdOrNull(widget.photo.serverId));
    final url = client?.thumbnailUrl(widget.photo.photoImagePath, width: edge, height: edge, cover: false);
    return url == null || url.isEmpty ? null : (url: url, edge: edge);
  }

  /// Fetched outside the artwork cache, as an [ImageProvider] download cannot
  /// be cancelled and an image this large would also fill the disk cache. A
  /// failure leaves the screen-sized image in place.
  Future<void> _loadLargeImage(String url, int edge) async {
    final httpClient = _upgradeHttp = MediaServerHttpClient(client: widget.upgradeTransport);
    try {
      Uint8List? bytes = await httpClient.getBytes(
        url,
        headers: const {'User-Agent': 'Plezy'},
        maxBytes: _maxUpgradeBytes,
      );
      if (!mounted) return;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // The engine holds its own copy now. Drop the download, which can be tens
      // of megabytes, instead of keeping it until the decode finishes.
      bytes = null;
      if (!mounted) {
        buffer.dispose();
        return;
      }
      final image = await (widget.upgradeDecoder ?? _decode)(buffer, edge);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _largeImage = image);
    } catch (error) {
      if (mounted) appLogger.d('Photo viewer: keeping the screen-sized image', error: error);
    } finally {
      _upgradeHttp?.close();
      _upgradeHttp = null;
    }
  }

  /// Decodes [buffer] to fit inside an [edge] square, so a server that ignores
  /// the requested size still cannot produce a bitmap past the cap. The codec
  /// takes [buffer] over and frees it.
  static Future<ui.Image> _decode(ui.ImmutableBuffer buffer, int edge) async {
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final scale = math.min(1.0, edge / math.max(width, height));
        return ui.TargetImageSize(width: (width * scale).round(), height: (height * scale).round());
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// Zooms around [position], or back out when already zoomed in.
  void _toggleDoubleTapZoom(Offset position) {
    if (_transformation.value.getMaxScaleOnAxis() > 1) {
      _transformation.value = Matrix4.identity();
      return;
    }
    final scene = _transformation.toScene(position);
    _transformation.value = Matrix4.diagonal3Values(_doubleTapZoom, _doubleTapZoom, 1)
      ..setTranslationRaw(position.dx - scene.dx * _doubleTapZoom, position.dy - scene.dy * _doubleTapZoom, 0);
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
    final edge = _imageEdge!;
    final url = client.thumbnailUrl(path, width: edge, height: edge, cover: false);
    if (url.isEmpty) return onFailed();
    return Image(
      image: _screenImages.putIfAbsent(
        url,
        () => MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: edge, memHeight: edge),
      ),
      fit: BoxFit.contain,
      semanticLabel: _title,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const Center(child: CircularProgressIndicator()),
      errorBuilder: (context, error, stackTrace) => onFailed(),
    );
  }

  Widget _buildPhoto() {
    // Laid out in the same box as the screen-sized image, and the zoom lives on
    // the viewer around it, so the swap moves nothing.
    final largeImage = _largeImage;
    if (largeImage != null) {
      return Semantics(
        image: true,
        label: _title,
        child: RawImage(image: largeImage, fit: BoxFit.contain),
      );
    }
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
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _doubleTapTracker.down,
                  onPointerMove: _doubleTapTracker.move,
                  onPointerCancel: _doubleTapTracker.cancel,
                  onPointerUp: (event) {
                    final position = _doubleTapTracker.up(event);
                    if (position != null) _toggleDoubleTapZoom(position);
                  },
                  child: InteractiveViewer(
                    transformationController: _transformation,
                    maxScale: _maxZoom,
                    child: SizedBox.expand(child: _buildPhoto()),
                  ),
                ),
              ),
            ),
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

/// Spots a double tap from raw pointer events. A double-tap gesture recognizer
/// would compete with the viewer's own in the gesture arena, which holds back
/// every pinch and pan until it has moved past the slop.
class _DoubleTapTracker {
  int _pointers = 0;

  /// Where the current press began, for as long as it can still be a tap.
  Offset? _press;
  bool _pressPairsWithLastTap = false;
  Duration? _lastTapTime;
  Offset? _lastTapPosition;

  void down(PointerDownEvent event) {
    _pointers++;
    if (_pointers > 1 || event.buttons != kPrimaryButton) {
      _reset();
      return;
    }
    final lastTapTime = _lastTapTime;
    final lastTapPosition = _lastTapPosition;
    _press = event.localPosition;
    _pressPairsWithLastTap =
        lastTapTime != null &&
        lastTapPosition != null &&
        event.timeStamp - lastTapTime < kDoubleTapTimeout &&
        (event.localPosition - lastTapPosition).distance < kDoubleTapSlop;
  }

  void move(PointerMoveEvent event) {
    final press = _press;
    if (press != null && (event.localPosition - press).distance > kTouchSlop) _reset();
  }

  void cancel(PointerCancelEvent event) {
    _pointers--;
    _reset();
  }

  /// Where the double tap landed, when this release completes one.
  Offset? up(PointerUpEvent event) {
    _pointers--;
    final press = _press;
    if (press == null) return null;
    _press = null;
    if (_pressPairsWithLastTap) {
      _reset();
      return press;
    }
    _lastTapTime = event.timeStamp;
    _lastTapPosition = press;
    return null;
  }

  void _reset() {
    _press = null;
    _pressPairsWithLastTap = false;
    _lastTapTime = null;
    _lastTapPosition = null;
  }
}
