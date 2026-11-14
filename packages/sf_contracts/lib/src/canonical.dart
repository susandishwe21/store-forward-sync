import 'dart:convert';

import 'package:crypto/crypto.dart';

String canonicalJson(Object? value) => jsonEncode(_sortKeys(value));

/// SHA-256 fingerprint of a string
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// Fingerprint of a payload: canonical JSON first, then SHA-256.
String payloadHash(Object? payload) => sha256Hex(canonicalJson(payload));

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sortKeys(value[k])};
  }
  if (value is List) {
    return [for (final item in value) _sortKeys(item)];
  }
  return value;
}
