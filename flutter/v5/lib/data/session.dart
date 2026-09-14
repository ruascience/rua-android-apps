import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'collecting.dart';

/// Who is signed in on this phone.
///
/// The app used to authenticate as ITSELF: one credential compiled into every
/// build, identical on every device. That says nothing about whose wrist the
/// band is on, so the server could not file a reading under a person and every
/// phone could read every participant's data. A session is a PERSON.
///
/// What is stored is the TOKEN the server issued, never the password. A stored
/// password hands over the account to anyone who extracts it; a token expires
/// on its own, can be revoked without changing the password, and identifies
/// the device it was issued to.
///
/// It lives in SharedPreferences — app-private storage, readable on a rooted
/// device. The keystore would be better and is a native dependency this build
/// has not taken on; the token's 90-day expiry and revocability are what carry
/// the risk in the meantime.
class Session {
  Session._();
  static final Session instance = Session._();

  static const _kUser = 'session.username';
  static const _kToken = 'session.token';
  static const _kProfile = 'session.profile_id';
  static const _kRole = 'session.role';
  static const _kName = 'session.display_name';

  String? username;
  String? token;
  String? profileId;
  String? role;
  String? displayName;

  bool get signedIn => (token ?? '').isNotEmpty && (username ?? '').isNotEmpty;
  bool get isAdmin => role == 'admin';

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      username = p.getString(_kUser);
      token = p.getString(_kToken);
      profileId = p.getString(_kProfile);
      role = p.getString(_kRole);
      displayName = p.getString(_kName);
    } catch (e) {
      debugPrint('[AuraV5] session unavailable: $e');
    }
    _changes.add(null);
  }

  /// Sign in against [baseUrl]. Returns null on success, or a message to show.
  ///
  /// The message is the server's for a refused login and ours for anything
  /// else, because "check your details" and "the server is unreachable" are
  /// different problems and telling someone the wrong one wastes their time.
  Future<String?> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required http.Client client,
    String device = 'Android',
  }) async {
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse('$baseUrl/api/v1/auth/login'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username.trim(),
              'password': password,
              'device': device,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      return 'Could not reach the server. Check the address on the Band tab.';
    }

    if (res.statusCode == 401) {
      return 'That username and password do not match an account.';
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return 'Sign in failed (${res.statusCode}).';
    }

    final body = jsonDecode(res.body);
    if (body is! Map || body['token'] is! String) {
      return 'The server answered without a token.';
    }

    this.username = body['username'] as String? ?? username.trim();
    token = body['token'] as String;
    profileId = body['profileId'] as String?;
    role = body['role'] as String?;
    displayName = body['displayName'] as String?;
    await _persist();
    _changes.add(null);
    return null;
  }

  /// Forget this device's session, and tell the server to as well.
  ///
  /// The local clear happens whatever the server says. A logout that left the
  /// phone signed in because the network was down would be the one failure a
  /// person cannot work around — they are handing the phone to someone else.
  Future<void> signOut({String? baseUrl, http.Client? client}) async {
    final t = token;
    // Forget who this phone was collecting for, before anything else.
    //
    // A selection that survived a sign-out would stamp the NEXT person's
    // readings with a stranger's profile id — and they would have no reason
    // to look, because they never chose it.
    await Collecting.instance.clear();
    username = null;
    token = null;
    profileId = null;
    role = null;
    displayName = null;
    await _persist();
    _changes.add(null);

    if (t != null && baseUrl != null && client != null) {
      try {
        await client
            .post(Uri.parse('$baseUrl/api/v1/auth/logout'),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({'token': t}))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // The token expires on its own; a failed revoke is not worth blocking
        // the person in front of us.
      }
    }
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      Future<void> put(String k, String? v) async =>
          v == null ? await p.remove(k) : await p.setString(k, v);
      await put(_kUser, username);
      await put(_kToken, token);
      await put(_kProfile, profileId);
      await put(_kRole, role);
      await put(_kName, displayName);
    } catch (_) {}
  }
}
