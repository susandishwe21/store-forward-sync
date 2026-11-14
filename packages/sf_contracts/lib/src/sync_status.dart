//Sync status of a record.
enum SyncStatus {
  //Saved on the phone
  queued,
  //Sent to the server
  sending,
  //Received by the server
  confirmed,
}

//Sync events that can be sent to the server.
enum SyncEvent {
  //Sync engine picked this record to send.
  batchBuilt,
  //Server replied: "applied"
  ackApplied,
}

//
SyncStatus? transition(SyncStatus? from, SyncEvent event) {
  return switch ((from, event)) {
    (SyncStatus.queued, SyncEvent.batchBuilt) => SyncStatus.sending,
    (SyncStatus.sending, SyncEvent.ackApplied) => SyncStatus.confirmed,
    _ => null,
  };
}
