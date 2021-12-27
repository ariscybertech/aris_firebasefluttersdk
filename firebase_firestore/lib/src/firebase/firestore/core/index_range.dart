// File created by
// Lung Razvan <long1eu>
// on 20/09/2018
import 'package:firebase_firestore/src/firebase/firestore/model/field_path.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/value/field_value.dart';

/// A range of index field values over which a cursor should iterate. If [start]
/// and [end] are both null, any field value will be considered within range.
class IndexRange {
  /// [FieldPath] to use for the index lookup.
  final FieldPath fieldPath;

  /// the inclusive start position of the index lookup.
  final FieldValue start;

  /// the inclusive end position of the index lookup.
  final FieldValue end;

  IndexRange(this.fieldPath, this.start, this.end);

  IndexRange copyWith({FieldPath fieldPath, FieldValue start, FieldValue end}) {
    return IndexRange(
      fieldPath ?? this.fieldPath,
      start ?? this.start,
      end ?? this.end,
    );
  }
}

class IndexRangeBuilder {
  FieldPath fieldPath;
  FieldValue start;
  FieldValue end;

  IndexRangeBuilder({this.fieldPath, this.start, this.end});

  IndexRange build() => IndexRange(fieldPath, start, end);
}
