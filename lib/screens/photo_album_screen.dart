import 'package:flutter/material.dart';
import '../focus/focusable_action_bar.dart';
import '../focus/input_mode_tracker.dart';
import '../i18n/strings.g.dart';
import '../media/library_query.dart';
import '../media/media_item.dart';
import '../mixins/grid_focus_node_mixin.dart';
import '../mixins/paginated_item_loader.dart';
import '../mixins/standard_paginated_view.dart';
import '../utils/app_logger.dart';
import '../utils/error_message_utils.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/media_server_http_client.dart';
import '../widgets/desktop_app_bar.dart';
import 'base_media_list_detail_screen.dart';
import 'focusable_detail_screen_mixin.dart';
import 'photo_sequence_viewer.dart';

/// Grid of what a photo album holds: photos, clips and nested albums, each of
/// which opens the way its own card does.
class PhotoAlbumScreen extends StatefulWidget {
  final MediaItem album;

  const PhotoAlbumScreen({super.key, required this.album});

  @override
  State<PhotoAlbumScreen> createState() => _PhotoAlbumScreenState();
}

class _PhotoAlbumScreenState extends BaseMediaListDetailScreen<PhotoAlbumScreen>
    with
        GridFocusNodeMixin<PhotoAlbumScreen>,
        FocusableDetailScreenMixin<PhotoAlbumScreen>,
        PaginatedItemLoader<MediaItem, PhotoAlbumScreen>,
        PaginatedItemUpdatable<PhotoAlbumScreen>,
        StandardPaginatedView<MediaItem, PhotoAlbumScreen> {
  static const int _pageSize = 200;

  @override
  MediaItem get mediaItem => widget.album;

  @override
  String get title => widget.album.displayTitle;

  @override
  String get emptyMessage => t.discover.noContentAvailable;

  @override
  bool get hasItems => totalSize > 0;

  @override
  void dispose() {
    disposePagination();
    disposeFocusResources();
    super.dispose();
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPage(int start, int size, AbortController? abort) {
    return mediaClient.fetchChildrenPage(widget.album.id, start: start, size: size, abort: abort);
  }

  @override
  Future<void> loadItems() {
    return loadStandardPaginatedItems(
      pageSize: _pageSize,
      errorMessageFor: (error, stackTrace) => localizedLoadErrorMessage(error, stackTrace, context: title),
      onLoaded: (loadedCount, totalCount) {
        appLogger.d('Loaded $loadedCount of $totalCount items for photo album: $title');
        autoFocusFirstItemAfterLoad();
      },
    );
  }

  @override
  List<FocusableAction> getAppBarActions() => const [];

  /// Photos and clips open in a viewer that moves through them. Nested albums
  /// open the way their cards do.
  Future<void> _openItem(int index) async {
    final item = loadedItems[index];
    if (item == null) return;
    if (!PhotoSequence.shows(item)) {
      await navigateToMediaItem(context, item, onRefresh: updateItem);
      return;
    }
    final sequence = PhotoSequence(
      index: index,
      photo: item,
      length: () => totalSize,
      itemAt: (i) => loadedItems[i],
      loadItemAt: (i) => loadItemAt(i, pageSize: _pageSize),
    );
    await openPhotoSequence(context, sequence);
    if (mounted && sequence.index != index) _revealItem(sequence.index);
  }

  /// Focuses the card at [index], scrolling the grid to it first when it is
  /// out of view. Waits for the route's own focus restore, which goes back to
  /// the card that opened the viewer.
  void _revealItem(int index) {
    final node = focusNodeForIndex(index, firstItemFocusNode, prefix: 'detail_grid_item');
    bool cardMounted() => node.context?.mounted ?? false;
    void reveal() {
      if (!mounted || !cardMounted()) return;
      node.requestFocus();
      // Focus scrolls the card into view only in keyboard mode.
      if (!InputModeTracker.isKeyboardMode(context, listen: false)) {
        Scrollable.ensureVisible(node.context!, alignment: 0.5);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (cardMounted()) return reveal();
        // Land near the card so the grid builds it, then place it exactly.
        if (scrollController.hasClients && totalSize > 0) {
          final position = scrollController.position;
          final extent = position.maxScrollExtent + position.viewportDimension;
          final estimate = extent * index / totalSize - position.viewportDimension / 2;
          position.jumpTo(estimate.clamp(position.minScrollExtent, position.maxScrollExtent));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return buildDetailScaffold(
      slivers: [
        CustomAppBar(
          title: Text(title),
          pinned: true,
          actions: buildFocusableAppBarActions(),
          onBackPressed: popFromAppBar,
        ),
        ...buildStateSlivers(),
        if (hasItems)
          buildSparseFocusableGrid(
            totalItems: totalSize,
            itemAt: (index) => loadedItems[index],
            onRefresh: updateItem,
            onItemTap: _openItem,
            onSkeletonVisible: (index) => ensureIndexLoaded(index, pageSize: _pageSize),
          ),
      ],
    );
  }
}
