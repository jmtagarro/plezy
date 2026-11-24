import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/dpad_navigator.dart';
import '../../../focus/focusable_button.dart';
import '../../../i18n/strings.g.dart';
import '../../../utils/platform_detector.dart';
import '../../app_icon.dart';
import '../video_control_button.dart';

/// What a sequence goes through, and the ways to switch it, as its bar shows
/// them. Built by the screen that owns the sequence, and handed to the player
/// of its clips so both draw the same bar.
@immutable
class SequenceMode {
  const SequenceMode({
    required this.label,
    this.album,
    this.onOpenAlbum,
    this.shuffling = false,
    this.switching = false,
    this.onToggleShuffle,
  });

  /// What the sequence goes through, and where in it: "Shuffle · Holidays",
  /// "Album · Summer · 3 / 40", or just "3 / 40".
  final String label;

  /// The album the item shown is directly in, which [onOpenAlbum] switches
  /// to. Null when there is none to offer.
  final String? album;

  final VoidCallback? onOpenAlbum;

  /// Whether the shuffle plays, rather than an album opened from it.
  final bool shuffling;

  /// An album is being opened.
  final bool switching;

  /// Switches between the shuffle and the album of the item shown. Null when
  /// the sequence is not a shuffle.
  final VoidCallback? onToggleShuffle;

  @override
  bool operator ==(Object other) =>
      other is SequenceMode &&
      other.label == label &&
      other.album == album &&
      other.onOpenAlbum == onOpenAlbum &&
      other.shuffling == shuffling &&
      other.switching == switching &&
      other.onToggleShuffle == onToggleShuffle;

  @override
  int get hashCode => Object.hash(label, album, onOpenAlbum, shuffling, switching, onToggleShuffle);
}

/// The focus nodes of a [SequenceControlBar], for the D-pad and keyboard.
/// The bar moves focus among them itself, and hands it to [onLeaveUp] past
/// its top row.
class SequenceBarFocus {
  SequenceBarFocus({required this.onLeaveUp});

  final VoidCallback onLeaveUp;

  final previous = FocusNode(debugLabel: 'sequence_bar_previous');
  final playPause = FocusNode(debugLabel: 'sequence_bar_play_pause');
  final next = FocusNode(debugLabel: 'sequence_bar_next');
  final album = FocusNode(debugLabel: 'sequence_bar_album');
  final shuffle = FocusNode(debugLabel: 'sequence_bar_shuffle');

  List<FocusNode> get _nodes => [previous, playPause, next, album, shuffle];

  bool get hasFocus => _nodes.any((node) => node.hasFocus);

  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
  }
}

/// The compact bar a sequence of photos and clips shows at the bottom: what
/// it goes through with the switches between shuffle and album ([mode]), an
/// optional seek row, and previous, play/pause and next.
///
/// It knows nothing of the player or the photo viewer. It is given the
/// sequence's state and what each control does, so both build the same bar.
class SequenceControlBar extends StatelessWidget {
  const SequenceControlBar({
    super.key,
    required this.playing,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.seek,
    this.mode,
    this.showPlayPause = true,
    this.focus,
  });

  /// Whether the sequence is playing. The middle button offers the opposite.
  final bool playing;

  /// Null disables the middle button.
  final VoidCallback? onPlayPause;

  /// Moves to the item before. Null when there is none: the button stays in
  /// its place, disabled, so the others never shift.
  final VoidCallback? onPrevious;

  /// Moves to the item after. Null when there is none, as for [onPrevious].
  final VoidCallback? onNext;

  /// Shown right above the buttons, such as a clip's timeline.
  final Widget? seek;

  /// The row above everything else, when the sequence names what it goes
  /// through.
  final SequenceMode? mode;

  /// False for a sequence that only moves by hand, which has nothing to play.
  final bool showPlayPause;

  /// Makes the controls reachable with the D-pad. Without it they take no
  /// focus at all, as on the touch controls of the player.
  final SequenceBarFocus? focus;

  static const _stepIconSize = 28.0;
  static const _playIconSize = 36.0;

  /// On a phone in landscape, where a clip's three rows would take over a
  /// third of the height, the mode row and the buttons share one row.
  static bool _oneRow(BuildContext context) =>
      PlatformDetector.isPhone(context) && MediaQuery.orientationOf(context) == Orientation.landscape;

