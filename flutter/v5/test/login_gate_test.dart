import 'package:aurav5/data/profile.dart';
import 'package:aurav5/data/session.dart';
import 'package:aurav5/main.dart';
import 'package:aurav5/ui/login_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => Profile.instance.markLoadedForTest());

  testWidgets('with no session the app shows the login screen and nothing else',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Session.instance.load();

    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    expect(find.byType(LoginPage), findsOneWidget);
    // The tabs must not be reachable: every reading the app collects needs an
    // owner, and a shell behind an unsigned session would collect all day and
    // be unable to file any of it.
    expect(find.text('Today'), findsNothing);
    expect(find.text('Band'), findsNothing);
  });

  testWidgets('sign-up is not offered until the server says it is allowed',
      (tester) async {
    // Self sign-up exists now — a participant should not wait on an admin to
    // be let in. But whether THIS server allows it is the server's answer,
    // not the build's, and until it arrives the app must not offer a button
    // that would only lead to a refusal. No server is reachable in a test, so
    // this is also what an offline or older server looks like.
    SharedPreferences.setMockInitialValues({});
    await Session.instance.load();
    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    expect(find.text('Create an account'), findsNothing);
    expect(find.textContaining('Accounts are created by the study team'),
        findsOneWidget);
  });

  testWidgets('a restored session goes straight to the app', (tester) async {
    SharedPreferences.setMockInitialValues({
      'session.username': 'tester',
      'session.token': 'test-token',
      'session.profile_id': 'test-profile',
      'session.role': 'user',
    });
    await Session.instance.load();

    await tester.pumpWidget(const AuraV5App());
    await tester.pump();

    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('Today'), findsWidgets);
  });

  test('an admin session is marked as one', () async {
    SharedPreferences.setMockInitialValues({
      'session.username': 'operator',
      'session.token': 't',
      'session.role': 'admin',
    });
    await Session.instance.load();
    expect(Session.instance.isAdmin, isTrue);
    expect(Session.instance.signedIn, isTrue);
  });

  test('a session with a username but no token is not signed in', () async {
    // The half-restored case: preferences that kept the name and lost the
    // token. Treating that as signed in would show the app and then 401 on
    // every request with no way back to the login screen.
    SharedPreferences.setMockInitialValues({'session.username': 'tester'});
    await Session.instance.load();
    expect(Session.instance.signedIn, isFalse);
  });
}
