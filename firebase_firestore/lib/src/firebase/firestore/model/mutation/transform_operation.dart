// File created by
// Lung Razvan <long1eu>
// on 17/09/2018

import 'package:firebase_firestore/src/firebase/firestore/model/value/field_value.dart';
import 'package:firebase_firestore/src/firebase/timestamp.dart';

/// A transform within a [TransformMutation].
abstract class TransformOperation {
  /// Computes the local transform result against the provided [previousValue],
  /// optionally using the provided [localWriteTime].
  FieldValue applyToLocalView(
      FieldValue previousValue, Timestamp localWriteTime);

  /// Computes a final transform result after the transform has been
  /// acknowledged by the server, potentially using the server-provided
  /// [transformResult].
  FieldValue applyToRemoteDocument(
      FieldValue previousValue, FieldValue transformResult);
}
