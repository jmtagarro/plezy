import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/immersive_mode_guard.dart';

/// The engine posts `SystemChrome.systemUIChange` when Android re-shows the
/// system bars (a fold/unfold keeps the activity resumed, so nothing else
/// re-applies the requested mode). The guard answers it only while a player
/// owns immersive mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    ImmersiveModeGuard.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> systemShowsOverlays() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(const MethodCall('SystemChrome.systemUIChange', [true])),
      (_) {},
    );
  }

  Iterable<MethodCall> immersiveRequests() => platformCalls.where(
    (call) => call.method == 'SystemChrome.setEnabledSystemUIMode' && call.arguments == 'SystemUiMode.immersiveSticky',
  );

  test('re-requests immersive mode while owned, not after release', () async {
    final owner = Object();
    ImmersiveModeGuard.acquire(owner);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1));

    ImmersiveModeGuard.release(owner);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1));
  });

  test('bars staying hidden is not a re-show', () async {
    ImmersiveModeGuard.acquire(Object());
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(const MethodCall('SystemChrome.systemUIChange', [false])),
      (_) {},
    );
    expect(immersiveRequests(), isEmpty);
  });

  test('a predecessor releasing after its successor acquired keeps the successor owning', () async {
    final predecessor = Object();
    final successor = Object();
    ImmersiveModeGuard.acquire(predecessor);
    ImmersiveModeGuard.acquire(successor);
    ImmersiveModeGuard.release(predecessor);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1));

    ImmersiveModeGuard.release(successor);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1));
  });

  test('release reports whether the caller still owned immersive mode', () {
    final predecessor = Object();
    final successor = Object();
    ImmersiveModeGuard.acquire(predecessor);
    ImmersiveModeGuard.acquire(successor);

    expect(ImmersiveModeGuard.release(predecessor), isFalse);
    expect(ImmersiveModeGuard.release(successor), isTrue);
    expect(ImmersiveModeGuard.release(successor), isFalse);
  });

  test('a screen opened over another owns immersive mode, then hands it back', () async {
    final viewer = Object();
    final player = Object();
    ImmersiveModeGuard.acquire(viewer);
    ImmersiveModeGuard.acquire(player);

    expect(ImmersiveModeGuard.release(player), isTrue);
    expect(ImmersiveModeGuard.isOwned, isTrue);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1), reason: 'the viewer below keeps the bars hidden');

    expect(ImmersiveModeGuard.release(viewer), isTrue);
    expect(ImmersiveModeGuard.isOwned, isFalse);
    await systemShowsOverlays();
    expect(immersiveRequests(), hasLength(1));
  });

  for (final viewerFirst in [true, false]) {
    test('torn down together, ${viewerFirst ? 'viewer' : 'player'} first, the two leave no owner and one current owner'
        ' releases last', () {
      final viewer = Object();
      final player = Object();
      ImmersiveModeGuard.acquire(viewer);
      ImmersiveModeGuard.acquire(player);

      final first = viewerFirst ? viewer : player;
      final second = viewerFirst ? player : viewer;
      final firstWasCurrent = ImmersiveModeGuard.release(first);
      final restoreAfterFirst = firstWasCurrent && !ImmersiveModeGuard.isOwned;
      final secondWasCurrent = ImmersiveModeGuard.release(second);
      final restoreAfterSecond = secondWasCurrent && !ImmersiveModeGuard.isOwned;

      expect([restoreAfterFirst, restoreAfterSecond], [false, true]);
      expect(ImmersiveModeGuard.isOwned, isFalse);
    });
  }

  test('acquiring again does not stack the same owner twice', () {
    final owner = Object();
    ImmersiveModeGuard.acquire(owner);
    ImmersiveModeGuard.acquire(owner);

    expect(ImmersiveModeGuard.release(owner), isTrue);
    expect(ImmersiveModeGuard.isOwned, isFalse);
  });

  test('registers the native listener once across owners', () async {
    ImmersiveModeGuard.acquire(Object());
    ImmersiveModeGuard.acquire(Object());
    await Future<void>.delayed(Duration.zero);
    expect(platformCalls.where((call) => call.method == 'SystemChrome.setSystemUIChangeListener'), hasLength(1));
  });
}
