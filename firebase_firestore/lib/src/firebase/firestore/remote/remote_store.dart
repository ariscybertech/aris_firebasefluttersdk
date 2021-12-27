// File created by
// Lung Razvan <long1eu>
// on 18/09/2018

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_database_collection/firebase_database_collection.dart';
import 'package:firebase_firestore/src/firebase/firestore/core/online_state.dart';
import 'package:firebase_firestore/src/firebase/firestore/core/transaction.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/local_store.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/query_data.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/query_purpose.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document_key.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation_batch.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation_batch_result.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation_result.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/snapshot_version.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/datastore.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/online_state_tracker.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/remote_event.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/target_change.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/watch_change.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/watch_change_aggregator.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/watch_stream.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/write_stream.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/assert.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/async_queue.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/util.dart';
import 'package:grpc/grpc.dart';

/// [RemoteStore] handles all interaction with the backend through a simple,
/// clean interface. This class is not thread safe and should be only called
/// from the worker [AsyncQueue].
class RemoteStore implements TargetMetadataProvider {
  /// The maximum number of pending writes to allow.
  /// TODO: Negotiate this value with the backend.
  static const int _maxPendingWrites = 10;

  /// The log tag to use for this class.
  static const String _tag = 'RemoteStore';

  final RemoteStoreCallback _remoteStoreCallback;

  final LocalStore _localStore;

  final Datastore _datastore;

  /// A mapping of watched targets that the client cares about tracking and the
  /// user has explicitly called a 'listen' for this target.
  ///
  /// * These targets may or may not have been sent to or acknowledged by the
  /// server. On re-establishing the listen stream, these targets should be sent
  /// to the server. The targets removed with unlistens are removed eagerly
  /// without waiting for confirmation from the listen stream.
  final Map<int, QueryData> _listenTargets;

  final OnlineStateTracker _onlineStateTracker;

  WatchStream _watchStream;

  WriteStream _writeStream;

  bool _networkEnabled = false;

  WatchChangeAggregator _watchChangeAggregator;

  /// A list of up to [_maxPendingWrites] writes that we have fetched from the
  /// [LocalStore] via [fillWritePipeline] and have or will send to the write
  /// stream.
  ///
  /// * Whenever [_writePipeline.length] > 0 the [RemoteStore] will attempt to
  /// start or restart the write stream. When the stream is established the
  /// writes in the pipeline will be sent in order.
  ///
  /// * Writes remain in [_writePipeline] until they are acknowledged by the
  /// backend and thus will automatically be re-sent if the stream is
  /// interrupted / restarted before they're acknowledged.
  ///
  /// * Write responses from the backend are linked to their originating request
  /// purely based on order, and so we can just poll() writes from the front of
  /// the [_writePipeline] as we receive responses.
  final Queue<MutationBatch> _writePipeline;

  RemoteStore(this._remoteStoreCallback, this._localStore, this._datastore,
      AsyncQueue workerQueue)
      : _listenTargets = <int, QueryData>{},
        _writePipeline = Queue<MutationBatch>(),
        _onlineStateTracker = OnlineStateTracker(
          workerQueue,
          _remoteStoreCallback.handleOnlineStateChange,
        ) {
    // Create new streams (but note they're not started yet).
    _watchStream = _datastore.createWatchStream(WatchStreamCallback(
      onOpen: _handleWatchStreamOpen,
      onClose: _handleWatchStreamClose,
      onWatchChange: _handleWatchChange,
    ));

    _writeStream = _datastore.createWriteStream(WriteStreamCallback(
      // we use this so that [_writeStream] is not null when called
      onOpen: () => _writeStream.writeHandshake(),
      onClose: _handleWriteStreamClose,
      onHandshakeComplete: _handleWriteStreamHandshakeComplete,
      onWriteResponse: _handleWriteStreamMutationResults,
    ));
  }

  RemoteStore._(
    this._remoteStoreCallback,
    this._localStore,
    this._datastore,
    this._listenTargets,
    this._onlineStateTracker,
    this._watchStream,
    this._writeStream,
    this._writePipeline,
  );

