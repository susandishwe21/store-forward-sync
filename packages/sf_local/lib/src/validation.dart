/// Checks a payload. Returns a list of problems; an empty list means valid.
typedef RecordValidator = List<String> Function(Map<String, Object?> payload);

/// Thrown when a record fails validation. Nothing was saved.
final class ValidationException implements Exception {
  ValidationException(this.entityType, this.problems);

  final String entityType;
  final List<String> problems;

  @override
  String toString() =>
      'ValidationException($entityType): ${problems.join('; ')}';
}

/// The kinds of value a field can hold.
enum FieldType { text, integer, number, boolean }

bool _matches(FieldType type, Object value) => switch (type) {
  FieldType.text => value is String,
  FieldType.integer => value is int,
  FieldType.number => value is num,
  FieldType.boolean => value is bool,
};

/// A ready-made validator: these fields must exist and have these types.
RecordValidator requireFields(Map<String, FieldType> fields) {
  return (payload) {
    final problems = <String>[];
    for (final entry in fields.entries) {
      final value = payload[entry.key];
      if (value == null) {
        problems.add('${entry.key} is required');
      } else if (!_matches(entry.value, value)) {
        problems.add('${entry.key} must be ${entry.value.name}');
      }
    }
    return problems;
  };
}
