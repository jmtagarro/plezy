import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_server_client.dart';
import '../../screens/photo_sequence_viewer.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../jellyfin_client.dart';
import '../plex_client.dart';
import 'media_browser_photo_shuffle_source.dart';
import 'photo_shuffle_source.dart';
import 'photo_walk_source.dart';
import 'plex_photo_queue_source.dart';

/// Starts a shuffled slideshow of everything a photo album, folder, collection
/// or library holds.
abstract final class PhotoShuffleLauncher {
  /// Replaces [start] in tests of the screens that offer a shuffle.
  @visibleForTesting
  static Future<void> Function(BuildContext context, PhotoShuffleTarget target)? debugStartOverride;

  /// Whether [library] shuffles into a photo slideshow.
  static bool shufflesLibrary(MediaLibrary library) => library.kind == MediaKind.photo && !library.isShared;

  /// Whether [collection] holds photos, as far as the server says before it is
  /// opened: Plex marks a photo collection's subtype.
  static bool isPhotoCollection(MediaItem collection) =>
      collection.kind == MediaKind.collection && collection is PlexMediaItem && collection.subtype == 'photo';

  /// Loads the first items of [target] in a random order behind a spinner,
  /// then runs the slideshow. Says so when there is nothing to show.
  static Future<void> start(BuildContext context, PhotoShuffleTarget target) async {
    final override = debugStartOverride;
    if (override != null) return override(context, target);
    final client = context.tryGetMediaClientForServer(photoShuffleServerId(target));
    if (client == null) {
      showErrorSnackBar(context, t.errors.noClientAvailable);
      return;
    }
    final loading = ScopedLoadingDialogController()
      ..show(context, builder: (_) => const Center(child: CircularProgressIndicator()));
    final ({PhotoShuffleSource source, PhotoSequence sequence})? opened;
    try {
      opened = await open(client, target);
    } finally {
      await loading.dismiss();
    }
    if (opened == null) {
      if (context.mounted) showErrorSnackBar(context, t.messages.failedToCreatePlayQueueNoItems);
      return;
    }
    try {
      if (context.mounted) await openPhotoSequence(context, opened.sequence, slideshow: true);
    } finally {
      opened.source.dispose();
    }
  }

  /// The server's own shuffle of [target] where it has one, or a walk of it
  /// on the device when that fails or comes back empty. Null when neither
  /// finds anything to show.
  static Future<({PhotoShuffleSource source, PhotoSequence sequence})?> open(
    MediaServerClient client,
    PhotoShuffleTarget target,
  ) async {
    final served = switch (client) {
      PlexClient() => PlexPhotoQueueSource(client: client, target: target),
      JellyfinClient() => MediaBrowserPhotoShuffleSource(client: client, target: target),
      _ => null,
    };
    if (served != null) {
      try {
        final sequence = await _sequenceOf(served);
        if (sequence != null) return (source: served, sequence: sequence);
        appLogger.i('Photo shuffle: the server shuffled nothing for ${target.logLabel}; walking it instead');
      } catch (error, stackTrace) {
        appLogger.w(
          'Photo shuffle: the server could not shuffle ${target.logLabel}; walking it instead',
          error: error,
          stackTrace: stackTrace,
        );
      }
      served.dispose();
    }
    final walk = PhotoWalkSource(client: client, target: target);
    try {
      final sequence = await _sequenceOf(walk);
      if (sequence != null) return (source: walk, sequence: sequence);
    } catch (error, stackTrace) {
      appLogger.w('Photo shuffle: could not walk ${target.logLabel}', error: error, stackTrace: stackTrace);
    }
    walk.dispose();
    return null;
  }

  static Future<PhotoSequence?> _sequenceOf(PhotoShuffleSource source) async =>
      await source.start() ? await source.sequence() : null;
}
