import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the player immersive across system-UI re-shows the engine does not
/// handle on its own.
///
/// Flutter's Android `PlatformPlugin` re-applies the requested
/// [SystemUiMode] only in `onPostResume`. A configuration change that keeps
/// the activity resumed — folding or unfolding, a display switch — lets
/// Android show the bars again with nothing to hide them. The engine's hook
/// for that is `SystemChrome.systemUIChange`: Android posts it when the
/// system re-shows the overlays, and the owner answers by re-requesting
/// [SystemUiMode.immersiveSticky]. Other platforms never post it, so the
/// guard is a no-op there; TV has no bars to re-hide.
///
/// Owners stack: a screen that opens over another immersive screen, such as
/// the player over the photo viewer, owns immersive mode until it releases it,
/// and the one below owns it again after. A successor (the next player, or
/// the viewer of the next photo) acquires before its predecessor releases, so
/// [release] removes the caller wherever it stands and reports whether it was
/// the current owner. Every owner releases in its `dispose`, whatever ended
/// it, so nothing stays in the stack once its screen is gone.
///
/// The native listener is registered once and stays registered — Flutter
/// never unregisters it — and does nothing while nobody owns immersive mode.
abstract final class ImmersiveModeGuard {
  static final List<Object> _owners = [];
  static bool _listening = false;

  static void acquire(Object owner) {
    _owners
      ..removeWhere((existing) => identical(existing, owner))
      ..add(owner);
    if (_listening) return;
    _listening = true;
    unawaited(SystemChrome.setSystemUIChangeCallback(_onSystemUiChange));
  }

  /// Removes [owner], and reports whether it was the current owner. A
  /// predecessor that lost it to a successor must leave the system UI as the
  /// successor set it.
  static bool release(Object owner) {
    final wasCurrent = _owners.isNotEmpty && identical(_owners.last, owner);
    _owners.removeWhere((existing) => identical(existing, owner));
    return wasCurrent;
  }

  /// Whether a screen still wants immersive mode. One that releases it should
  /// show the system UI again only when nobody does.
  static bool get isOwned => _owners.isNotEmpty;

  static Future<void> _onSystemUiChange(bool systemOverlaysAreVisible) async {
    if (!systemOverlaysAreVisible || _owners.isEmpty) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @visibleForTesting
  static void resetForTesting() {
    _owners.clear();
    _listening = false;
    unawaited(SystemChrome.setSystemUIChangeCallback(null));
  }
}
