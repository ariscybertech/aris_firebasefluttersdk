// File created by
// Lung Razvan <long1eu>
// on 16/09/2018

import 'package:firebase_common/src/annotations.dart';
import 'package:firebase_common/src/errors/firebase_error.dart';

/// Exception thrown when a request to a Firebase service has failed due to a
/// network error. Inspect the device's network connectivity state or retry
/// later to resolve.
@publicApi
class FirebaseNetworkError extends FirebaseError {
  @publicApi
  const FirebaseNetworkError(String message) : super(message);
}
