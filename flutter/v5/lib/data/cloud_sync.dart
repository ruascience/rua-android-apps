/// Pushes what SQLite holds up to the Spring Boot API, and keeps trying.
///
/// ## The contract
///
/// SQLite is the system of record. This is a *mirror*, and it is allowed to
/// be behind — it is never allowed to lose anything, and it is never allowed
/// to take the app down.
///
/// Every row carries a `synced` flag. A row is written first and marked
/// second, so the failure mode of a crash mid-push is a row sent twice, never
/// a row lost. A sample is keyed server-side on its timestamp alone now, and
/// a batch only `$set`s the metric fields it carries, so a repeat overwrites
/// instead of duplicating and the duplicate costs nothing. SQLite still keys
/// on (device, metric, at) — the two sides stopped agreeing on the key on
/// purpose, and only the server's half moved.
///
/// ## Why the server being down is uninteresting
///
/// Nothing here awaits the network on the write path. A store write bumps a
/// revision, this listens to that and flushes in the background. If the flush
/// fails the rows stay unsynced and the next trigger picks them up — the
/// backlog is the queue, and it is already durable because it is the data.
///
/// The one thing that would break that is treating a permanent rejection as
/// retryable: a malformed row answered 400 forever would sit at the head of
/// the queue and block everything behind it. So 4xx marks the batch done (and
/// says so in the log) while 5xx and network errors leave it queued.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile.dart';
import 'store.dart';
import 'uuid.dart';

enum CloudState { idle, syncing, offline, error }

class CloudSync {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  static const _kBase = 'cloud.base_url';
  static const _kEnabled = 'cloud.enabled';
  static const _kUser = 'cloud.auth_user';
  static const _kPass = 'cloud.auth_pass';

  /// The server in AKS, reached by address: there is no hostname for it, so
  /// there is no TLS either. `localhost` would be the PHONE, which is the
  /// classic way this looks broken for an afternoon.
  static const defaultBaseUrl = 'https://48.202.193.164:8101';

