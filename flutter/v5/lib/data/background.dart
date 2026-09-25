import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the app running while it is not on screen, so the band keeps syncing.
///
/// ⚠ This is the whole reason it exists. Android stops an app's Dart timers
/// shortly after it leaves the foreground, and every scheduler in this app is
/// a Dart timer: SyncService's two-minute sweep, CloudSync's flush, the
/// periodic sampler. So the band recorded continuously and the phone collected
/// none of it until someone opened the app — a participant who wore the band
/// all week and opened the app on Friday saw empty screens until one long
/// sync completed, and every screen in between reported no data.
///
/// A foreground service is the only sanctioned way to keep a BLE link and its
/// timers alive on modern Android, and it comes with an unavoidable, permanent
/// notification. That is not a cost to hide: the notification is the OS
/// telling the user this app is running, and an app holding a health sensor
/// link should be visible in exactly that way.
///
/// It deliberately does NOT run the sync in the service's own isolate. The BLE
/// stack, the database and the outbox all live in the main isolate and hold
/// state that a second isolate cannot see; duplicating them there would mean
/// two writers to one SQLite file. Keeping the PROCESS alive lets the existing
/// schedulers carry on unchanged, which is a far smaller change than moving
/// them.
class BackgroundSync {
  BackgroundSync._();
  static final BackgroundSync instance = BackgroundSync._();

  static const _kEnabled = 'background.enabled';

  /// Whether the service is actually running.
  bool enabled = false;

  /// Whether it is MEANT to be running.
  ///
  /// Separate from [enabled] because starting can fail for a reason that is
  /// nobody's decision — most often the notification permission, which cannot
  /// be asked for during startup because there is no frame to show a dialog
  /// on yet. Collapsing the two turned "we have not asked you yet" into "you
  /// said no", and the service then never started on a fresh install: the
  /// exact case every new participant is in.
  bool wanted = false;

  bool get supported => defaultTargetPlatform == TargetPlatform.android;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      // ON by default now.
      //
      // Android stops this app the moment it leaves the screen, and with it
      // the band connection and every sync timer. Off by default meant a
      // participant wearing the band all day collected nothing unless they
      // remembered to open the app — which is not a thing to ask of someone
      // in a study, and was the practical reason data stopped arriving.
      //
      // The cost is a permanent notification, which is Android telling the
      // truth: the app really is running. It remains switchable on the Band
      // tab for anyone who would rather sync by hand.
      wanted = p.getBool(_kEnabled) ?? true;
      // Deliberately does NOT start here. `start()` asks for the notification
      // permission, and a permission dialog needs a frame to appear on —
      // during startup there is none, so the request is refused before anyone
      // sees it. [ensureStarted] is called once the UI is up.
    } catch (e) {
      debugPrint('[AuraV5] background sync state unavailable: $e');
    }
  }

  /// Start it if it is meant to be running and is not already.
  ///
  /// Called after the first frame — and after onboarding, so the permission
  /// dialog does not land behind a modal sheet. Safe to call repeatedly.
  Future<void> ensureStarted() async {
    if (!supported || !wanted || enabled) return;

    // Android will not start a `connectedDevice` foreground service unless
    // the app already HOLDS a runtime Bluetooth permission:
    //
    //   SecurityException: Starting FGS with type connectedDevice ...
    //   requires any of [BLUETOOTH_CONNECT, BLUETOOTH_SCAN, ...]
    //
    // Those are granted the first time somebody scans, which is after this.
    // Attempting anyway does not merely fail: the service is left in a
    // half-started state and Android retries it every five seconds, so a
    // fresh install sat in a permanent crash loop, logging and burning
    // battery while never collecting anything.
    //
    // So: only when the permission is actually in hand. Called again after a
    // successful connect, which is the moment it becomes true.
    if (!await _bluetoothGranted()) {
      debugPrint('[AuraV5] background sync waiting for Bluetooth permission');
      return;
    }

    final why = await start(persist: false);
    if (why != null) {
      // Not written down as a preference: the person never expressed one, and
      // recording a refusal here would stop the app ever asking again.
      debugPrint('[AuraV5] background sync could not start: $why');
    }
  }

  /// Does the app hold a Bluetooth runtime permission yet?
  ///
  /// Either is enough for the foreground-service type; the app asks for both
  /// when it first scans.
  Future<bool> _bluetoothGranted() async {
    try {
      if (await Permission.bluetoothConnect.isGranted) return true;
      if (await Permission.bluetoothScan.isGranted) return true;
      // Pre-Android-12 phones have no such runtime permission and the old
      // umbrella one is granted at install.
      return await Permission.bluetooth.isGranted;
    } catch (e) {
      debugPrint('[AuraV5] could not check Bluetooth permission: $e');
      return false;
    }
  }

  void _init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'rua_band_sync',
        channelName: 'Band sync',
        channelDescription:
            'Shown while the app is keeping your band connected and syncing.',
        // Low: it must be visible, it must not buzz. It is a status, not news.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // The service's own heartbeat. The real work is on the app's existing
        // schedulers; this only has to be often enough that Android keeps the
        // service alive.
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Returns the reason it could not start, or null on success.
  Future<String?> start({bool persist = true}) async {
    if (!supported) return 'Background sync is Android-only for now.';

    // Android 13+ will not show the service's notification without this, and
    // a foreground service whose notification is suppressed is killed.
    final notif = await Permission.notification.request();
    if (!notif.isGranted) {
      return 'Android needs permission to show the sync notification. '
          'Without it the service cannot run.';
    }

    _init();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        enabled = true;
        if (persist) await _persist();
        _changes.add(null);
        return null;
      }
      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Rua Science',
        notificationText: 'Keeping your band synced',
        callback: _entry,
      );
      if (result is ServiceRequestFailure) {
        return 'Could not start the background service: ${result.error}';
      }
    } catch (e) {
      return 'Could not start the background service: $e';
    }
    enabled = true;
    wanted = true;
    if (persist) await _persist();
    _changes.add(null);
    return null;
  }

  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[AuraV5] could not stop background service: $e');
    }
    enabled = false;
    wanted = false;
    await _persist();
    _changes.add(null);
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, enabled);
    } catch (_) {}
  }
}

/// The service isolate's entry point.
///
/// Required by the plugin, and deliberately does nothing. The sync happens in
/// the MAIN isolate, which this service exists to keep alive — see the note on
/// [BackgroundSync]. Anything done here would be running against a second,
/// empty copy of the app's state.
@pragma('vm:entry-point')
void _entry() => FlutterForegroundTask.setTaskHandler(_KeepAlive());

class _KeepAlive extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
