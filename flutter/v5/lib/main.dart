import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ble/band_link.dart';
import 'data/profile.dart';
import 'ui/device_page.dart';
import 'ui/home_page.dart';
import 'data/background.dart';
import 'data/cloud_sync.dart';
import 'data/sync_service.dart';
import 'ui/kit.dart';
import 'ui/onboarding.dart';
import 'ui/sleep_page.dart';
import 'ui/trends_page.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // Publish the semantics tree in debug builds so the running app can be
  // inspected and driven as TEXT — `adb shell uiautomator dump` returns the
  // real labels instead of an empty node list.
  //
  // Flutter only builds this tree when something asks for it, normally an
  // accessibility service. Requesting it here means on-device verification
  // does not depend on screenshots, which is the point: a screenshot captures
  // whatever happens to be on screen, and the accessibility tree of a
  // foreground app captures only that app.
  //
  // Debug only — building the tree has a cost, and release users get it from
  // their own accessibility service when they need it.
  if (kDebugMode) {
    binding.ensureSemantics();
  }

  // ⚠ Nothing before runApp() may be allowed to throw.
  //
  // This used to be a bare `await Profile.instance.load()`. That call opens
  // SQLite and runs migrations, and if any of it failed — a corrupt database,
  // a half-applied schema upgrade, a full disk — the exception escaped main()
  // and runApp() was never reached. The result is not a visible error: it is
  // an app that dies on launch, every launch, with no screen and no way for
  // the user to clear it.
  //
  // Booting with defaults and saying so is strictly better than not booting.
  var storageFailed = false;
  try {
    await Profile.instance.load();
  } catch (e, st) {
    storageFailed = true;
    debugPrint('[AuraV5] profile load failed, starting with defaults: $e\n$st');
  }

  // Pick up where the last session left off: if the band from last time is
  // in range, connect and sync without anyone tapping anything.
  //
  // Unawaited — it spends up to 8 s looking, and the UI must come up first.
  // A sync follows the connect for the same reason a reconnect triggers one:
  // the interesting data is whatever the band logged while we were away.
  unawaited(() async {
    try {
      if (await BandLink.instance.connectToRemembered()) {
        await SyncService.instance.syncAll();
      }
    } catch (e) {
      debugPrint('[AuraV5] startup reconnect failed: $e');
    }
  }());

  // Restore the foreground service if it was switched on. Before anything
  // that schedules a timer: those timers are exactly what the service exists
  // to keep alive, and starting it after them leaves a window where Android
  // can stop them.
  try {
    await BackgroundSync.instance.load();
  } catch (e) {
    debugPrint('[AuraV5] background sync did not resume: $e');
  }

  // Mirror SQLite to the API. Started unawaited and inside its own guard:
  // the phone works offline by design, so nothing about the cloud may delay
  // or prevent the app coming up.
  try {
    unawaited(CloudSync.instance.start());
  } catch (e) {
    debugPrint('[AuraV5] cloud sync did not start: $e');
  }

  // A reconnect that does not sync is half a fix: the whole reason the drop
  // mattered is the data the band logged while the link was down.
  BandLink.instance.onReconnected = SyncService.instance.syncAll;

  // A build error should cost you one card, not the whole screen. The default
  // ErrorWidget is a full-bleed grey (release) or red (debug) panel that
  // replaces whatever contained it — on a page of stacked cards that reads as
  // "the app is broken" when one metric failed to render.
  ErrorWidget.builder = (details) => _InlineError(details: details);

  // Unhandled errors from the framework and from async gaps. Neither should
  // take the process down: this app's job is to hold a BLE link and keep
  // writing to SQLite, and it can carry on doing that with one broken widget
  // or one failed future.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    BandLink.instance.log.add('ui error: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[AuraV5] uncaught async error: $error\n$stack');
    BandLink.instance.log.add('error: $error');
    return true; // handled — do not terminate
  };

  runApp(AuraV5App(storageFailed: storageFailed));
}

/// Shown in place of a widget that threw while building.
///
/// Deliberately small and inline: it keeps the rest of the page usable and
/// tells you which widget failed, instead of blanking the screen.
class _InlineError extends StatelessWidget {
  final FlutterErrorDetails details;
  const _InlineError({required this.details});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: kBad.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBad.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          Icon(Icons.warning_amber, size: 16, color: kBad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              kDebugMode
                  ? details.exceptionAsString()
                  : 'This section could not be displayed.',
              style: TextStyle(color: kBad, fontSize: 11),
            ),
          ),
        ]),
      );
}

class AuraV5App extends StatelessWidget {
  /// True when the on-device profile could not be read at startup.
  final bool storageFailed;
  const AuraV5App({super.key, this.storageFailed = false});

  static ThemeMode _mode(AppTheme t) => switch (t) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      };

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
        // Rebuilt on profile changes so switching the setting takes effect
        // without a restart.
        stream: Profile.instance.changes,
        builder: (context, _) => MaterialApp(
          title: 'Rua Science',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: _mode(Profile.instance.theme),
          home: Builder(
            // The one place the palette is pointed at a brightness. Inside
            // MaterialApp so it follows the theme the framework actually
            // resolved — including ThemeMode.system, which this widget cannot
            // work out for itself — rather than a second copy of the decision
            // that could disagree with it.
            builder: (inner) {
              applyPaletteFor(Theme.of(inner).brightness);
              return Shell(storageFailed: storageFailed);
            },
          ),
        ),
      );
}

