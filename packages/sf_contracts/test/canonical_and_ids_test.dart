import 'package:sf_contracts/sf_contracts.dart';
import 'package:test/test.dart';

void main() {
  test('key order does not change the canonical form', () {
    expect(canonicalJson({'b': 2, 'a': 1}), canonicalJson({'a': 1, 'b': 2}));
    expect(canonicalJson({'b': 2, 'a': 1}), '{"a":1,"b":2}');
  });

  test('nested maps are sorted too, but list order is kept', () {
    expect(
      canonicalJson({
        'z': {'y': 1, 'x': 2},
        'list': [3, 1, 2],
      }),
      '{"list":[3,1,2],"z":{"x":2,"y":1}}',
    );
  });

  test('fingerprints match a known value (same in every language)', () {
    expect(
      payloadHash({}),
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    );
    expect(
      payloadHash({'title': 'Water level', 'depth_cm': 120}),
      '3096a5e914f711c2e6b58756a2b8751b314d41492be467e153a8b6f436bd4514',
    );
  });

  test('any change in the data changes the fingerprint', () {
    expect(
      payloadHash({'depth_cm': 120}),
      isNot(payloadHash({'depth_cm': 121})),
    );
  });

  test('IDs have the UUIDv7 shape', () {
    final pattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(newUuidV7(), matches(pattern));
  });

  test('IDs made later sort later', () {
    final earlier = newUuidV7(now: DateTime.utc(2026, 1, 1));
    final later = newUuidV7(now: DateTime.utc(2026, 1, 2));
    expect(earlier.compareTo(later), lessThan(0));
  });

  test('1,000 IDs are all different', () {
    final ids = {for (var i = 0; i < 1000; i++) newUuidV7()};
    expect(ids.length, 1000);
  });
}
