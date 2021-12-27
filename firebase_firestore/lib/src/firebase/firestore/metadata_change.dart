// File created by
// Lung Razvan <long1eu>
// on 18/09/2018

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_firestore/src/firebase/firestore/document_snapshot.dart';
import 'package:firebase_firestore/src/firebase/firestore/query.dart';

/// Indicates whether metadata-only changes (i.e. only
/// [DocumentSnapshot.metadata] or [Query.metadata] changed) should
/// trigger snapshot events.
@publicApi
enum MetadataChanges { exclude, include }