  /// Re-enables the network. Only to be called as the counterpart to
  /// [disableNetwork].
  Future<void> enableNetwork() async {
    _networkEnabled = true;

    if (_canUseNetwork()) {
      _writeStream.lastStreamToken = _localStore.lastStreamToken;

      if (_shouldStartWatchStream()) {
        await _startWatchStream();
      } else {
        await _onlineStateTracker.updateState(OnlineState.unknown);
      }

      // This will start the write stream if necessary.
      await fillWritePipeline();
    }
  }

  /// Temporarily disables the network. The network can be re-enabled using
  /// [enableNetwork].
  Future<void> disableNetwork() async {
    _networkEnabled = false;
    await _disableNetworkInternal();

    // Set the OnlineState to OFFLINE so get()s return from cache, etc.
    await _onlineStateTracker.updateState(OnlineState.offline);
  }

  Future<void> _disableNetworkInternal() async {
    await _watchStream.stop();
    await _writeStream.stop();

    if (_writePipeline.isNotEmpty) {
      Log.d(_tag,
          'Stopping write stream with ${_writePipeline.length} pending writes');
      _writePipeline.clear();
    }

    _cleanUpWatchStreamState();
  }

  /// Starts up the remote store, creating streams, restoring state from
  /// [LocalStore], etc. This should called before using any other API endpoints
  /// in this class.
  Future<void> start() async {
    // For now, all setup is handled by enableNetwork(). We might expand on this
    // in the future.
    await enableNetwork();
  }

  /// Shuts down the remote store, tearing down connections and otherwise
  /// cleaning up. This is not reversible and renders the Remote Store unusable.
  Future<void> shutdown() async {
    Log.d(_tag, 'Shutting down');
    // For now, all shutdown logic is handled by disableNetworkInternal(). We
    // might expand on this in the future.
    _networkEnabled = false;
    await _disableNetworkInternal();
    // Set the OnlineState to UNKNOWN (rather than OFFLINE) to avoid potentially
    // triggering spurious listener events with cached data, etc.
    await _onlineStateTracker.updateState(OnlineState.unknown);
  }

  /// Tells the [RemoteStore] that the currently authenticated user has changed.
  ///
  /// * In response the remote store tears down streams and clears up any
  /// tracked operations that should not persist across users. Restarts the
  /// streams if appropriate.
  Future<void> handleCredentialChange() async {
    // If the network has been explicitly disabled, make sure we don't
    // accidentally re-enable it.
    if (_canUseNetwork()) {
      // Tear down and re-create our network streams. This will ensure we get a
      // fresh auth token for the new user and re-fill the write pipeline with
      // new mutations from the [LocalStore] (since mutations are per-user).
      Log.d(_tag, 'Restarting streams for new credential.');
      _networkEnabled = false;
      await _disableNetworkInternal();
      await _onlineStateTracker.updateState(OnlineState.unknown);
      await enableNetwork();
    }
  }

  // Watch Stream

  /// Listens to the target identified by the given [QueryData]. */
  Future<void> listen(QueryData queryData) async {
    final int targetId = queryData.targetId;
    Assert.hardAssert(!_listenTargets.containsKey(targetId),
        'listen called with duplicate target ID: $targetId');

    _listenTargets[targetId] = queryData;

    if (_shouldStartWatchStream()) {
      await _startWatchStream();
    } else if (_watchStream.isOpen) {
      _sendWatchRequest(queryData);
    }
  }

  void _sendWatchRequest(QueryData queryData) {
    _watchChangeAggregator.recordPendingTargetRequest(queryData.targetId);
    _watchStream.watchQuery(queryData);
  }

