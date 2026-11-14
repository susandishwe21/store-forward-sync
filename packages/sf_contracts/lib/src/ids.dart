import 'dart:math';

final Random _random = Random.secure();
String newUuidV7({DateTime? now}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final bytes = List<int>.filled(16, 0);
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff; // time, most significant first
  }
  for (var i = 6; i < 16; i++) {
    bytes[i] = _random.nextInt(256); // random part
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // mark as version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // mark the standard variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
