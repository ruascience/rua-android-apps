import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aurav5/data/profile.dart';
import 'package:aurav5/data/store.dart';
import 'package:aurav5/main.dart';
import 'package:aurav5/ui/kit.dart';
import 'package:aurav5/ui/profile_edit.dart';

/// The edit screen exists because the first-run sheet asked once and then
/// never again: a typo at install time was permanent, and a wrong age does
/// not throw — it produces a believable VO2max.
///
/// Pushed from a button rather than used as `home:` so that Cancel and the
/// back gesture have somewhere to pop to, which is the whole point of it.
Widget openEditor() => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                builder: (_) => const ProfileEditPage())),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.resetForTest();
    Profile.instance.markLoadedForTest();
    Profile.instance.name = 'Test Person';
    Profile.instance.age = 48;
    Profile.instance.sex = Sex.male;
    Profile.instance.heightCm = 183;
    Profile.instance.weightKg = 136;
    Profile.instance.phoneNumber = '';
    Profile.instance.email = '';
    Profile.instance.periodStarts = [];
  });

  testWidgets('the Device tab offers a route to it', (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();
    await tester.tap(find.text('Band'));
    await tester.pumpAndSettle();

    expect(find.text('Your details'), findsOneWidget,
        reason: 'the sheet must not be the only way in — this is the card '
            'that replaces the editor hidden behind showAdvancedCards');
    // The stored answers are on the card itself: a typo is only worth fixing
    // if you can see it without opening anything.
    expect(find.textContaining('48'), findsWidgets);
  });

  testWidgets('it opens on what is stored, all six answers', (tester) async {
    Profile.instance.sex = Sex.female;
    Profile.instance.periodStarts = [DateTime(2026, 8, 14)];

    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Test Person'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('183'), findsOneWidget);
    expect(find.text('136'), findsOneWidget);
    // Scrolled to, since the Contact card was added between the body fields
    // and this one: the screen has always been taller than a phone (which is
    // why Save is pinned in a footer), and it is now taller than the 800x600
    // test viewport as well. A ListView never builds what is off-screen, so
    // without the drag this fails as "not shown" when it is only "not yet
    // scrolled to".
    await tester.dragUntilVisible(
        find.text('14/8/2026'), find.byType(ListView), const Offset(0, -120));
    expect(find.text('14/8/2026'), findsOneWidget,
        reason: 'the period start is one of the answers onboarding collects, '
            'so it is one of the answers this screen has to show');
  });

  testWidgets('it opens on the stored phone and email too', (tester) async {
    Profile.instance.phoneNumber = '+44 20 7946 0018';
    Profile.instance.email = 'gaj@example.com';

    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('+44 20 7946 0018'), findsOneWidget);
    expect(find.text('gaj@example.com'), findsOneWidget,
        reason: 'an address you cannot see is an address you cannot correct, '
            'which is the state this whole screen exists to end');
  });

  testWidgets('blank phone and email do not block Save', (tester) async {
    // The rule these two fields carry: they are OPTIONAL. Everything else on
    // this screen is required because it has no honest default; not having a
    // phone number is an honest answer, and on the sheet this screen shares
    // its validators with, a required email field would lock someone out of
    // their own app.
    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Required'), findsNothing,
        reason: 'blank is a legal answer to both');
    expect(find.textContaining('typo'), findsNothing);
    expect(find.text('Needs one @'), findsNothing);
    // Proof it got past validation rather than merely failing quietly: the
    // save is in flight. It cannot be awaited here — sqflite never completes
    // under the fake async testWidgets runs in, which is why the storage half
    // is driven directly further down.
    expect(find.text('Saving…'), findsOneWidget);
  });

  testWidgets('a malformed email is refused and nothing is written',
      (tester) async {
    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(5), 'gaj.example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Needs one @'), findsOneWidget);
    expect(find.text('Saving…'), findsNothing,
        reason: 'a rejected field must stop the save, not merely annotate it');
    expect(Profile.instance.email, '', reason: 'nothing may be written');
  });

  testWidgets('the cycle question follows sex, as it does on the sheet',
      (tester) async {
    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('First day of last period'), findsNothing);
    await tester.tap(find.text('Female'));
    await tester.pumpAndSettle();
    // Below the fold since the Contact card went in above it — see the drag
    // in the test above.
    await tester.dragUntilVisible(find.text('First day of last period'),
        find.byType(ListView), const Offset(0, -120));
    expect(find.text('First day of last period'), findsOneWidget);
  });

  testWidgets('a fractional age is refused rather than thrown on',
      (tester) async {
    // The rule this screen inherits from the sheet: the validator and the
    // parser have to agree. "48.5" once passed validation and then threw
    // FormatException in the save, leaving a spinner up and no error.
    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), '48.5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Whole numbers only'), findsOneWidget);
    expect(Profile.instance.age, 48, reason: 'nothing may be written');
  });

  testWidgets('a height typed in metres is refused', (tester) async {
    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(3), '1.8');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('typo'), findsWidgets);
    expect(Profile.instance.heightCm, 183);
  });

  testWidgets('cancelling leaves the screen and writes nothing',
      (tester) async {
    // Watched through the change stream rather than by reading the row back:
    // save() is the only thing that fires it, and a sqflite call inside
    // testWidgets never completes under fake async — asserting on storage
    // here hangs the suite rather than failing it.
    var fired = 0;
    // Torn down rather than awaited: awaiting anything that is not resolved
    // by a pump deadlocks the fake async this test runs under.
    final sub = Profile.instance.changes.listen((_) => fired++);
    addTearDown(sub.cancel);

    await tester.pumpWidget(openEditor());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), '60');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget, reason: 'it must be escapable — '
        'unlike the sheet, an edit always has an honest fallback');
    expect(Profile.instance.age, 48);
    expect(fired, 0, reason: 'cancelling must not reach storage at all');
  });

  // The persistence half is driven directly, as the onboarding tests are:
  // sqflite needs the real event loop, and testWidgets runs under fake async
  // where a database call never completes.
  test('an edit lands in SQLite and fires the change stream', () async {
    var fired = 0;
    final sub = Profile.instance.changes.listen((_) => fired++);

    await Profile.instance.updateDetails(
      name: 'Corrected Person',
      age: 60,
      sex: Sex.male,
      heightCm: 180,
      weightKg: 90.5,
    );
    // Broadcast delivery is asynchronous.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    final row = await Store.instance.readProfile();
    expect(row!['name'], 'Corrected Person');
    expect(row['age'], 60);
    expect(row['weight_kg'], 90.5);
    expect(fired, greaterThan(0),
        reason: 'without the event, Insights keeps showing figures derived '
            'from the old age and a card captioned "vs your 48"');
  });

  test('an edit with blank phone and email saves', () async {
    // The contract in one line: leaving both blank is not an error state,
    // and the save that follows is an ordinary successful save.
    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 48,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 136,
      phoneNumber: '',
      email: '',
    );

    expect(Profile.instance.phoneNumber, '');
    expect(Profile.instance.email, '');
    final row = await Store.instance.readProfile();
    expect(row, isNotNull, reason: 'a blank contact must not abort the write');
    expect(row!['name'], 'Test Person');
  });

  test('a contact that is given lands in SQLite', () async {
    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 48,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 136,
      phoneNumber: '+44 20 7946 0018',
      email: 'gaj@example.com',
    );

    final row = await Store.instance.readProfile();
    // Asserted against the row's VALUES rather than a column name: the
    // storage half of this change is another agent's file, and a test that
    // guesses at its column spelling fails for a reason that has nothing to
    // do with what it is checking.
    expect(row!.values, contains('gaj@example.com'));
    expect(row.values, contains('+44 20 7946 0018'));
  });

  test('correcting the cycle start replaces it rather than logging a second',
      () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 14),
    );
    // 13 days out, so completeOnboarding's 10-day mis-tap guard would not
    // have caught it: routed through that path both dates survive and phase
    // is counted from whichever sorts last.
    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 1),
    );
    expect(await Store.instance.readPeriodStarts(), [DateTime(2026, 8, 1)]);
  });

  test('a start a full cycle later is LOGGED, not swallowed as a correction',
      () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 1),
    );
    // The case the edit screen exists for, and the one that used to destroy
    // data: this screen removeLast()'d unconditionally, so a woman recording
    // that her period started today LOST the previous start — and cycle length,
    // which every phase calculation counts from, went with it.
    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 29),
    );
    expect(await Store.instance.readPeriodStarts(),
        [DateTime(2026, 8, 1), DateTime(2026, 8, 29)],
        reason: '28 days apart is a new cycle, not a correction of the first');
  });

  test('earlier cycles are left where they are', () async {
    await Store.instance.writePeriodStarts([
      DateTime(2026, 7, 1),
      DateTime(2026, 8, 14),
    ]);
    Profile.instance.periodStarts = await Store.instance.readPeriodStarts();

    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 1),
    );
    expect(await Store.instance.readPeriodStarts(),
        [DateTime(2026, 7, 1), DateTime(2026, 8, 1)]);
  });

  test('switching to male keeps the cycle history rather than erasing it',
      () async {
    await Store.instance.writePeriodStarts([DateTime(2026, 8, 14)]);
    Profile.instance.periodStarts = await Store.instance.readPeriodStarts();

    await Profile.instance.updateDetails(
      name: 'Test Person',
      age: 30,
      sex: Sex.male,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 1),
    );
    expect(await Store.instance.readPeriodStarts(), [DateTime(2026, 8, 14)],
        reason: 'correcting one field must not silently discard what is '
            'stored behind another');
  });
}
