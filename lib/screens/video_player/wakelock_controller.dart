import 'package:wakelock_plus/wakelock_plus.dart';

import '../../utils/app_logger.dart';

typedef WakelockPlatformToggle = Future<void> Function(bool enabled);

/// Serializes fire-and-forget wakelock requests around the latest desired state.
///
/// Each owner holds or lets go of the wakelock on its own, and the screen stays
/// awake while any of them holds it, so one screen letting go late (a player
/// closing over a slideshow) cannot switch it off under another.
class WakelockController {
  WakelockController({WakelockPlatformToggle? platformToggle})
    : _platformToggle = platformToggle ?? _togglePlatformWakelock;

  /// The app's wakelock, shared by the player and the photo slideshow.
  static final WakelockController shared = WakelockController();

  static const Object _defaultOwner = Object();

  final WakelockPlatformToggle _platformToggle;

  Future<void> _tail = Future<void>.value();
  bool? _effectiveEnabled;
  bool _desiredEnabled = false;
  final Set<Object> _holders = {};

  /// Whether anyone holds the wakelock.
  bool get isHeld => _holders.isNotEmpty;

  /// Whether [owner] holds the wakelock.
  bool isHeldBy(Object owner) => _holders.contains(owner);

  /// Requests a wakelock state for [owner] and completes after this queued
  /// reconciliation. Callers that pass no owner share one.
  ///
  /// Platform failures are logged and absorbed so detached UI callers cannot
  /// produce unhandled errors. A failed state is not recorded as effective;
  /// the same value can therefore be retried by a later explicit request.
  Future<void> setEnabled(bool enabled, {Object? owner}) {
    final holder = owner ?? _defaultOwner;
    enabled ? _holders.add(holder) : _holders.remove(holder);
    _desiredEnabled = _holders.isNotEmpty;
    final operation = _tail.then((_) => _reconcile());
    _tail = operation;
    return operation;
  }

  Future<void> _reconcile() async {
    while (_effectiveEnabled != _desiredEnabled) {
      final target = _desiredEnabled;
      try {
        await _platformToggle(target);
        _effectiveEnabled = target;
      } catch (error, stackTrace) {
        appLogger.w('Wakelock ${target ? 'enable' : 'disable'} failed', error: error, stackTrace: stackTrace);

        // Do not spin on a persistent failure. If an opposing request arrived
        // during the await, it still gets one attempt before this operation
        // settles; an identical state retries only through another setEnabled.
        if (_desiredEnabled == target) return;
      }
    }
  }
}

Future<void> _togglePlatformWakelock(bool enabled) => WakelockPlus.toggle(enable: enabled);
