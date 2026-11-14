import 'package:flutter/foundation.dart';

/// Ties a player to the sequence it was opened from, such as the photos and
/// clips of an album. The sequence says which ways there is an item to go to;
/// the player's next and previous commands then close the player and ask the
/// sequence to move, instead of looking for an episode or queue item.
class PlayerSequenceLink extends ChangeNotifier {
  PlayerSequenceLink({this._hasPrevious = false, this._hasNext = false});

  bool _hasPrevious;
  bool _hasNext;
  int? _requestedStep;

  /// Whether the sequence has an item before the one playing.
  bool get hasPrevious => _hasPrevious;
  set hasPrevious(bool value) {
    if (_hasPrevious == value) return;
    _hasPrevious = value;
    notifyListeners();
  }

  /// Whether the sequence has an item after the one playing.
  bool get hasNext => _hasNext;
  set hasNext(bool value) {
    if (_hasNext == value) return;
    _hasNext = value;
    notifyListeners();
  }

  /// Whether there is an item in the direction of [step] (-1 or 1).
  bool hasItem(int step) => step < 0 ? _hasPrevious : _hasNext;

  /// The move the player asked for as it closed: -1 for the previous item, 1
  /// for the next one, null when it closed for any other reason.
  int? get requestedStep => _requestedStep;

  /// Records the move the player closes for.
  void request(int step) => _requestedStep = step < 0 ? -1 : 1;
}
