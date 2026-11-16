/// What the app knows about the phone's situation right now.
/// (In a Flutter app, plugins like connectivity_plus and battery_plus fill this in.)
final class SyncContext {
  const SyncContext({
    required this.now,
    this.onWifi = false,
    this.charging = false,
  });

  final DateTime now;
  final bool onWifi;
  final bool charging;
}

/// Says whether syncing is allowed in this situation. The app developer chooses it.
typedef SyncPolicy = bool Function(SyncContext context);

/// Sync whenever possible.
bool syncAlways(SyncContext context) => true;

/// Only on Wi-Fi (no mobile data).
bool syncOnWifiOnly(SyncContext context) => context.onWifi;

/// Only while the phone is charging.
bool syncWhileCharging(SyncContext context) => context.charging;

/// Only between two times of day (phone's local time).
/// The window may cross midnight, for example 22:00 to 05:00.
SyncPolicy syncWindow({
  required int fromHour,
  int fromMinute = 0,
  required int toHour,
  int toMinute = 0,
}) {
  final from = fromHour * 60 + fromMinute;
  final to = toHour * 60 + toMinute;
  return (context) {
    final minute = context.now.hour * 60 + context.now.minute;
    return from <= to
        ? (minute >= from && minute < to) // e.g. 01:00–03:00
        : (minute >= from || minute < to); // e.g. 22:00–05:00, crosses midnight
  };
}

/// Allowed only when EVERY policy allows it.
SyncPolicy syncWhenAll(List<SyncPolicy> policies) =>
    (context) => policies.every((policy) => policy(context));
