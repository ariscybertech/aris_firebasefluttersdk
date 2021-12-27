// File created by
// Lung Razvan <long1eu>
// on 26/09/2018

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_firestore/src/firebase/firestore/field_path.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/field_path.dart'
    as model;
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/field_mask.dart';

/// An options object that configures the behavior of set() calls. By providing
/// one of the [SetOptions] objects returned by [merge], [mergeField] and
/// [mergeFieldPaths], the set() calls in [DocumentReference], [WriteBatch] and
/// [Transaction] can be configured to perform granular merges instead of
/// overwriting the target documents in their entirety.
@publicApi
class SetOptions {
  static const SetOptions overwrite = SetOptions._overwrite();

  /// Changes the behavior of set() calls to only replace the values specified
  /// in its data argument. Fields omitted from the set() call will remain
  /// untouched.
  static const SetOptions mergeAllFields = SetOptions._mergeAll();

  final bool merge;
  final FieldMask fieldMask;

  const SetOptions._(this.merge, this.fieldMask)
      : assert(fieldMask != null && merge,
            'Cannot specify a fieldMask for non-merge sets()');

  const SetOptions._overwrite()
      : merge = false,
        fieldMask = null;

  const SetOptions._mergeAll()
      : merge = true,
        fieldMask = null;

  /// Changes the behavior of set() calls to only replace the fields under
  /// [fieldPaths]. Any field that is not specified in [fieldPaths] is ignored
  /// and remains untouched.
  ///
  /// * It is an error to pass a [SetOptions] object to a set() call that is
  /// missing a value for any of the fields specified here.
  ///
  /// [fields] the list of fields to merge. Fields can contain dots to reference
  /// nested fields within the document.
  @publicApi
  factory SetOptions.mergeFields(List<String> fields) {
    final List<model.FieldPath> fieldPaths = <model.FieldPath>[];
    for (String field in fields) {
      fieldPaths.add(FieldPath.fromDotSeparatedPath(field).internalPath);
    }

    return SetOptions._(true, FieldMask(fieldPaths));
  }

  /// Changes the behavior of set() calls to only replace the fields under
  /// [fieldPaths]. Any field that is not specified in [fieldPaths] is ignored
  /// and remains untouched.
  ///
  /// * It is an error to pass a SetOptions object to a set() call that is
  /// missing a value for any of the fields specified here in its to data
  /// argument.
  @publicApi
  factory SetOptions.mergeFieldPaths(List<FieldPath> fields) {
    final List<model.FieldPath> fieldPaths = <model.FieldPath>[];

    for (FieldPath field in fields) {
      fieldPaths.add(field.internalPath);
    }

    return SetOptions._(true, FieldMask(fieldPaths));
  }
}