  /// Stops listening to the target with the given target ID.
  ///
  /// * If this is called with the last active targetId, the watch stream enters
  /// idle mode and will be torn down after one minute of inactivity.
  Future<void> stopListening(int targetId) async {
    final QueryData queryData = _listenTargets.remove(targetId);
    Assert.hardAssert(queryData != null,
        'stopListening called on target no currently watched: $targetId');

    // The watch stream might not be started if we're in a disconnected state
    if (_watchStream.isOpen) {
      _sendUnwatchRequest(targetId);
    }

    if (_listenTargets.isEmpty) {
      if (_watchStream.isOpen) {
        _watchStream.markIdle();
      } else if (_canUseNetwork()) {
        // Revert to [OnlineState.unknown] if the watch stream is not open and
        // we have no listeners, since without any listens to send we cannot
        // confirm if the stream is healthy and upgrade to [OnlineState.online].
        await _onlineStateTracker.updateState(OnlineState.unknown);
      }
    }
  }

  void _sendUnwatchRequest(int targetId) {
    _watchChangeAggregator.recordPendingTargetRequest(targetId);
    _watchStream.unwatchTarget(targetId);
  }

  /// Returns true if the network is enabled, the write stream has not yet been
  /// started and there are pending writes.
  bool _shouldStartWriteStream() {
    return _canUseNetwork() &&
        !_writeStream.isStarted &&
        _writePipeline.isNotEmpty;
  }

  /// Returns true if the network is enabled, the watch stream has not yet been
  /// started and there are active watch targets.
  bool _shouldStartWatchStream() {
    return _canUseNetwork() &&
        !_watchStream.isStarted &&
        _listenTargets.isNotEmpty;
  }

  void _cleanUpWatchStreamState() {
    // If the connection is closed then we'll never get a snapshot version for
    // the accumulated changes and so we'll never be able to complete the batch.
    // When we start up again the server is going to resend these changes
    // anyway, so just toss the accumulated state.
    _watchChangeAggregator = null;
  }

  Future<void> _startWatchStream() async {
    Assert.hardAssert(_shouldStartWatchStream(),
        'startWatchStream() called when shouldStartWatchStream() is false.');
    _watchChangeAggregator = WatchChangeAggregator(this);
    await _watchStream.start();
    await _onlineStateTracker.handleWatchStreamStart();
  }

  Future<void> _handleWatchStreamOpen() async {
    // Restore any existing watches.
    _listenTargets.values.forEach(_sendWatchRequest);
  }

  Future<void> _handleWatchChange(
      SnapshotVersion snapshotVersion, WatchChange watchChange) async {
    // Mark the connection as ONLINE because we got a message from the server.
    await _onlineStateTracker.updateState(OnlineState.online);

    Assert.hardAssert(
        (_watchStream != null) && (_watchChangeAggregator != null),
        'WatchStream and WatchStreamAggregator should both be non-null');

    final WatchChangeWatchTargetChange watchTargetChange =
        watchChange is WatchChangeWatchTargetChange ? watchChange : null;

    if (watchTargetChange != null &&
        watchTargetChange.changeType == WatchTargetChangeType.removed &&
        watchTargetChange.cause != null) {
      // There was an error on a target, don't wait for a consistent snapshot to
      // raise events
      await _processTargetError(watchTargetChange);
    } else {
      if (watchChange is WatchChangeDocumentChange) {
        _watchChangeAggregator.handleDocumentChange(watchChange);
      } else if (watchChange is WatchChangeExistenceFilterWatchChange) {
        _watchChangeAggregator.handleExistenceFilter(watchChange);
      } else if (watchChange is WatchChangeWatchTargetChange) {
        _watchChangeAggregator.handleTargetChange(watchChange);
      } else {
        Assert.fail(
            'Expected watchChange to be an instance of WatchTargetChange');
      }

      if (snapshotVersion != SnapshotVersion.none) {
        final SnapshotVersion lastRemoteSnapshotVersion =
            _localStore.getLastRemoteSnapshotVersion();

        if (snapshotVersion.compareTo(lastRemoteSnapshotVersion) >= 0) {
          // We have received a target change with a global snapshot if the
          // snapshot version is not equal to SnapshotVersion.MIN.
          await _raiseWatchSnapshot(snapshotVersion);
        }
      }
    }
  }

