/// Why sending failed. The kind of failure decides what happens to the changes.
sealed class SendFailure implements Exception {
  const SendFailure(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A: The request never reached the server. Safe to simply send again later.
final class NotDelivered extends SendFailure {
  const NotDelivered(super.message);
}

/// B: The request may have reached the server. Ask the server before resending.
final class DeliveryUnknown extends SendFailure {
  const DeliveryUnknown(super.message);
}

/// The server said the request itself is broken (HTTP 400) and applied nothing.
/// Sending the same thing again will not help.
final class RequestRejected extends SendFailure {
  const RequestRejected(super.message);
}
