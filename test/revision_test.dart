import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/revision.dart';

/// The revision layer is what every SQLite-backed screen listens to. These
/// tests pin the two behaviours that keep launch from flashing: a burst is
/// coalesced, and a user write is still immediate.
void main() {
  test('coalesces a burst of background changes into one revision', () async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    final List<int> seen = <int>[];
    final ProviderSubscription<int> subscription = container.listen<int>(
      dataRevisionProvider,
      (int? previous, int next) => seen.add(next),
    );
    addTearDown(subscription.close);

    final DataRevision revision = container.read(dataRevisionProvider.notifier);
    revision.bump();
    revision.bump();
    revision.bump();

    // Nothing has settled yet.
    expect(seen, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(seen, <int>[1]);
  });

  test('bumpNow is not debounced', () async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    final List<int> seen = <int>[];
    final ProviderSubscription<int> subscription = container.listen<int>(
      dataRevisionProvider,
      (int? previous, int next) => seen.add(next),
    );
    addTearDown(subscription.close);

    container.read(dataRevisionProvider.notifier).bumpNow();
    await Future<void>.delayed(Duration.zero);

    expect(seen, <int>[1]);
  });
}