  Future<void> _handleWatchStreamClose(GrpcError status) async {
    if (status.code == StatusCode.ok) {
      // Graceful stop (due to stop() or idle timeout). Make sure that's
      // desirable.
      Assert.hardAssert(!_shouldStartWatchStream(),
          'Watch stream was stopped gracefully while still needed.');
    }

    _cleanUpWatchStreamState();

    // If we still need the watch stream, retry the connection.
    if (_shouldStartWatchStream()) {
      await _onlineStateTracker.handleWatchStreamFailure(status);

      await _startWatchStream();
    } else {
      // We don't need to restart the watch stream because there are no active
      // targets. The online state is set to unknown because there is no active
      // attempt at establishing a connection.
      await _onlineStateTracker.updateState(OnlineState.unknown);
    }
  }

  bool _canUseNetwork() {
    // PORTING NOTE: This method exists mostly because web also has to take into
    // account primary vs. secondary state.
    return _networkEnabled;
  }

  /// Takes a batch of changes from the [Datastore], repackages them as a
  /// [RemoteEvent], and passes that on to the listener, which is typically the
  /// [SyncEngine].
  Future<void> _raiseWatchSnapshot(SnapshotVersion snapshotVersion) async {
    Assert.hardAssert(snapshotVersion != SnapshotVersion.none,
        'Can\'t raise event for unknown SnapshotVersion');
    final RemoteEvent remoteEvent =
        _watchChangeAggregator.createRemoteEvent(snapshotVersion);

    // Update in-memory resume tokens. [LocalStore] will update the persistent
    // view of these when applying the completed [RemoteEvent].
    for (MapEntry<int, TargetChange> entry
        in remoteEvent.targetChanges.entries) {
      final TargetChange targetChange = entry.value;
      if (targetChange.resumeToken.isNotEmpty) {
        final int targetId = entry.key;
        final QueryData queryData = _listenTargets[targetId];
        // A watched target might have been removed already.
        if (queryData != null) {
          _listenTargets[targetId] = queryData.copyWith(
            snapshotVersion: snapshotVersion,
            resumeToken: targetChange.resumeToken,
            sequenceNumber: queryData.sequenceNumber,
          );
        }
      }
    }

    // Re-establish listens for the targets that have been invalidated by
    // existence filter mismatches.
    for (int targetId in remoteEvent.targetMismatches) {
      final QueryData queryData = _listenTargets[targetId];
      // A watched target might have been removed already.
      if (queryData != null) {
        // Clear the resume token for the query, since we're in a known mismatch
        // state.
        _listenTargets[targetId] = queryData.copyWith(
          snapshotVersion: queryData.snapshotVersion,
          sequenceNumber: queryData.sequenceNumber,
          resumeToken: Uint8List.fromList(<int>[]),
        );

        // Cause a hard reset by unwatching and rewatching immediately, but
        // deliberately don't send a resume token so that we get a full update.
        _sendUnwatchRequest(targetId);

        // Mark the query we send as being on behalf of an existence filter
        // mismatch, but don't actually retain that in [listenTargets]. This
        // ensures that we flag the first re-listen this way without impacting
        // future listens of this target (that might happen e.g. on reconnect).
        final QueryData requestQueryData = QueryData.init(
          queryData.query,
          targetId,
          queryData.sequenceNumber,
          QueryPurpose.existenceFilterMismatch,
        );
        _sendWatchRequest(requestQueryData);
      }
    }

    // Finally raise remote event
    await _remoteStoreCallback.handleRemoteEvent(remoteEvent);
  }

  Future<void> _processTargetError(
      WatchChangeWatchTargetChange targetChange) async {
    Assert.hardAssert(
        targetChange.cause != null, 'Processing target error without a cause');
    for (int targetId in targetChange.targetIds) {
      // Ignore targets that have been removed already.
      if (_listenTargets.containsKey(targetId)) {
        _listenTargets.remove(targetId);
        _watchChangeAggregator.removeTarget(targetId);
        await _remoteStoreCallback.handleRejectedListen(
            targetId, targetChange.cause);
      }
    }
  }

