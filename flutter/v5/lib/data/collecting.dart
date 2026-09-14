import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session.dart';

/// Who this phone is collecting for.
///
/// A band handed to a participant for a fortnight comes back and is synced on
/// whichever phone is to hand — usually not theirs. The server files a
/// reading under the AUTHENTICATED ACCOUNT and never under anything the
/// client claims, which is the right rule and, on its own, the wrong answer
/// here: sync a participant's band on the study phone and their fortnight
/// becomes the admin's readings. Not as a collision — as a silent mislabel,
/// indistinguishable afterwards from data the admin recorded themselves.
///
/// So an admin says who it is collecting for, and that answer is stamped on
/// every row AS IT IS WRITTEN. Not at upload time: rows sit in the outbox for
/// as long as the phone is offline, and deciding ownership when they happen
/// to drain would re-attribute a backlog to whoever was selected later. The
/// person whose wrist it came off is a fact about the reading, fixed at the
/// moment it is recorded.
///
/// Null means "the signed-in person themselves", which is what every ordinary
/// participant's own phone does and what every existing row means.
class Collecting {
  Collecting._();
  static final Collecting instance = Collecting._();

  static const _kProfile = 'collecting.profile_id';
  static const _kName = 'collecting.display_name';

  String? profileId;
  String? displayName;

  bool get active => (profileId ?? '').isNotEmpty;

  /// True when nothing may be collected yet.
  ///
  /// An admin account has no profile the server will accept by default — it
  /// must name the profile it is writing for, or every batch is refused. That
  /// refusal is correct and it is not something to discover one 403 at a
  /// time, so the app blocks the sync and says why instead.
  bool get blocked => Session.instance.isAdmin && !active;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      profileId = p.getString(_kProfile);
      displayName = p.getString(_kName);
    } catch (e) {
      debugPrint('[AuraV5] collecting context unavailable: $e');
    }
    _changes.add(null);
  }

  /// Collect for [profileId], or for the signed-in person when null.
  Future<void> select(String? profileId, {String? displayName}) async {
    this.profileId = (profileId ?? '').isEmpty ? null : profileId;
    this.displayName = this.profileId == null ? null : displayName;
    await _persist();
    _changes.add(null);
  }

  /// Forget the selection.
  ///
  /// Called on sign-out: the next person to sign in on this phone must not
  /// inherit a target chosen by the last one, and a stale selection would
  /// stamp their readings with a stranger's id.
  Future<void> clear() => select(null);

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      Future<void> put(String k, String? v) async =>
          v == null ? await p.remove(k) : await p.setString(k, v);
      await put(_kProfile, profileId);
      await put(_kName, displayName);
    } catch (_) {}
  }
}
