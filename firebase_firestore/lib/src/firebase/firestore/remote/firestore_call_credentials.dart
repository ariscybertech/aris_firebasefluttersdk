// File created by
// Lung Razvan <long1eu>
// on 24/09/2018
import 'dart:async';

import 'package:firebase_common/firebase_common.dart';
import 'package:firebase_firestore/src/firebase/firestore/auth/credentials_provider.dart';
import 'package:grpc/grpc.dart';

class FirestoreCallCredentials {
  static const String tag = 'FirestoreCallCredentials';

  static const String _authorizationHeader = 'Authorization';

  final CredentialsProvider credentialsProvider;

  FirestoreCallCredentials(this.credentialsProvider);

  Future<Null> getRequestMetadata(
      Map<String, String> metadata, String uri) async {
    try {
      final String token = await credentialsProvider.token;
      Log.d(tag, 'Successfully fetched token.');
      if (token != null && token.isNotEmpty) {
        metadata[_authorizationHeader] = 'Bearer $token';
      }
    } on FirebaseApiNotAvailableError catch (_) {
      Log.d(tag, 'Firebase Auth API not available, not using authentication.');
    } on FirebaseNoSignedInUserError catch (_) {
      Log.d(tag, 'No user signed in, not using authentication.');
    } catch (e) {
      Log.w(tag, 'Failed to get token: $e.');
      throw GrpcError.unauthenticated(e.toString());
    }
  }
}