  // Write Stream

  /// Attempts to fill our write pipeline with writes from the [LocalStore].
  ///
  /// * Called internally to bootstrap or refill the write pipeline by
  /// [SyncEngine] whenever there are new mutations to process.
  ///
  /// * Starts the write stream if necessary.
  Future<void> fillWritePipeline() async {
    int lastBatchIdRetrieved = _writePipeline.isEmpty
        ? MutationBatch.unknown
        : _writePipeline.last.batchId;

    while (_canAddToWritePipeline()) {
      final MutationBatch batch =
          await _localStore.getNextMutationBatch(lastBatchIdRetrieved);

      if (batch == null) {
        if (_writePipeline.isEmpty) {
          _writeStream.markIdle();
        }
        break;
      }
      _addToWritePipeline(batch);
      lastBatchIdRetrieved = batch.batchId;
    }

    if (_shouldStartWriteStream()) {
      await _startWriteStream();
    }
  }

  /// Returns true if we can add to the write pipeline (i.e. it is not full and
  /// the network is enabled).
  bool _canAddToWritePipeline() {
    return _canUseNetwork() && _writePipeline.length < _maxPendingWrites;
  }

  /// Queues additional writes to be sent to the write stream, sending them
  /// immediately if the write stream is established.
  void _addToWritePipeline(MutationBatch mutationBatch) {
    Assert.hardAssert(_canAddToWritePipeline(),
        'addToWritePipeline called when pipeline is full');

    _writePipeline.add(mutationBatch);

    if (_writeStream.isOpen && _writeStream.isHandshakeComplete) {
      _writeStream.writeMutations(mutationBatch.mutations);
    }
  }

  Future<void> _startWriteStream() async {
    Assert.hardAssert(_shouldStartWriteStream(),
        'startWriteStream() called when shouldStartWriteStream() is false.');
    await _writeStream.start();
  }

  /// Handles a successful handshake response from the server, which is our cue
  /// to send any pending writes.
  Future<void> _handleWriteStreamHandshakeComplete() async {
    // Record the stream token.
    await _localStore.setLastStreamToken(_writeStream.lastStreamToken);

    // Send the write pipeline now that stream is established.
    for (MutationBatch batch in _writePipeline) {
      _writeStream.writeMutations(batch.mutations);
    }
  }

  /// Handles a successful [StreamingWriteResponse] from the server that
  /// contains a mutation result.
  Future<void> _handleWriteStreamMutationResults(
      SnapshotVersion commitVersion, List<MutationResult> results) async {
    // This is a response to a write containing mutations and should be
    // correlated to the first write in our write pipeline.
    final MutationBatch batch = _writePipeline.removeFirst();

    final MutationBatchResult mutationBatchResult = MutationBatchResult.create(
        batch, commitVersion, results, _writeStream.lastStreamToken);
    await _remoteStoreCallback.handleSuccessfulWrite(mutationBatchResult);

    // It's possible that with the completion of this mutation another slot has
    // freed up.
    await fillWritePipeline();
  }

  Future<void> _handleWriteStreamClose(GrpcError status) async {
    if (status.code == StatusCode.ok) {
      // Graceful stop (due to stop() or idle timeout). Make sure that's
      // desirable.
      Assert.hardAssert(!_shouldStartWatchStream(),
          'Write stream was stopped gracefully while still needed.');
    }

    // If the write stream closed due to an error, invoke the error callbacks
    // if there are pending writes.
    if (status.code != StatusCode.ok && _writePipeline.isNotEmpty) {
      // TODO: handle UNAUTHENTICATED status, see go/firestore-client-errors
      if (_writeStream.isHandshakeComplete) {
        // This error affects the actual writes
        await _handleWriteError(status);
      } else {
        // If there was an error before the handshake has finished, it's
        // possible that the server is unable to process the stream token we're
        // sending. (Perhaps it's too old?)
        await _handleWriteHandshakeError(status);
      }
    }

    // The write stream may have already been restarted by refilling the write
    // pipeline for failed writes. In that case, we don't want to start the
    // write stream again.
    if (_shouldStartWriteStream()) {
      await _startWriteStream();
    }
  }

