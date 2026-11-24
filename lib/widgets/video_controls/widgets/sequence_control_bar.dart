import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../video_control_button.dart';

/// The compact bar a photo sequence shows at the bottom: previous, play/pause
/// and next, with an optional seek row right above them.
///
/// It knows nothing of the player. It is given the sequence's state and what
/// each control does, so any screen that shows the sequence can build it.
class SequenceControlBar extends StatelessWidget {
  const SequenceControlBar({
    super.key,
    required this.playing,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.seek,
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

  static const _stepIconSize = 28.0;
  static const _playIconSize = 36.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?seek,
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _button(
              icon: Symbols.skip_previous_rounded,
              label: t.videoControls.previousButton,
              size: _stepIconSize,
              onPressed: onPrevious,
            ),
            const SizedBox(width: 16),
            _button(
              icon: playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
              label: playing ? t.videoControls.pauseButton : t.videoControls.playButton,
              size: _playIconSize,
              onPressed: onPlayPause,
            ),
            const SizedBox(width: 16),
            _button(
              icon: Symbols.skip_next_rounded,
              label: t.videoControls.nextButton,
              size: _stepIconSize,
              onPressed: onNext,
            ),
          ],
        ),
      ],
    );
  }

  Widget _button({
    required IconData icon,
    required String label,
    required double size,
    required VoidCallback? onPressed,
  }) {
    return VideoControlButton(
      icon: icon,
      iconSize: size,
      semanticLabel: label,
      color: onPressed == null ? Colors.white54 : Colors.white,
      onPressed: onPressed,
    );
  }
}