  /// The server's self-signed certificate, pinned.
  ///
  /// There is no hostname for this deployment, so no public CA will issue for
  /// it — the certificate carries an IP SAN and signs itself. Pinning is what
  /// makes that safe: this app trusts exactly this certificate and no other,
  /// which is a stronger guarantee than the public CA system gives, not a
  /// weaker one. It is also why the connection must never fall back to
  /// accepting any certificate.
  ///
  /// Rotating the server certificate means shipping an app update. Valid to
  /// 2028-12-12.
  static const pinnedCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDOzCCAiOgAwIBAgIUO1pBbiMquqXYUlv6jfvXfQP7RMYwDQYJKoZIhvcNAQEL
BQAwJDEUMBIGA1UEAwwLYXVyYS12NS1hcGkxDDAKBgNVBAoMA1JVQTAeFw0yNjA5
MDkxODM1MzdaFw0yODEyMTIxODM1MzdaMCQxFDASBgNVBAMMC2F1cmEtdjUtYXBp
MQwwCgYDVQQKDANSVUEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCe
n1neZtsDpENJen2SWRXTjKzS6//SV0Ra/4BYQm+FVYOb/C4YEJ0L1jHzJW9hMWl0
cBEnSBYGatk9rjnOw+38Y/PWbtdb8CwGHBwqwYm6lz3KRk0teSxzv3JD+q1civ91
aodMGBhp+Z4BOGE2riH/HNJIiXruKF9/3oKoxdYrFJTMxXLVJA7zr4Y4v5zoqnvn
S9PqDwKT+T7s2UT8BFP0XC5XnQizkuXbc7TUC04EhcX0vRdNyCq4QhTwODPOdB+B
bGzwENZL1htjKKCCi96as5VQKH+qV3oku1sL9OtHCFPFdmlqxGTVe/rtY5qC+Kkl
4k+pJ+64lIO4w8pG2+r1AgMBAAGjZTBjMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/
BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMA8GA1UdEQQIMAaHBDDKwaQwHQYD
VR0OBBYEFC/ROoEbSka6OYLSqCIjIDHFglhdMA0GCSqGSIb3DQEBCwUAA4IBAQA2
TlVPiQX0uR4Yf/vt6B59cdl6222tqXRWcSCB0IiTieIQnRQR9jL1k0HXBopSExdb
YvMYoqyAPNWY5jGOUcB49G+kldr0P/nlx0yfEFRa5BJU0AJiI3pPsS7wPHWCEsOF
nWcGqvxXJXkm0b+pf1Cg46byQUQPUOi0u3S5PaRtdUWRgNnRcWO46VNONLHHo49K
jyhn7zPAyvS/SaEpVHhuQqTEmCXhVlF8U9P2gm2e1crp5ZG/BTwi/MpzI3cSOGlL
9eRrzQa082rsFbxQSrOt0LmBNyiqDOrM3B/KfRZo7UX5N7PICJWAaj0p89T62Ql+
5R4ilAjIHIhrmRO29Wrn
-----END CERTIFICATE-----''';

  /// The same certificate as DER, base64, for the exact-match fallback below.
  static const _pinnedDerB64 = 'MIIDOzCCAiOgAwIBAgIUO1pBbiMquqXYUlv6jfvXfQP7RMYwDQYJKoZIhvcNAQELBQAwJDEUMBIGA1UEAwwLYXVyYS12NS1hcGkxDDAKBgNVBAoMA1JVQTAeFw0yNjA5MDkxODM1MzdaFw0yODEyMTIxODM1MzdaMCQxFDASBgNVBAMMC2F1cmEtdjUtYXBpMQwwCgYDVQQKDANSVUEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCen1neZtsDpENJen2SWRXTjKzS6//SV0Ra/4BYQm+FVYOb/C4YEJ0L1jHzJW9hMWl0cBEnSBYGatk9rjnOw+38Y/PWbtdb8CwGHBwqwYm6lz3KRk0teSxzv3JD+q1civ91aodMGBhp+Z4BOGE2riH/HNJIiXruKF9/3oKoxdYrFJTMxXLVJA7zr4Y4v5zoqnvnS9PqDwKT+T7s2UT8BFP0XC5XnQizkuXbc7TUC04EhcX0vRdNyCq4QhTwODPOdB+BbGzwENZL1htjKKCCi96as5VQKH+qV3oku1sL9OtHCFPFdmlqxGTVe/rtY5qC+Kkl4k+pJ+64lIO4w8pG2+r1AgMBAAGjZTBjMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMA8GA1UdEQQIMAaHBDDKwaQwHQYDVR0OBBYEFC/ROoEbSka6OYLSqCIjIDHFglhdMA0GCSqGSIb3DQEBCwUAA4IBAQA2TlVPiQX0uR4Yf/vt6B59cdl6222tqXRWcSCB0IiTieIQnRQR9jL1k0HXBopSExdbYvMYoqyAPNWY5jGOUcB49G+kldr0P/nlx0yfEFRa5BJU0AJiI3pPsS7wPHWCEsOFnWcGqvxXJXkm0b+pf1Cg46byQUQPUOi0u3S5PaRtdUWRgNnRcWO46VNONLHHo49Kjyhn7zPAyvS/SaEpVHhuQqTEmCXhVlF8U9P2gm2e1crp5ZG/BTwi/MpzI3cSOGlL9eRrzQa082rsFbxQSrOt0LmBNyiqDOrM3B/KfRZo7UX5N7PICJWAaj0p89T62Ql+5R4ilAjIHIhrmRO29Wrn';

  /// HTTP Basic, required by every /api route since the server moved off the
  /// LAN. Supplied at BUILD time, not committed:
  ///
  ///   flutter build apk --release \
  ///     --dart-define=AURA_AUTH_USER=rua-band \
  ///     --dart-define=AURA_AUTH_PASS=...
  ///
  /// This repository is public, which is the whole reason these are not
  /// literals here — a credential in a public repository is scraped within
  /// minutes and cannot be unpublished. The value still ends up inside the
  /// APK and is readable by anyone who unpacks it, so it is a shared pilot
  /// credential rather than a secret; keeping it out of git is what stops it
  /// being a PUBLISHED one.
  ///
  /// Built without them, the app starts with no credentials and every sync
  /// answers 401 — which is retryable, so the outbox pauses rather than
  /// drains, and the Cloud settings screen can supply them by hand.
  static const defaultAuthUser =
      String.fromEnvironment('AURA_AUTH_USER', defaultValue: '');
  static const defaultAuthPass =
      String.fromEnvironment('AURA_AUTH_PASS', defaultValue: '');

  String baseUrl = defaultBaseUrl;
  String authUser = defaultAuthUser;
  String authPass = defaultAuthPass;
  bool enabled = true;

  CloudState state = CloudState.idle;
  String lastError = '';
  DateTime? lastSuccess;
  int pending = 0;
  int pushedThisSession = 0;

  /// Rows the server accepted a 4xx on and the phone therefore threw away.
  ///
  /// Separate from [pushedThisSession] so a drop is a NUMBER the Device tab can
  /// show, not just a colour. Non-zero here always means data left the phone
  /// without reaching the server.
  int discardedThisSession = 0;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _emit() => _changes.add(null);

  http.Client _client = _newClient();

  /// A client that trusts the pinned certificate and nothing else.
  ///
  /// Two layers on purpose. `setTrustedCertificatesBytes` with
  /// `withTrustedRoots: false` makes the pinned certificate the only root, so
  /// normal validation — including the IP SAN check — still runs. The callback
  /// is the fallback for the case where that validation refuses an IP-only
  /// certificate on some platform: it compares the DER bytes exactly, so it
  /// accepts precisely one certificate and cannot degrade into "accept
  /// anything", which is what `=> true` here would have meant.
  static http.Client _newClient() {
    try {
      final ctx = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(pinnedCertPem));
      final io = HttpClient(context: ctx)
        ..badCertificateCallback = (cert, host, port) =>
            base64Encode(cert.der) == _pinnedDerB64;
      return IOClient(io);
    } catch (_) {
      // dart:io unavailable, or the certificate failed to parse. Plain client
      // rather than no client: an http:// base URL still works, and an
      // https:// one fails loudly at connect time instead of silently
      // trusting whatever answers.
      return http.Client();
    }
  }

  /// Basic credentials for every /api request. Omitted entirely when unset,
  /// so a build pointed at an older unauthenticated server still works.
  Map<String, String> get _authHeaders => authUser.isEmpty && authPass.isEmpty
      ? const {}
      : {
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$authUser:$authPass'))}',
        };

  Map<String, String> get _jsonHeaders => {
        'Content-Type': 'application/json',
        ..._authHeaders,
      };

  /// False once a test has injected a client, so the reset below never throws
  /// a real socket back into a test.
  bool _ownsClient = true;

  /// Number of times the connection pool has been discarded. Surfaced only so
  /// the behaviour can be asserted.
  @visibleForTesting
  int clientResets = 0;

  /// Set when a batch was rejected permanently during THIS flush.
  ///
  /// Without it the success path at the end of flush() cleared lastError and
  /// the rejection vanished — rows dropped with nothing on screen to say so,
  /// which is worse than the rejection itself.
  bool _rejectedThisRun = false;

  /// The profile PUT was refused with a 4xx this run.
  ///
  /// Separate from [_rejectedThisRun], which means "a batch of SAMPLES was
  /// thrown away" and also drives the drain loops' early break. A profile
  /// rejection throws nothing away — the profile is re-derived from storage on
  /// every flush, so it heals itself — but it still has to survive the
  /// epilogue, which otherwise sets `state = idle; lastError = ''` three lines
  /// after `_pushProfile` set them and erases the whole report.
  bool _profileRejectedThisRun = false;

  /// Why the profile could not be pushed, when that is not an error.
  ///
  /// A phone that cannot resolve its profile id defers, by design — but until
  /// this existed it deferred in complete silence, and the Device tab went on
  /// reporting a clean, up-to-date sync forever. A deferral that never ends is
  /// indistinguishable from success unless it says something.
  String _profileNote = '';

  /// Swap in a fake for tests. Nothing here should ever reach a real socket
  /// during `flutter test`.
  @visibleForTesting
  set clientForTest(http.Client c) {
    _client = c;
    _ownsClient = false;
  }

  /// Throw away the connection pool.
  ///
  /// ⚠ This is what makes recovery after a server restart work at all.
  ///
  /// package:http keeps connections alive and reuses them. When the server
  /// goes away, a pooled socket is left half-open — and the NEXT request does
  /// not fail fast, it hangs until the timeout. Observed exactly that: the
  /// server was back, `curl` from the same phone answered in 80 ms, and the
  /// app still reported "timed out" on every attempt because it kept reaching
  /// for the same dead socket.
  ///
  /// So any transport-level failure discards the pool rather than retrying
  /// over it.
  void _resetClient() {
    // Counted before the guard: the decision to discard the pool is the
    // behaviour worth asserting, and a test's injected client must survive.
    clientResets++;
    if (!_ownsClient) return;
    try {
      _client.close();
    } catch (_) {}
    _client = _newClient();
  }

  Timer? _timer;
  Timer? _debounce;
  StreamSubscription? _storeSub;
  bool _running = false;

  /// Batch sizes. Large enough that a month of history drains in a few round
  /// trips, small enough that one failure does not throw away much work.
  static const sampleBatch = 500;
  static const sleepBatch = 200;

  /// Safety net for the case where nothing is being written — a backlog left
  /// over from an outage would otherwise sit there until the next sample.
  static const sweep = Duration(minutes: 2);

  Future<void> start() async {
    try {
      final p = await SharedPreferences.getInstance();
      baseUrl = p.getString(_kBase) ?? defaultBaseUrl;
      enabled = p.getBool(_kEnabled) ?? true;
      authUser = p.getString(_kUser) ?? defaultAuthUser;
      authPass = p.getString(_kPass) ?? defaultAuthPass;
    } catch (_) {
      // Preferences unavailable — carry on with the defaults rather than
      // leaving sync switched off for a reason the user cannot see.
    }

    // "As soon as data is stored in SQLite": Store bumps its revision on
    // every write, so subscribing here covers every write path — sync,
    // periodic sampling, manual measurement — without each one remembering
    // to call us.
    _storeSub?.cancel();
    _storeSub = Store.instance.changes.listen((_) => _scheduleFlush());

    _timer?.cancel();
    _timer = Timer.periodic(sweep, (_) => unawaited(flush()));

    await refreshPending();
    unawaited(flush());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _debounce?.cancel();
    _debounce = null;
    await _storeSub?.cancel();
    _storeSub = null;
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, v);
    } catch (_) {}
    _emit();
    if (v) unawaited(flush());
  }

  Future<void> setAuth(String user, String pass) async {
    authUser = user.trim();
    authPass = pass;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kUser, authUser);
      await p.setString(_kPass, authPass);
    } catch (_) {}
    _emit();
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kBase, baseUrl);
    } catch (_) {}
    _emit();
  }

  /// A sync writes thousands of rows in a burst, each bumping the revision.
  /// Debouncing turns that into one flush instead of one per row.
  void _scheduleFlush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  Future<void> refreshPending() async {
    try {
      pending = await Store.instance.pendingCount();
      _emit();
    } catch (_) {
      // A count is cosmetic; never let it break anything.
    }
  }

  /// Push everything outstanding. Safe to call at any time, from anywhere.
  ///
  /// Never throws. Every exit path either leaves rows queued for later or
  /// marks them done, and both are fine — the queue IS the data.
  Future<void> flush() async {
    if (!enabled || _running) return;
    _running = true;
    _rejectedThisRun = false;
    _profileRejectedThisRun = false;
    _profileNote = '';
    state = CloudState.syncing;
    _emit();

    try {
      var moved = 0;
      // Rows the server refused. Counted apart from `moved` because they are
      // the opposite of progress, and folding them together is what made the
      // Device tab report "55779 pushed, 0 waiting, synced just now" at the
      // exact moment the backlog was being thrown away.
      var discarded = 0;
      // Loop so a large backlog drains in one go rather than one batch per
      // trigger — after a week offline that would take a week to catch up.
      while (true) {
        final rows = await Store.instance.unsyncedSamples(limit: sampleBatch);
        if (rows.isEmpty) break;

        // The row as it stands, all four columns. The server stores one
        // document per (device, metric, at) — the phone's own primary key —
        // so the wire shape and the stored shape are the same thing and
        // nothing has to be translated at either end.
        //
        // ⚠ `device` is required, and briefly was not sent. While the server
        // pivoted onto the instant it was dropped from the payload, and two
        // bands worn at the same moment merged into one document, last write
        // winning each field. This phone HAS two bands. Sending it keeps
        // their rows apart, and is the only reason the server can tell them
        // apart at all — the field cannot be reconstructed once it is gone.
        final ok = await _post('/api/v1/samples', [
          for (final r in rows)
            {
              'device': r['device'],
              'metric': r['metric'],
              'at': r['at'],
              'value': (r['value'] as num?)?.toDouble() ?? 0.0,
            }
        ]);
        if (!ok) return; // stays queued; state already set by _post
        // Marked even when the server REFUSED them: a 4xx is permanent, and
        // leaving a poison row queued wedges the outbox forever.
        await Store.instance.markSamplesSynced(rows);
        if (_rejectedThisRun) {
          // ⚠ Stop the drain. Marking a rejected batch is what keeps the queue
          // moving; CONTINUING to drain after one is what turns a single bad
          // batch into the whole backlog.
          //
          // The case that matters is version skew, and it is not hypothetical:
          // a build sending this payload to an API that still requires
          // `device` gets 400 on element 1 — so EVERY batch fails, and without
          // this break one flush() walks all 55,779 rows, marks every one
          // synced and uploads nothing. `unsyncedSamples` filters `synced = 0`,
          // so they are then invisible; the only way back is "Re-send all",
          // which a user has no reason to press.
          //
          // Losing 500 rows and stopping is strictly better than losing all of
          // them, in the poison-row case as well as this one.
          discarded += rows.length;
          break;
        }
        moved += rows.length;
        if (rows.length < sampleBatch) break;
      }

      while (true) {
        final rows = await Store.instance.unsyncedSleep(limit: sleepBatch);
        if (rows.isEmpty) break;

        final ok = await _post('/api/v1/sleep-segments', [
          for (final r in rows)
            {
              'device': r['device'],
              'start': r['start'],
              'minutes': r['minutes'],
              'stages': ((r['stages'] as String?) ?? '')
                  .split(',')
                  .map((e) => int.tryParse(e.trim()))
                  .whereType<int>()
                  .toList(),
            }
        ]);
        if (!ok) return;
        await Store.instance.markSleepSynced(rows);
        if (_rejectedThisRun) {
          discarded += rows.length;
          break;
        }
        moved += rows.length;
        if (rows.length < sleepBatch) break;
      }

      await _pushProfile();

      // Only 2xx-accepted rows count as pushed, and only they refresh the
      // "last sync" clock — otherwise both indicators assert success while
      // data is being discarded.
      pushedThisSession += moved;
      discardedThisSession += discarded;
      if (moved > 0) lastSuccess = DateTime.now();
      if (_rejectedThisRun || _profileRejectedThisRun) {
        // Everything drained, but something was refused. Keep saying so —
        // `lastError` is left exactly as the failing path wrote it.
        state = CloudState.error;
      } else {
        state = CloudState.idle;
        // Not blanked unconditionally. A profile that could not be identified
        // is not an error — deferring is the correct, safe behaviour — but it
        // is also not nothing, and this is the only place it can be said.
        lastError = _profileNote;
      }
    } catch (e) {
      // Belt and braces. Nothing above should throw, and if something does
      // it must not escape into an unhandled async error.
      state = CloudState.error;
      lastError = '$e';
      debugPrint('[AuraV5] cloud flush failed: $e');
    } finally {
      _running = false;
      await refreshPending();
      _emit();
    }
  }

  /// The person, so the server's rows mean something. Best-effort: a failure
  /// here must not hold up sample data.
  Future<void> _pushProfile() async {
    final p = Profile.instance;
    final device = p.bandDisplayName;
    if (device == null || device.isEmpty || !p.onboarded) return;

    // ⚠ The id is settled BEFORE anything is sent, and no id means no push.
    //
    // A profile pushed without one is a profile the server has to key some
    // other way, and the only other key it has is the band's advertised name
    // — which is how the live database ended up with a document whose `_id`
    // is "JCV5 BE8D18". Skipping the push costs a round of stale name/age on
    // the server; guessing an id costs a duplicate person that nothing in the
    // app can later merge.
    String? id;
    try {
      id = await p.ensureProfileId(
          lookup: lookupProfileByBand, mintGate: serverHoldsNoProfiles);
    } catch (e) {
      debugPrint('[AuraV5] profile id unresolved: $e');
      _profileNote = 'profile identity unresolved — $e';
      return;
    }
    if (id == null || id.isEmpty) {
      // The safe outcome, and the one that must not be silent. Every route
      // here is a question the server could not answer: it is unreachable, it
      // is un-migrated and answering 503, it is older than this app and has no
      // by-band route, or it holds profiles but none that match this band. The
      // phone is right to wait rather than mint a second person — but waiting
      // forever while the Device tab reads "Up to date" is how nobody notices.
      _profileNote = 'profile not yet synced — waiting for the server to '
          'identify this band';
      debugPrint('[AuraV5] profile id unresolved: deferring, nothing minted');
      return;
    }

    try {
      final res = await _client
          .put(
            Uri.parse('$baseUrl/api/v1/profile'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'id': id,
              'device': device,
              // The BLE ADDRESS, not the advertised name above. They are two
              // different facts and the server wants both: `device` is what
              // the samples are filed under, `bandId` is what survives the
              // band renaming itself, as this one did mid-session from
              // "JCV8B 44300D" to "V5".
              //
              // Omitted rather than sent as null when unknown: a null here
              // would overwrite a good band id on the server with nothing,
              // and the band id is identity — unlike the fields below, it is
              // never something the user meant to clear.
              if (p.bandId != null && p.bandId!.isNotEmpty) 'bandId': p.bandId,
              'name': p.name,
              'age': p.age,
              'sex': p.sex.index,
              'heightCm': p.heightCm,
              'weightKg': p.weightKg,
              // Sent even when blank, as null. These two ARE user-clearable,
              // so "no phone number" has to be able to travel; leaving the
              // field out would make deleting an address the one edit that
              // never reaches the server.
              'phoneNumber': _blankToNull(p.phoneNumber),
              'email': _blankToNull(p.email),
              'periodStarts': [
                for (final d in p.periodStarts)
                  '${d.year.toString().padLeft(4, '0')}-'
                      '${d.month.toString().padLeft(2, '0')}-'
                      '${d.day.toString().padLeft(2, '0')}'
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode >= 400 && res.statusCode < 500) {
        // package:http does not throw on a 4xx, so discarding the response —
        // which this did — makes a rejected profile indistinguishable from an
        // accepted one, and the Device tab reports a clean sync while the
        // person's name, age and weight quietly stop arriving. The server
        // rejects on a missing id and on a contact field its pattern dislikes
        // where ours did not, so this is a reachable state, not a theoretical
        // one.
        //
        // Recorded but NOT marked permanently dropped: unlike a sample batch,
        // the profile is re-derived from storage on every flush, so it heals
        // itself the moment the payload or the server is fixed. 5xx and
        // transport failures fall through to the same retry for the same
        // reason.
        _profileRejectedThisRun = true;
        state = CloudState.error;
        lastError = 'profile rejected ${res.statusCode} — ${_short(res.body)}';
        debugPrint('[AuraV5] profile rejected: ${res.statusCode} '
            '${_short(res.body)}');
      }
    } catch (_) {
      // Sample data is the point; the profile rides along on the next flush.
    }
  }

  /// Does this server hold NO profiles at all?
  ///
  /// The last gate before minting a profile id, and the only question whose
  /// answer is safe in the direction it is used. `true` is returned for one
  /// state only: the server answered, and the number it reported was zero.
  ///
  /// Everything else is false, and every "else" is a real state on this
  /// phone. A build older than this one has no `profiles` key in its summary
  /// — absent, not zero, and reading absence as zero is how the app updates
  /// before the API does and mints a rival for a profile that exists. An
  /// un-migrated database answers 503 from SchemaGuard. An unreachable server
  /// answers nothing. All three mean the same thing here: we do not know, so
  /// do not mint.
  Future<bool> serverHoldsNoProfiles() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/v1/summary'), headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final body = jsonDecode(res.body);
      if (body is! Map) return false;
      final n = body['profiles'];
      // `is num` and not `!= null`: an older build omits the key entirely,
      // and `null == 0` is false anyway — but being explicit is the point of
      // the whole method.
      return n is num && n == 0;
    } catch (_) {
      _resetClient();
      return false;
    }
  }

  static String? _blankToNull(String s) => s.trim().isEmpty ? null : s.trim();

  /// Does the server already hold a profile for this band?
  ///
  /// Asked once per install, and only while no id is stored. Getting it wrong
  /// in the "no" direction costs a second profile document for the same
  /// person, which nothing in the app can merge afterwards — so every branch
  /// here is biased towards "I do not know" and away from "there is none".
  ///
  /// The search is wider than the connected band because the thing being
  /// looked for is filed under a name nobody chose deliberately. The
  /// migration could not fill in `band_id` — the BLE address lives only on
  /// the phone — so it filed the profile under `device`, the advertised name
  /// that used to be its `_id`, which is ONE of this phone's two bands. It
  /// asks, in order:
  ///
  ///   1. `by-band/{bleAddress}?device={connected name}` — the one-round-trip
  ///      form, and the only one that can match `band_id` once a push has
  ///      written it.
  ///   2. `by-band/{name}` for every band this phone has history under, the
  ///      connected one first.
  ///   3. `profile/{name}` — the PRE-migration key, where the document lived
  ///      when its `_id` was the advertised name. Evidence only; see below.
  ///
  /// Note what step 3 does NOT do: adopt the id it finds. Taking the
  /// advertised name as our permanent id would leave the phone pushing to a
  /// document the migration is about to move to a UUID — the same duplicate
  /// arriving through the other door. It only ever answers "a profile for
  /// this band exists", and if one does, the answer to "may I mint?" is no.
  Future<ProfileLookupResult> lookupProfileByBand(
      String bandId, String? device) async {
    final byAddress = await _profileIdFor(bandId, device);
    if (byAddress.outcome != ProfileLookup.none) return byAddress;

    // Every name this phone holds data under, not just the one connected now.
    //
    // `bandDisplayName` is rewritten on every connect, and this phone has two
    // bands — 34,373 samples from `JCV5 6C6BB3`, 20,906 from `JCV5 BE8D18` —
    // with the profile filed under one of them. Putting the other band on
    // first thing in the morning is enough to miss a profile that is sitting
    // right there. The band renaming itself has the same effect, and this
    // hardware does rename itself ("JCV8B 44300D" -> "V5").
    //
    // A `null` here is the database declining to answer, which is not the
    // same fact as "no history". Narrowing the search on the strength of a
    // list we could not read is exactly how the 404 below gets believed when
    // it should not be, so it leaves the question open instead.
    final known = await Store.instance.knownDevices();
    if (known == null) return const ProfileLookupResult.unreachable();

    final tried = <String>{bandId};
    final names = <String>[?device, ...known];
    for (final name in names) {
      if (name.isEmpty || !tried.add(name)) continue;
      final byName = await _profileIdFor(name, null);
      // Found, or could not ask — either way, stop. Only a definite 404 is
      // worth continuing past.
      if (byName.outcome != ProfileLookup.none) return byName;
    }

    // ⚠ Everything 404ed — which is also what a server with no such ROUTE
    // says, and that is the one sequence that still ends in two profiles:
    //
    //   the app updates before the API does → by-band 404s because it does
    //   not exist yet → "none" → mint → the id is now permanent → the API
    //   and migration are deployed → the phone pushes its own UUID beside
    //   the migrated document, and the user has two profiles.
    //
    // So a 404 is only believed when no profile exists under the old key
    // either. The pre-migration document's `_id` IS the advertised name, so
    // this finds it exactly while that window is open and 404s once the
    // migration has moved it to a UUID — which is when believing the 404 is
    // correct.
    for (final name in tried) {
      if (name == bandId) continue;
      final legacy = await _legacyProfileExists(name);
      // Not `== true`. `null` is "could not ask", and the whole point of the
      // tri-state is that it must not collapse into "no".
      if (legacy != false) return const ProfileLookupResult.unreachable();
    }
    return byAddress;
  }

  /// Is there a profile under the pre-UUID key? Evidence only — see above.
  ///
  /// `null` means the question could not be asked, and the caller must not
  /// read that as "no". This is the same `none`-vs-`unreachable` distinction
  /// [ProfileLookupResult] exists to make, and it collapsed here into a plain
  /// `bool` precisely where it matters most: this probe is the last thing
  /// standing between a server that cannot be reached and a minted duplicate,
  /// so "the socket failed" answering "there is no profile" defeats it.
  Future<bool?> _legacyProfileExists(String device) async {
    try {
      final res = await _client
          .get(
              Uri.parse(
                  '$baseUrl/api/v1/profile/${Uri.encodeComponent(device)}'),
              headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 404) return false;
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      // 503 is SchemaGuard refusing an un-migrated database, where the
      // profile we are looking for demonstrably DOES exist and simply cannot
      // be matched yet. Anything else in this range is equally uninformative.
      return null;
    } catch (_) {
      _resetClient();
      return null;
    }
  }

  Future<ProfileLookupResult> _profileIdFor(String key, String? device) async {
    final q = device == null || device.isEmpty
        ? ''
        : '?device=${Uri.encodeQueryComponent(device)}';
    final uri =
        Uri.parse('$baseUrl/api/v1/profile/by-band/${Uri.encodeComponent(key)}$q');
    final http.Response res;
    try {
      res = await _client
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Same reasoning as _post: a pooled socket left half-open by a server
      // restart hangs rather than failing, and must not be retried over.
      _resetClient();
      return const ProfileLookupResult.unreachable();
    }
    if (res.statusCode == 404) return const ProfileLookupResult.none();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // A 500 is not "there is no profile". Treating it as one is how the
      // duplicate gets minted.
      return const ProfileLookupResult.unreachable();
    }
    Object? body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      return const ProfileLookupResult.unreachable();
    }
    if (body is Map) {
      // `_id` is what Mongo calls it and what the contract names; `id` is
      // what Jackson serialises a Spring `@Id` field as unless it is told
      // otherwise. Accepting both is one line and removes a whole class of
      // "worked in Postman, duplicated on the phone".
      for (final k in const ['_id', 'id', 'profileId']) {
        final v = body[k];
        if (v is! String || v.isEmpty) continue;
        // Adopted only if it is actually a UUID. This method's caller promises
        // in its own docstring never to take the band's advertised name as a
        // permanent id, and enforces that for the legacy probe by not adopting
        // at all — but the by-band routes adopt whatever `_id` comes back, and
        // a server can return a document whose key is still the old one (an
        // un-migrated database, a half-run migration, a hand-edited row). Once
        // stored, the id is permanent; nothing clears it. So a non-UUID is
        // "something is wrong here", which is `unreachable` — defer — and
        // never `none`, which would licence minting a rival.
        if (!isUuidV4(v)) {
          debugPrint('[AuraV5] profile lookup returned a non-UUID id '
              '(${_short(v)}) — not adopting');
          return const ProfileLookupResult.unreachable();
        }
        return ProfileLookupResult.found(v);
      }
    }
    // A profile came back and we could not tell what it is called. Refusing
    // to guess is the point: this returns "unknown", never "none".
    debugPrint('[AuraV5] profile lookup: no id in ${_short(res.body)}');
    return const ProfileLookupResult.unreachable();
  }

  /// True when the batch is settled — accepted, or rejected in a way that
  /// retrying cannot fix.
  Future<bool> _post(String path, List<Map<String, Object?>> body) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: _jsonHeaders,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode >= 200 && res.statusCode < 300) return true;

      // 401/403 are the exception to the rule below. They say nothing about
      // the payload — the credential is wrong or missing — and the fix is on
      // the server or in settings, not in the data. Treating them as
      // permanent would mark every queued batch done and DISCARD it, so a
      // mistyped password would silently destroy the outbox instead of
      // pausing it. Retryable, like a 5xx.
      if (res.statusCode == 401 || res.statusCode == 403) {
        state = CloudState.error;
        lastError = 'unauthorized ${res.statusCode} — check cloud credentials';
        debugPrint('[AuraV5] cloud auth rejected $path: ${res.statusCode}');
        return false;
      }

      if (res.statusCode >= 400 && res.statusCode < 500) {
        // Permanent. Retrying an unacceptable payload forever would wedge the
        // queue and every later row behind it, so it is marked done and
        // recorded loudly instead of silently dropped.
        _rejectedThisRun = true;
        state = CloudState.error;
        lastError = 'rejected ${res.statusCode} — ${_short(res.body)}';
        debugPrint('[AuraV5] cloud rejected $path: ${res.statusCode} '
            '${_short(res.body)}');
        return true;
      }

      state = CloudState.error;
      lastError = 'server ${res.statusCode}';
      return false;
    } on TimeoutException {
      // Very likely a stale pooled socket rather than a slow server — see
      // _resetClient. Either way the next attempt must start from a clean one.
      _resetClient();
      state = CloudState.offline;
      lastError = 'timed out';
      return false;
    } catch (e) {
      // No route to host, DNS, connection refused, TLS — all the same thing
      // from here: the server is not reachable right now, try again later.
      _resetClient();
      state = CloudState.offline;
      lastError = _short('$e');
      return false;
    }
  }

  static String _short(String s) =>
      s.length <= 120 ? s : '${s.substring(0, 120)}…';

  /// Is the server there? Used by the UI's Test button only.
  ///
  /// Deliberately NOT /actuator/health. Actuator is served on a second port
  /// that is private to the pod — it is how Kubernetes probes the container,
  /// and its body names the database — so nothing outside the cluster can
  /// reach it. /api/v1/summary is the cheapest authenticated route, which
  /// also makes this test cover the credential and not just the socket.
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(Uri.parse('$baseUrl/api/v1/summary'), headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      final ok = res.statusCode == 200;
      state = ok ? CloudState.idle : CloudState.error;
      lastError = ok
          ? ''
          : res.statusCode == 401 || res.statusCode == 403
              ? 'unauthorized ${res.statusCode} — check credentials'
              : 'server ${res.statusCode}';
      _emit();
      return ok;
    } catch (e) {
      _resetClient();
      state = CloudState.offline;
      lastError = _short('$e');
      _emit();
      return false;
    }
  }
}