  Future<void> _handleWriteHandshakeError(GrpcError status) async {
    Assert.hardAssert(
        status.code != StatusCode.ok, 'Handling write error with status OK.');
    // Reset the token if it's a permanent error or the error code is ABORTED,
    // signaling the write stream is no longer valid.
    if (Datastore.isPermanentWriteError(status) ||
        status.code == StatusCode.aborted) {
      final String token = toDebugString(_writeStream.lastStreamToken);
      Log.d(
          _tag,
          'RemoteStore error before completed handshake; resetting stream token'
          ' $token: $status');
      _writeStream.lastStreamToken = WriteStream.emptyStreamToken;
      await _localStore.setLastStreamToken(WriteStream.emptyStreamToken);
    }
  }

  Future<void> _handleWriteError(GrpcError status) async {
    Assert.hardAssert(
        status.code != StatusCode.ok, 'Handling write error with status OK.');
    // Only handle permanent error, if it's transient just let the retry logic
    // kick in.
    if (Datastore.isPermanentWriteError(status)) {
      // If this was a permanent error, the request itself was the problem so
      // it's not going to succeed if we resend it.
      final MutationBatch batch = _writePipeline.removeFirst();

      // In this case it's also unlikely that the server itself is melting down
      // -- this was just a bad request, so inhibit backoff on the next restart
      _writeStream.inhibitBackoff();

      await _remoteStoreCallback.handleRejectedWrite(batch.batchId, status);

      // It's possible that with the completion of this mutation another slot
      // has freed up.
      await fillWritePipeline();
    }
  }

  Transaction createTransaction() => Transaction(_datastore);

  @override
  QueryData Function(int targetId) get getQueryDataForTarget =>
      (int targetId) => _listenTargets[targetId];

  @override
  ImmutableSortedSet<DocumentKey> Function(int targetId)
      get getRemoteKeysForTarget => (int targetId) {
            return _remoteStoreCallback.getRemoteKeysForTarget(targetId);
          };
}

/// A callback interface for events from RemoteStore.
abstract class RemoteStoreCallback {
  /// Handle a remote event to the sync engine, notifying any views of the
  /// changes, and releasing any pending mutation batches that would become
  /// visible because of the snapshot version the remote event contains.
  Future<void> handleRemoteEvent(RemoteEvent remoteEvent);

  /// Reject the listen for the given [targetId]. This can be triggered by the
  /// backend for any active target.
  ///
  /// The [targetId] corresponding to a listen initiated via listen(). [error]
  /// is a description of the condition that has forced the rejection. Nearly
  /// always this will be an indication that the user is no longer authorized to
  /// see the data matching the target.
  Future<void> handleRejectedListen(int targetId, GrpcError error);

  /// Applies the result of a successful write of a mutation batch to the sync
  /// engine, emitting snapshots in any views that the mutation applies to, and
  /// removing the batch from the mutation queue.
  Future<void> handleSuccessfulWrite(MutationBatchResult successfulWrite);

  /// Rejects the batch, removing the batch from the mutation queue, recomputing
  /// the local view of any documents affected by the batch and then, emitting
  /// snapshots with the reverted value.
  Future<void> handleRejectedWrite(int batchId, GrpcError error);

  /// Called whenever the online state of the client changes. This is based on
  /// the watch stream for now.
  Future<void> handleOnlineStateChange(OnlineState onlineState);

  /// Returns the set of remote document keys for the given target ID. This list
  /// includes the documents that were assigned to the target when we received
  /// the last snapshot.
  ///
  /// * Returns an empty set of document keys for unknown targets.
  ImmutableSortedSet<DocumentKey> Function(int targetId)
      get getRemoteKeysForTarget;
}