  @override
  Widget build(BuildContext context) {
    final mode = this.mode;
    final oneRow = mode != null && _oneRow(context);
    final Widget bar;
    if (mode == null) {
      bar = Column(mainAxisSize: MainAxisSize.min, children: [?seek, _buildButtons()]);
    } else if (oneRow) {
      bar = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?seek,
          Row(
            children: [
              Expanded(child: _buildLabel(context, mode)),
              const SizedBox(width: 8),
              _buildButtons(),
              const SizedBox(width: 8),
              Expanded(
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: _buildSwitches(mode)),
              ),
            ],
          ),
        ],
      );
    } else {
      bar = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(child: _buildLabel(context, mode)),
                ..._buildSwitches(mode),
              ],
            ),
          ),
          ?seek,
          _buildButtons(),
        ],
      );
    }
    final focus = this.focus;
    if (focus == null) return ExcludeFocus(child: bar);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _handleKey(event, focus, oneRow: oneRow),
      child: bar,
    );
  }

  /// The rows of the bar, from the top, with the controls that can take
  /// focus in each, in the order they are drawn.
  List<List<FocusNode>> _focusRows(SequenceBarFocus focus, {required bool oneRow}) {
    final switches = [if (_offersAlbum) focus.album, if (mode?.onToggleShuffle != null) focus.shuffle];
    final buttons = [focus.previous, if (showPlayPause) focus.playPause, focus.next];
    final rows = oneRow ? [buttons + switches] : [switches, buttons];
    return rows.where((row) => row.isNotEmpty).toList();
  }

  bool get _offersAlbum => mode?.album != null && mode?.onOpenAlbum != null;

  KeyEventResult _handleKey(KeyEvent event, SequenceBarFocus focus, {required bool oneRow}) {
    final key = event.logicalKey;
    if (!key.isDpadDirection) return KeyEventResult.ignored;
    final rows = _focusRows(focus, oneRow: oneRow);
    final row = rows.indexWhere((nodes) => nodes.any((node) => node.hasFocus));
    if (row < 0) return KeyEventResult.ignored;
    if (!event.isActionable) return KeyEventResult.handled;
    final nodes = rows[row];
    final at = nodes.indexWhere((node) => node.hasFocus);
    if (key == LogicalKeyboardKey.arrowLeft && at > 0) nodes[at - 1].requestFocus();
    if (key == LogicalKeyboardKey.arrowRight && at < nodes.length - 1) nodes[at + 1].requestFocus();
    if (key == LogicalKeyboardKey.arrowUp) row > 0 ? rows[row - 1].last.requestFocus() : focus.onLeaveUp();
    if (key == LogicalKeyboardKey.arrowDown && row < rows.length - 1) {
      final below = rows[row + 1];
      below[below.length ~/ 2].requestFocus();
    }
    return KeyEventResult.handled;
  }

  Widget _buildLabel(BuildContext context, SequenceMode mode) {
    return Text(
      mode.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white),
    );
  }

  /// The album button and the shuffle toggle, where the sequence has them.
  List<Widget> _buildSwitches(SequenceMode mode) {
    final album = mode.album;
    final onOpenAlbum = mode.onOpenAlbum;
    final onToggleShuffle = mode.onToggleShuffle;
    return [
      if (album != null && onOpenAlbum != null) ...[
        const SizedBox(width: 8),
        Flexible(
          child: _AlbumButton(album: album, switching: mode.switching, onPressed: onOpenAlbum, focusNode: focus?.album),
        ),
      ],
      if (onToggleShuffle != null) ...[
        const SizedBox(width: 8),
        _ShuffleToggle(
          shuffling: mode.shuffling,
          // With no album to switch to, there is nothing for it to do.
          enabled: !mode.shuffling || _offersAlbum,
          onPressed: onToggleShuffle,
          focusNode: focus?.shuffle,
        ),
      ],
    ];
  }

  Widget _buildButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _button(
          icon: Symbols.skip_previous_rounded,
          label: t.tooltips.previousItem,
          size: _stepIconSize,
          onPressed: onPrevious,
          focusNode: focus?.previous,
        ),
        if (showPlayPause) ...[
          const SizedBox(width: 16),
          _button(
            icon: playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
            label: playing ? t.videoControls.pauseButton : t.videoControls.playButton,
            size: _playIconSize,
            onPressed: onPlayPause,
            focusNode: focus?.playPause,
          ),
        ],
        const SizedBox(width: 16),
        _button(
          icon: Symbols.skip_next_rounded,
          label: t.tooltips.nextItem,
          size: _stepIconSize,
          onPressed: onNext,
          focusNode: focus?.next,
        ),
      ],
    );
  }

  Widget _button({
    required IconData icon,
    required String label,
    required double size,
    required VoidCallback? onPressed,
    required FocusNode? focusNode,
  }) {
    return VideoControlButton(
      icon: icon,
      iconSize: size,
      semanticLabel: label,
      color: onPressed == null ? Colors.white54 : Colors.white,
      onPressed: onPressed,
      focusNode: focusNode,
    );
  }
}

/// Switches to the album of the item shown, named on the button.
class _AlbumButton extends StatelessWidget {
  const _AlbumButton({required this.album, required this.switching, required this.onPressed, this.focusNode});

  final String album;
  final bool switching;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: FocusableButton(
        focusNode: focusNode,
        onPressed: onPressed,
        autoScroll: false,
        child: Tooltip(
          message: t.tooltips.playPhotoAlbum,
          child: TextButton.icon(
            onPressed: onPressed,
            style: TextButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
            icon: switching
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const AppIcon(Symbols.photo_album_rounded),
            label: Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}

/// On while the shuffle plays; off plays the album of the item shown, in
/// order, and on again goes back to the shuffle.
class _ShuffleToggle extends StatelessWidget {
  const _ShuffleToggle({required this.shuffling, required this.enabled, required this.onPressed, this.focusNode});

  final bool shuffling;
  final bool enabled;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return FocusableButton(
      focusNode: focusNode,
      // Stays focusable when there is no album to switch to, so focus does
      // not drop out of the bar as the items change.
      onPressed: onPressed,
      autoScroll: false,
      child: IconButton(
        onPressed: enabled ? onPressed : null,
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
}
