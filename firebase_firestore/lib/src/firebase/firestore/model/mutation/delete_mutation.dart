// File created by
// Lung Razvan <long1eu>
// on 17/09/2018

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document_key.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/maybe_document.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation_result.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/precondition.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/no_document.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/snapshot_version.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/assert.dart';
import 'package:firebase_firestore/src/firebase/timestamp.dart';

/// Represents a Delete operation
class DeleteMutation extends Mutation {
  const DeleteMutation(DocumentKey key, Precondition precondition)
      : super(key, precondition);

  @override
  MaybeDocument applyToRemoteDocument(
      MaybeDocument maybeDoc, MutationResult mutationResult) {
    verifyKeyMatches(maybeDoc);

    Assert.hardAssert(mutationResult.transformResults == null,
        'Transform results received by DeleteMutation.');

    // Unlike applyToLocalView, if we're applying a mutation to a remote
    // document the server has accepted the mutation so the precondition must
    // have held.
    return NoDocument(
      key,
      mutationResult.version,
      /*hasCommittedMutations:*/ true,
    );
  }

  @override
  MaybeDocument applyToLocalView(
      MaybeDocument maybeDoc, MaybeDocument baseDoc, Timestamp localWriteTime) {
    verifyKeyMatches(maybeDoc);

    if (!precondition.isValidFor(maybeDoc)) {
      return maybeDoc;
    }

    return NoDocument(
      key,
      SnapshotVersion.none,
      /*hasCommittedMutations:*/ false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeleteMutation &&
          runtimeType == other.runtimeType &&
          hasSameKeyAndPrecondition(other);

  @override
  int get hashCode => keyAndPreconditionHashCode();

  @override
  String toString() {
    return (ToStringHelper(runtimeType)
          ..add('key', key)
          ..add('precondition', precondition))
        .toString();
  }
}
