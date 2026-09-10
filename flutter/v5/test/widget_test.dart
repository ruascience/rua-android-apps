import 'package:flutter/material.dart';
import 'package:aurav5/ble/band_link.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:aurav5/data/profile.dart';
import 'package:aurav5/ui/device_page.dart';
import 'package:aurav5/ui/trends_page.dart';
import 'package:aurav5/ui/lab_page.dart';
import 'package:aurav5/ui/sleep_page.dart';
import 'package:aurav5/ui/kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The page's own scroll view.
///
/// NOT `find.byType(Scrollable).last`: a TextField brings its own Scrollable,
/// so as soon as the Device page gained the cloud-sync URL field, `.last`
/// started resolving to the text field and every scrollUntilVisible aimed at
/// something 40 pixels wide.
Finder pageScrollable() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    description: 'vertical page scrollable').first;

/// The Lab page on its own.
///
/// It used to be reached by tapping through the Device tab. That entry point
/// is hidden now, and a test that navigates a route the app no longer offers
/// tests the route rather than the page.
///
/// Wrapped in a Scaffold exactly as the real push site does — LabPage was
/// written as a tab body and takes its Material ancestor from its parent.
Widget openLab() => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('Lab')),
        body: const LabPage(),
      ),
    );

void main() {
  // The Shell blocks on the first-run sheet, which would cover every screen
  // under test. These tests are about the screens, not about onboarding —
  // there is a dedicated group for that.
  setUp(() => Profile.instance.markLoadedForTest());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('app boots to four flat destinations', (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    // One row of tabs, one page each. Two rows was two things to learn, and
    // it paired Insights with History — one question asked twice.
    for (final tab in ['Today', 'Sleep', 'Trends', 'Band']) {
      expect(find.text(tab), findsWidgets, reason: '$tab destination missing');
    }
    expect(find.text('Lab'), findsNothing,
        reason: 'Lab was asked to leave the bottom bar');

    // Exactly once: the tab label. The page heading that used to say it too
    // was removed when the tab bar became the title.
    expect(find.text('Today'), findsOneWidget);

    // The connection state is pinned above every tab.
    expect(find.text('Not connected'), findsWidgets);
  });

  testWidgets('both pages behind a destination are built at startup',
      (tester) async {
    // The property the grouping had to preserve. Every page documents itself
    // as built once at startup, and several read SQLite in initState on that
    // basis — so the group uses an IndexedStack rather than a TabBarView,
    // which would build the second tab only when first opened.
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    expect(find.byType(TrendsPage, skipOffstage: false), findsOneWidget,
        reason: 'Trends belongs to a destination that is not selected — it '
            'must still be mounted, or its initState work moves to first open');
    expect(find.byType(SleepPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(DevicePage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('Device tab offers a scan when nothing is connected',
      (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    await tester.tap(find.text('Band'));
    await tester.pumpAndSettle();

    expect(find.text('My Device'), findsOneWidget);
    expect(find.text('Scan for bands'), findsOneWidget);
    // The vendor app keeps the BLE link open after unpairing, which is the
    // single most common reason a scan finds nothing — the UI must say so.
    expect(find.textContaining('close the vendor app'), findsOneWidget);
  });

  testWidgets('Insights explains its methods rather than asserting numbers',
      (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    // Insights is a section of the Trends page now, not a tab of its own.
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    expect(find.text('Derived on this phone from your band\'s data'),
        findsOneWidget,
        reason: 'the one line that still says these are computed here rather '
            'than reported by the band');

    // The Cycle card and the "How these are calculated" note were removed at
    // the user's request, so this no longer asserts on either.
    expect(find.text('Cycle'), findsNothing);
    expect(find.text('Log period'), findsNothing);
    expect(find.text('How these are calculated'), findsNothing);
  });

  testWidgets('the Lab still flags risky opcodes', (tester) async {
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    expect(find.text('Protocol lab'), findsOneWidget);
    expect(find.textContaining('0x2A'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsWidgets);
  });

  testWidgets('the Lab shows the settled verdict for 0x78', (tester) async {
    // 0x78 is the opcode you reach for when hunting a pulse, and it carries
    // none. The conclusion has to be visible here, with the band on the
    // wrist, or it gets rediscovered the expensive way.
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '78');
    await tester.pumpAndSettle();

    expect(find.textContaining('SETTLED'), findsOneWidget);
    // Appears twice by design: the verdict banner and the cross-linked
    // finding headline.
    expect(find.textContaining('no pulse'), findsWidgets);
    expect(find.textContaining('0x56'), findsWidgets,
        reason: 'the verdict must name the path that does work');
  });

  testWidgets('settled opcodes are marked in the opcode list', (tester) async {
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    expect(find.textContaining('settled'), findsWidgets);
  });

  testWidgets('0x3A carries the verdict too, not just 0x78', (tester) async {
    // Both halves of the same dead end must say so. Someone hunting a pulse
    // is at least as likely to poke the stream opcode as the start opcode.
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '3A');
    await tester.pumpAndSettle();

    expect(find.textContaining('SETTLED'), findsOneWidget);
    expect(find.textContaining('no pulse'), findsWidgets);
  });

  testWidgets('the Lab offers the findings corpus without knowing an opcode',
      (tester) async {
    // The whole point: you should not need to already know which opcode to
    // ask about in order to reach what was established.
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    expect(find.text('Findings'), findsOneWidget);
    await tester.tap(find.text('Findings'));
    await tester.pumpAndSettle();

    expect(find.text('What we know about the V5'), findsOneWidget);

    // The cards sit below the standing caveat in a lazily-built list.
    await tester.scrollUntilVisible(find.textContaining('no pulse'), 400,
        scrollable: pageScrollable());
    expect(find.textContaining('no pulse'), findsWidgets);
  });

  testWidgets('the findings page separates measured from inherited',
      (tester) async {
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Findings'));
    await tester.pumpAndSettle();

    // The standing caveat is gone now that findings are confirmed on a V5 —
    // which is the point: it comes down when it stops being true.
    expect(find.text('Nothing is confirmed on a V5 yet'), findsNothing);

    // The state-of-play entry leads, and is still OPEN.
    expect(find.text('OPEN'), findsWidgets,
        reason: 'what remains unresolved must be admitted up front');

    // Scrolling down, both classes of finding must be visible AS SUCH: what
    // was measured on this band, and what was merely inherited from a V8.
    // Scroll by unique finding titles — the status chips repeat, and
    // scrollUntilVisible needs a finder that matches exactly one widget.
    await tester.scrollUntilVisible(
        find.textContaining('GATT matches the J-Style family'), 300,
        scrollable: pageScrollable());
    expect(find.textContaining('CONFIRMED ON V5'), findsWidgets,
        reason: 'measurements taken on this band must read as such');

    await tester.scrollUntilVisible(
        find.textContaining('On the V8, raw PPG'), 300,
        scrollable: pageScrollable());
    expect(find.textContaining('ASSUMED'), findsWidgets,
        reason: 'V8-derived findings must never read as V5 fact');
    // _labelled renders its heading uppercased.
    expect(find.textContaining('MEASURED ON A V8'), findsWidgets,
        reason: 'and must name the band they actually came from');
  });

  testWidgets('0x58 actigraphy is reachable in the Lab', (tester) async {
    // It was established on hardware but had no presence in the app at all.
    await tester.pumpWidget(openLab());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '58');
    await tester.pumpAndSettle();

    expect(find.textContaining('actigraphy'), findsWidgets);
    expect(find.textContaining('45 days'), findsWidgets);
  });
  testWidgets('opening the Device tab does not show the last scan\'s bands',
      (tester) async {
    // The pages sit in an IndexedStack, so DevicePage is built once and its
    // initState never runs again. Without an explicit clear on tab entry the
    // Device tab reopens showing whatever the previous scan found, however
    // stale — bands that may be out of range, in an order that puts a
    // different one under the same thumb position.
    final link = BandLink.instance;
    link.found
      ..clear()
      ..addAll([
        Candidate(BluetoothDevice(remoteId: const DeviceIdentifier('AA:01')),
            'JCV5 6C6BB3', -76, const [], 100),
      ]);

    await tester.pumpWidget(const AuraV5App());
    await tester.pump();
    await tester.tap(find.text('Band'));
    await tester.pumpAndSettle();

    expect(link.found, isEmpty);
    expect(find.textContaining('found'), findsNothing,
        reason: 'the results card renders only when found is non-empty');
    expect(find.text('Scan for bands'), findsOneWidget,
        reason: 'the only way to a list is to scan for one');
  });

  group('the connection bar tracks the link', () {
    // Reported from the phone: the bar read "Not connected" in red while the
    // band was connected. It was placed as `const ConnectionBar()`, and
    // Flutter skips updating an element whose widget is the identical
    // instance — so it built once at startup and froze on LinkState.idle.
    tearDown(() {
      BandLink.instance.state = LinkState.idle;
      BandLink.instance.deviceName = '';
    });

    testWidgets('it follows a state change instead of freezing', (tester) async {
      final link = BandLink.instance;
      link.state = LinkState.idle;
      link.deviceName = '';

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConnectionBar())));
      await tester.pump();
      expect(find.text('Not connected'), findsOneWidget);

      link.state = LinkState.connected;
      link.deviceName = 'JCV5 BE8D18';
      link.emitForTest();
      // Two pumps: the first delivers the stream event, the second paints the
      // rebuild it triggers.
      await tester.pump();
      await tester.pump();

      expect(find.text('JCV5 BE8D18'), findsOneWidget,
          reason: 'the bar must rebuild on a link event, not once at startup');
      expect(find.text('Not connected'), findsNothing);
    });

    testWidgets('a drop under retry says so rather than looking dead',
        (tester) async {
      final link = BandLink.instance;
      link.state = LinkState.idle;
      link.reconnecting = true;

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConnectionBar())));
      await tester.pump();

      expect(find.text('Reconnecting…'), findsOneWidget,
          reason: '"Not connected" during an active retry reads as broken');
      link.reconnecting = false;
    });

    testWidgets('scanning and connecting each get their own label',
        (tester) async {
      final link = BandLink.instance;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConnectionBar())));

      for (final (state, label) in [
        (LinkState.scanning, 'Scanning…'),
        (LinkState.connecting, 'Connecting…'),
      ]) {
        link.state = state;
        link.emitForTest();
        await tester.pump();
        await tester.pump();
        expect(find.text(label), findsOneWidget);
      }
    });
  });
}
