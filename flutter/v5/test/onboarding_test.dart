import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aurav5/data/profile.dart';
import 'package:aurav5/data/store.dart';
import 'package:aurav5/main.dart';
import 'package:aurav5/ui/onboarding.dart';

/// The first-run sheet exists because the alternative is worse: defaults of
/// 35 / 170 cm / 70 kg standing in silently. A wrong age does not throw, it
/// produces a believable VO2max — the same failure mode this project keeps
/// meeting on the protocol side.
void main() {
  setUp(() async {
    // Band identity still lives in SharedPreferences, and save() writes it —
    // without a mock the plugin channel throws and the sheet never closes.
    SharedPreferences.setMockInitialValues({});
    await Store.instance.resetForTest();
    Profile.instance.markLoadedForTest(onboarded: false);
    Profile.instance.name = '';
    Profile.instance.sex = Sex.unspecified;
    Profile.instance.phoneNumber = '';
    Profile.instance.email = '';
    Profile.instance.periodStarts = [];
  });

  /// Phone and email are the only optional answers on the sheet, and the
  /// reason is structural rather than cosmetic: this dialog is undismissable,
  /// so a field that can refuse to be satisfied is a lock on the app. Blank
  /// has to pass, and the format check only ever runs on something typed.
  group('the optional contact validators', () {
    test('blank passes both — this is the lockout guard', () {
      expect(validatePhone(''), isNull);
      expect(validateEmail(''), isNull);
      expect(validatePhone('   '), isNull, reason: 'a space is still blank');
      expect(validateEmail('  '), isNull);
      expect(validatePhone(null), isNull);
      expect(validateEmail(null), isNull);
    });

    test('a malformed email is refused', () {
      expect(validateEmail('gaj.example.com'), isNotNull);
      expect(validateEmail('@example.com'), isNotNull);
      expect(validateEmail('gaj@'), isNotNull);
      expect(validateEmail('gaj@@example.com'), isNotNull);
      expect(validateEmail('gaj@example'), isNotNull,
          reason: 'a domain with no dot is the half-typed one');
      expect(validateEmail('gaj@example..com'), isNotNull);
      expect(validateEmail('Gajendran <gaj@example.com>'), isNotNull,
          reason: 'the paste that brings the name along with the address');
    });

    test('real addresses are not refused by a clever regex', () {
      // The failure this rules out is the opposite one and is worse on an
      // undismissable sheet: "invalid" shown to someone whose address is fine.
      expect(validateEmail('gaj@example.com'), isNull);
      expect(validateEmail('gaj+band@example.co.uk'), isNull);
      expect(validateEmail('g.a.j_99@sub.example.museum'), isNull);
      expect(validateEmail('  gaj@example.com  '), isNull,
          reason: 'trimmed before judging, and stored the same way');
    });

    test('a phone is judged on its digits, not its punctuation', () {
      expect(validatePhone('+44 20 7946 0018'), isNull);
      expect(validatePhone('(020) 7946-0018'), isNull);
      expect(validatePhone('9840012345'), isNull);
      expect(validatePhone('123'), isNotNull, reason: 'a slipped number');
      expect(validatePhone('1234567890123456'), isNotNull,
          reason: 'longer than E.164 allows');
      expect(validatePhone('call me'), isNotNull);
      expect(validatePhone('020+7946'), isNotNull,
          reason: 'a + means something at the front and nowhere else');
    });
  });

  testWidgets('it blocks the app until it is filled in', (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pumpAndSettle();

    expect(find.text('About you'), findsOneWidget);

    // Undismissable on purpose — there is no honest default to fall back to.
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget,
        reason: 'tapping outside must not dismiss it');
  });

  testWidgets('it refuses to save an empty or nonsense answer',
      (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);
    expect(Profile.instance.onboarded, isFalse);

    // A height typed in metres is the classic one.
    await tester.enterText(find.byType(TextFormField).at(3), '1.8');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('typo'), findsWidgets);
    expect(Profile.instance.onboarded, isFalse);
  });

  /// Fills the four answers that ARE required, so a test can go on to say
  /// something about the two that are not.
  Future<void> fillTheRequiredAnswers(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'Test Person');
    await tester.enterText(find.byType(TextFormField).at(1), '48');
    await tester.enterText(find.byType(TextFormField).at(2), '136');
    await tester.enterText(find.byType(TextFormField).at(3), '183');
    // ensureVisible first: entering the height scrolls the sheet down to the
    // focused field, and with two more fields below it that carries the sex
    // buttons out of the dialog's clip rect. tap() then MISSES — and only
    // warns, so the sheet simply stayed on "choose male or female" and the
    // test failed somewhere else entirely.
    await tester.ensureVisible(find.text('Male'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Male'));
    await tester.pumpAndSettle();
  }

  testWidgets('it saves with phone and email left blank', (tester) async {
    // The one that matters. This sheet cannot be dismissed, so a contact
    // field that can refuse to be satisfied is a lock on the user's own app —
    // a worse bug by far than an empty column.
    await tester.pumpWidget(const AuraV5App());
    await tester.pumpAndSettle();
    await fillTheRequiredAnswers(tester);

    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Required'), findsNothing,
        reason: 'blank is a legal answer to both contact fields');
    // The save is in flight, which is the proof it was not blocked. It is not
    // awaited: sqflite never completes under the fake async testWidgets runs
    // in, so the storage half is driven directly below.
    expect(find.text('Saving…'), findsOneWidget);
  });

  testWidgets('a malformed email is refused, and blocks the save',
      (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pumpAndSettle();
    await fillTheRequiredAnswers(tester);

    await tester.enterText(find.byType(TextFormField).at(5), 'gaj.example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Needs one @'), findsOneWidget);
    expect(find.text('Saving…'), findsNothing);
    expect(Profile.instance.onboarded, isFalse,
        reason: 'optional does not mean unchecked — a typo caught here is a '
            'typo not carried to the server on every profile push');
  });

  testWidgets('the cycle question is asked only when it applies',
      (tester) async {
    await tester.pumpWidget(const AuraV5App());
    await tester.pumpAndSettle();

    expect(find.text('First day of last period'), findsNothing);

    await tester.tap(find.text('Female'));
    await tester.pumpAndSettle();
    expect(find.text('First day of last period'), findsOneWidget);

    await tester.tap(find.text('Male'));
    await tester.pumpAndSettle();
    expect(find.text('First day of last period'), findsNothing,
        reason: 'cycle phase is counted from a start date; asking everyone '
            'for one collects data that means nothing');
  });

  // The persistence contract is tested directly rather than through the
  // widget. sqflite needs the real event loop, and testWidgets runs under
  // fake async where a database call never completes — driving it through
  // taps tests the harness more than the code.
  test('completing onboarding lands in SQLite, not just in memory', () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 48,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 136,
    );

    final row = await Store.instance.readProfile();
    expect(row, isNotNull);
    expect(row!['name'], 'Test Person');
    expect(row['age'], 48);
    expect(row['sex'], Sex.male.index);
    expect(row['height_cm'], 183);
    expect(row['weight_kg'], 136.0);
    expect(row['onboarded'], 1,
        reason: 'the flag is what stops the sheet asking again');
  });

  test('onboarding completes with no contact details at all', () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 48,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 136,
      phoneNumber: '',
      email: '',
    );

    final row = await Store.instance.readProfile();
    expect(row!['onboarded'], 1,
        reason: 'the sheet has to be able to close on an answer of "none"');
    expect(Profile.instance.phoneNumber, '');
    expect(Profile.instance.email, '');
  });

  test('a contact that is given is stored', () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 48,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 136,
      phoneNumber: '+44 20 7946 0018',
      email: 'gaj@example.com',
    );

    final row = await Store.instance.readProfile();
    // Checked against the row's values rather than a column name: the storage
    // half of this change belongs to another file, and a test that guesses at
    // its column spelling fails for a reason unrelated to what it asserts.
    expect(row!.values, contains('gaj@example.com'));
    expect(row.values, contains('+44 20 7946 0018'));
  });

  test('a female profile stores the cycle start it was given', () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 30,
      sex: Sex.female,
      heightCm: 165,
      weightKg: 60,
      lastPeriodStart: DateTime(2026, 8, 14, 9, 30),
    );
    expect(await Store.instance.readPeriodStarts(), [DateTime(2026, 8, 14)]);
  });

  test('a male profile stores no cycle start even if one is passed', () async {
    await Profile.instance.completeOnboarding(
      name: 'Test Person',
      age: 30,
      sex: Sex.male,
      heightCm: 183,
      weightKg: 90,
      lastPeriodStart: DateTime(2026, 8, 14),
    );
    expect(await Store.instance.readPeriodStarts(), isEmpty);
  });

  testWidgets('ensureOnboarded is a no-op once complete', (tester) async {
    Profile.instance.markLoadedForTest(onboarded: true);
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ensureOnboarded(c);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  group('period starts round-trip through the database', () {
    test('written and read back as whole days', () async {
      await Store.instance.writePeriodStarts([
        DateTime(2026, 8, 14, 9, 30),
        DateTime(2026, 7, 17),
      ]);
      final back = await Store.instance.readPeriodStarts();
      expect(back, hasLength(2));
      expect(back.first, DateTime(2026, 7, 17));
      expect(back.last, DateTime(2026, 8, 14),
          reason: 'a cycle start is a day, not a moment');
    });

    test('rewriting replaces rather than accumulating', () async {
      await Store.instance.writePeriodStarts([DateTime(2026, 8, 14)]);
      await Store.instance.writePeriodStarts([DateTime(2026, 8, 14)]);
      expect(await Store.instance.readPeriodStarts(), hasLength(1));
    });
  });
}
