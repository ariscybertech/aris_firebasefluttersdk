// File created by
// Lung Razvan <long1eu>
// on 20/10/2018

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_storage/src/network/network_request.dart';

/// Represents a request to update metadata on a GCS blob.
class UpdateMetadataNetworkRequest extends NetworkRequest {
  final Map<String, dynamic> _metadata;

  UpdateMetadataNetworkRequest(Uri gsUri, FirebaseApp app, this._metadata)
      : super(gsUri, app) {
    setCustomHeader('X-HTTP-Method-Override', 'PATCH');
  }

  @override
  String get action => 'PUT';

  @override
  Map<String, dynamic> get outputJson => _metadata;
}
