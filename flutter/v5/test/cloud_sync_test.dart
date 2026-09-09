import 'dart:async';
import 'dart:convert';

import 'package:aurav5/data/cloud_sync.dart';
import 'package:aurav5/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The sync is a mirror, not the record. These tests pin the two properties
/// that make that safe: it never loses a row when the server is unavailable,
/// and it never crashes whatever the server does.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Store.instance.resetForTest();
    final c = CloudSync.instance;
    c.enabled = true;
    c.pending = 0;
    c.pushedThisSession = 0;
    c.lastError = '';
    c.lastSuccess = null;
    c.state = CloudState.idle;
  });

  Future<void> seed({int samples = 3}) async {
    for (var i = 0; i < samples; i++) {
      await Store.instance.putSamples('JCV5 TEST', 'heart_rate',
          [Sample(DateTime(2026, 9, 6, 10, i), 70.0 + i)]);
    }
  }

  group('an unreachable server costs nothing', () {
    test('rows stay queued when the connection is refused', () async {
      await seed();
      expect(await Store.instance.pendingCount(), 3);

      CloudSync.instance.clientForTest = MockClient((_) async {
        throw const SocketExceptionLike();
      });
      await CloudSync.instance.flush();

      expect(CloudSync.instance.state, CloudState.offline);
      expect(await Store.instance.pendingCount(), 3,
          reason: 'nothing may be marked sent when nothing was sent');
    });

    test('a timeout leaves the queue intact', () async {
      await seed();
      CloudSync.instance.clientForTest = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw const SocketExceptionLike();
      });
      await CloudSync.instance.flush();
      expect(await Store.instance.pendingCount(), 3);
    });

    test('and they go up on the next attempt once it is back', () async {
      await seed();
      CloudSync.instance.clientForTest =
          MockClient((_) async => throw const SocketExceptionLike());
      await CloudSync.instance.flush();
      expect(await Store.instance.pendingCount(), 3);

      // Server comes back.
      var posted = 0;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.url.path.endsWith('/samples')) {
          posted += (jsonDecode(req.body) as List).length;
        }
        return http.Response('{"received":0}', 200);
      });
      await CloudSync.instance.flush();

      expect(posted, 3, reason: 'the backlog is what gets sent');
      expect(await Store.instance.pendingCount(), 0);
    });
  });

  group('a broken server never breaks the app', () {
    test('a 500 keeps the rows queued for later', () async {
      await seed();
      CloudSync.instance.clientForTest =
          MockClient((_) async => http.Response('boom', 500));
      await CloudSync.instance.flush();

      expect(CloudSync.instance.state, CloudState.error);
      expect(await Store.instance.pendingCount(), 3,
          reason: '5xx is transient — the server may recover');
    });

    test('a 400 settles the batch instead of wedging the queue', () async {
      // A payload the server will never accept must not sit at the head of
      // the queue forever, blocking every good row behind it.
      await seed();
      CloudSync.instance.clientForTest = MockClient(
          (_) async => http.Response('{"error":"validation"}', 400));
      await CloudSync.instance.flush();

      expect(await Store.instance.pendingCount(), 0,
          reason: 'retrying an unacceptable payload can never succeed');
      expect(CloudSync.instance.lastError, contains('400'),
          reason: 'dropping data silently would be worse than the bug');
    });

    test('garbage in the response body does not throw', () async {
      await seed();
      CloudSync.instance.clientForTest = MockClient(
          (_) async => http.Response('<html>not json at all', 200));
      await CloudSync.instance.flush();
      expect(await Store.instance.pendingCount(), 0);
    });

    test('flush is safe to call when disabled', () async {
      await seed();
      CloudSync.instance.enabled = false;
      CloudSync.instance.clientForTest =
          MockClient((_) async => throw StateError('must not be called'));
      await CloudSync.instance.flush();
      expect(await Store.instance.pendingCount(), 3);
      CloudSync.instance.enabled = true;
    });
  });

  group('a stale connection pool cannot wedge recovery', () {
    // The bug this pins: package:http reuses keep-alive sockets. When the
    // server was killed and restarted, the pooled socket was half-open and
    // every later request HUNG to its 20 s timeout instead of failing fast.
    // Observed on the phone: curl from the same device answered in 80 ms
    // while the app reported "timed out" on every attempt.
    test('a timeout discards the pool', () async {
      await seed();
      final before = CloudSync.instance.clientResets;
      CloudSync.instance.clientForTest =
          MockClient((_) async => throw TimeoutException('stale socket'));
      await CloudSync.instance.flush();

      expect(CloudSync.instance.clientResets, greaterThan(before),
          reason: 'retrying over the same dead socket never recovers');
      expect(await Store.instance.pendingCount(), 3,
          reason: 'and the rows are still queued');
    });

    test('a transport error discards the pool too', () async {
      await seed();
      final before = CloudSync.instance.clientResets;
      CloudSync.instance.clientForTest =
          MockClient((_) async => throw const SocketExceptionLike());
      await CloudSync.instance.flush();
      expect(CloudSync.instance.clientResets, greaterThan(before));
    });

    test('a clean 2xx leaves the pool alone', () async {
      await seed();
      final before = CloudSync.instance.clientResets;
      CloudSync.instance.clientForTest =
          MockClient((_) async => http.Response('{}', 200));
      await CloudSync.instance.flush();
      expect(CloudSync.instance.clientResets, before,
          reason: 'churning connections on every success would be wasteful');
    });
  });

  group('what gets sent', () {
    test('the payload carries the row\'s whole natural key', () async {
      await Store.instance.putSamples('JCV5 TEST', 'spo2',
          [Sample(DateTime.utc(2026, 9, 6, 10), 98)]);

      Map<String, Object?>? first;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.url.path.endsWith('/samples')) {
          first = (jsonDecode(req.body) as List).first as Map<String, Object?>;
        }
        return http.Response('{}', 200);
      });
      await CloudSync.instance.flush();

      expect(first, isNotNull);
      // ⚠ `device` is the one that regressed. It was dropped from this
      // payload while the server keyed samples on the instant alone, and two
      // bands worn at the same moment then merged into one document, last
      // write winning each field. This phone has two bands, and the field
      // cannot be reconstructed once it is gone — recovering it meant
      // rebuilding the collection from the phone.
      expect(first!['device'], 'JCV5 TEST',
          reason: 'without it the server cannot tell two bands apart, and '
              'nothing downstream can put that back');
      expect(first!['metric'], 'spo2');
      expect(first!['at'], isA<int>(), reason: 'epoch ms');
      expect(first!['value'], 98.0);
      expect(first!.keys.toSet(), {'device', 'metric', 'at', 'value'},
          reason: 'the phone key (device, metric, at) plus the reading — the '
              'wire shape and the stored shape are the same thing again');
    });

    test('a row already sent is not sent twice', () async {
      await seed(samples: 2);
      var calls = 0;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.url.path.endsWith('/samples')) calls++;
        return http.Response('{}', 200);
      });
      await CloudSync.instance.flush();
      final after = calls;
      await CloudSync.instance.flush();
      expect(calls, after, reason: 'nothing left unsynced to send');
    });

    test('re-sending everything is possible after changing server', () async {
      await seed(samples: 2);
      CloudSync.instance.clientForTest =
          MockClient((_) async => http.Response('{}', 200));
      await CloudSync.instance.flush();
      expect(await Store.instance.pendingCount(), 0);

      await Store.instance.resetSyncState();
      expect(await Store.instance.pendingCount(), 2,
          reason: 'a different server holds none of it');
    });
  });
}

/// A stand-in for a connection failure. The real one is dart:io's
/// SocketException, which the sync only ever sees as "some exception".
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
  @override
  String toString() => 'SocketException: Connection refused';
}
