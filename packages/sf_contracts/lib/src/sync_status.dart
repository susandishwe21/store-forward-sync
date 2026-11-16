//Sync status of a record.
enum SyncStatus {
  queued,
  sending,
  retryScheduled,
  sentUnconfirmed,
  confirmed,
  rejected,
}

//Sync events that can be sent to the server.
enum SyncEvent {
  batchBuilt,
  ackApplied,
  transientError,
  backoffElapsed,
  ambiguousResponse,
  appRestarted,
  statusApplied,
  statusUnknown,
  permanentError,
}

//rules
SyncStatus? transition(SyncStatus? from, SyncEvent event) {
  return switch ((from, event)) {
    (SyncStatus.queued, SyncEvent.batchBuilt) => SyncStatus.sending,
    (SyncStatus.sending, SyncEvent.ackApplied) => SyncStatus.confirmed,
    (SyncStatus.sending, SyncEvent.transientError) => SyncStatus.retryScheduled,
    (SyncStatus.retryScheduled, SyncEvent.backoffElapsed) => SyncStatus.queued,
    (SyncStatus.sending, SyncEvent.ambiguousResponse) =>
      SyncStatus.sentUnconfirmed,
    (SyncStatus.sending, SyncEvent.appRestarted) => SyncStatus.sentUnconfirmed,
    (SyncStatus.sentUnconfirmed, SyncEvent.statusApplied) =>
      SyncStatus.confirmed,
    (SyncStatus.sentUnconfirmed, SyncEvent.statusUnknown) => SyncStatus.queued,
    (SyncStatus.sending, SyncEvent.permanentError) => SyncStatus.rejected,
    _ => null,
  };
}