class Shell extends StatefulWidget {
  final bool storageFailed;
  const Shell({super.key, this.storageFailed = false});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // After the first frame: the sheet needs a Navigator, and this widget is
    // the first thing under one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ensureOnboarded(context);
    });
  }

  /// Index of DevicePage in [_pages].
  static const _deviceTab = 3;

  /// Four destinations, four pages — one tab bar, no nested tabs.
  ///
  /// It was three destinations with two of them holding a PAIR of pages behind
  /// a second tab bar. Two rows of tabs is two things to learn, and the
  /// pairing put Insights and History side by side when they are one question
  /// asked twice — they are one Trends page now.
  ///
  /// Still an IndexedStack: every one of these pages documents itself as
  /// "built once at startup, before any band is connected", and several load
  /// from SQLite in `initState` on that assumption. Lazily building a tab
  /// would break that quietly.
  static const _pages = [
    HomePage(),
    SleepPage(),
    TrendsPage(),
    DevicePage(),
  ];

  static const _dests = [
    NavigationDestination(
        icon: Icon(Icons.show_chart_outlined),
        selectedIcon: Icon(Icons.show_chart),
        label: 'Today'),
    NavigationDestination(
        icon: Icon(Icons.nightlight_outlined),
        selectedIcon: Icon(Icons.nightlight),
        label: 'Sleep'),
    NavigationDestination(
        icon: Icon(Icons.insights_outlined),
        selectedIcon: Icon(Icons.insights),
        label: 'Trends'),
    NavigationDestination(
        icon: Icon(Icons.watch_outlined),
        selectedIcon: Icon(Icons.watch),
        label: 'Band'),
  ];

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
        stream: BandLink.instance.changes,
        builder: (context, _) => Scaffold(
          // IndexedStack keeps each tab's state and its loaded data alive, so
          // switching tabs does not re-query SQLite every time.
          body: SafeArea(
            child: Column(children: [
              if (widget.storageFailed) const _StorageWarning(),
              // Deliberately not const — see ConnectionBar.build.
              ConnectionBar(),
              Expanded(
                  child: IndexedStack(index: _tab, children: _pages)),
            ]),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            destinations: _dests,
            backgroundColor: kCard,
            onDestinationSelected: (i) {
              // Arriving at Device must show an empty list until a scan runs.
              // The pages live in an IndexedStack, so DevicePage is built once
              // and never re-runs initState — without this, the tab reopens
              // showing whatever the last scan found, however long ago.
              if (i == _deviceTab) BandLink.instance.clearFound();
              setState(() => _tab = i);
            },
          ),
        ),
      );
}

/// A one-line connection state, pinned above every tab.
///
/// It lives in the Shell rather than in each page for the obvious reason —
/// one implementation — and for a less obvious one: the pages sit in an
/// IndexedStack and are built once, so a per-page banner would show whatever
/// was true when that tab was first opened. Here it rebuilds with the Shell
/// on every link event.
class ConnectionBar extends StatelessWidget {
  const ConnectionBar({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
        // Subscribes ITSELF rather than relying on the parent to rebuild it.
        // As `const ConnectionBar()` inside the Shell's StreamBuilder this
        // was handed down as the identical widget instance every time, and
        // Flutter skips updating an element whose widget is identical — so it
        // built once at startup, read LinkState.idle, and showed
        // "Not connected" for the rest of the session however many times the
        // band connected.
        stream: BandLink.instance.changes,
        builder: (context, _) => _bar(context),
      );

  Widget _bar(BuildContext context) {
    final link = BandLink.instance;
    final t = Theme.of(context);

    final (IconData icon, String text, Color colour) = switch (link.state) {
      LinkState.connected => (
          Icons.bluetooth_connected,
          link.deviceName.isEmpty ? 'Connected' : link.deviceName,
          kAccent
        ),
      LinkState.connecting => (Icons.bluetooth_searching, 'Connecting…', kMuted),
      LinkState.scanning => (Icons.bluetooth_searching, 'Scanning…', kMuted),
      // A drop is provisional while the reconnect loop is running, and saying
      // so is the difference between "it is handling it" and "it is broken".
      LinkState.idle when link.reconnecting => (
          Icons.bluetooth_searching,
          'Reconnecting…',
          kMuted
        ),
      LinkState.idle => (Icons.bluetooth_disabled, 'Not connected', kBad),
    };

    // Masthead and status share one row: brand left, connection right.
    //
    // They were two stacked bars, which with the tab bar under them put three
    // rows of chrome above the first chart — on a screen whose entire job is
    // charts. The site sets its masthead the same way, as a signature rather
    // than a title bar, and a status line is exactly the sort of thing that
    // belongs opposite it.
    return Container(
      width: double.infinity,
      color: kCard,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(children: [
        const RuaWordmark(markSize: 22),
        const Spacer(),
        Icon(icon, size: 14, color: colour),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.labelMedium?.copyWith(color: colour)),
        ),
        if (link.batteryPercent != null && link.state == LinkState.connected)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text('${link.batteryPercent}%',
                style: t.textTheme.labelMedium?.copyWith(color: kMuted)),
          ),
      ]),
    );
  }
}

/// Shown when the profile could not be read from storage at startup.
///
/// The app still runs — it just cannot trust its own numbers, because age,
/// height and weight feed every derived metric. Saying so is the point: the
/// alternative is silently computing a VO2max from a default 35-year-old.
class _StorageWarning extends StatelessWidget {
  const _StorageWarning();

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: kBad.withValues(alpha: 0.18),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(children: [
          Icon(Icons.warning_amber, size: 14, color: kBad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not read your saved profile — age, height and weight '
              'feed every derived metric, so treat those numbers as '
              'unreliable until this clears.',
              style: TextStyle(color: kBad, fontSize: 11),
            ),
          ),
        ]),
      );
}
