/// First-run details sheet.
///
/// Asked once, because every metric downstream needs it: age drives VO2max,
/// strain and the BioAge comparison; height and weight drive the calorie and
/// distance figures; cycle phase needs a period start to count from.
///
/// It is deliberately BLOCKING and undismissable. The alternative — defaults
/// of 35 / 170 cm / 70 kg quietly standing in — is the failure mode this whole
/// project keeps running into: a plausible number that is not a measurement.
/// A wrong age does not throw, it just produces a believable VO2max.
library;

import 'package:flutter/material.dart';

import '../data/profile.dart';
import 'kit.dart';

/// Shows the sheet if it has not been completed, and does not return until it
/// has. Safe to call on every launch.
Future<void> ensureOnboarded(BuildContext context) async {
  final profile = Profile.instance;
  if (!profile.loaded) {
    try {
      await profile.load();
    } catch (_) {
      // Storage is broken. Showing the sheet anyway is the recovery path:
      // the user can still supply their details, and the app has somewhere
      // to put them once storage comes back. Throwing here would leave them
      // with no route to enter anything at all.
    }
  }
  if (profile.onboarded) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _OnboardingDialog(),
  );
}

/// Ranges are wide on purpose. They exist to catch a typo — a decimal point
/// in the wrong place, a height typed in metres — not to tell anyone their
/// body is out of bounds.
String? profileRange(String? v, String label, num lo, num hi,
    {String unit = '', bool whole = false}) {
  if (v == null || v.trim().isEmpty) return 'Required';
  final n = num.tryParse(v.trim());
  if (n == null) return 'Numbers only';
  if (n < lo || n > hi) return '$label looks like a typo ($lo–$hi$unit)';
  // ⚠ The validator and the parser have to agree on what they accept.
  // They did not: this accepted any num, so "48.5" passed here and then
  // int.parse threw FormatException in _submit — the sheet froze with the
  // spinner up and no error, because nothing catches it.
  if (whole && n != n.roundToDouble()) return 'Whole numbers only';
  return null;
}

/// The per-field rules, named rather than spelled out at each call site so
/// that the sheet and the edit screen cannot drift apart.
///
/// They already had: the Device tab's own editor allowed age 10–100 and
/// height 100–230 against this sheet's 5–120 and 80–250, so the same person
/// was editable in one place and a typo in the other.
String? validateName(String? v) =>
    (v == null || v.trim().isEmpty) ? 'Required' : null;
String? validateAge(String? v) => profileRange(v, 'Age', 5, 120, whole: true);
String? validateWeightKg(String? v) =>
    profileRange(v, 'Weight', 20, 400, unit: ' kg');
String? validateHeightCm(String? v) =>
    profileRange(v, 'Height', 80, 250, unit: ' cm', whole: true);

/// Contact details, and the only two answers here that are OPTIONAL —
/// blank returns null on purpose, from both of these.
///
/// Everything above is required because none of it has an honest default: a
/// stand-in age does not throw, it produces a believable VO2max. Contact
/// details DO have one — not having any. And the sheet these run on is
/// undismissable, so a required email field is not a nag, it is a lock on
/// the user's own app. An empty column is by far the cheaper bug.
///
/// Format is therefore checked only once something has been typed, and
/// loosely. A regex strict enough to be interesting rejects real addresses —
/// a +tag, a .museum, a two-letter domain — and "invalid" with no way past
/// is that same lockout arriving through a different door.
///
/// Both judge `v.trim()`, so both screens store the TRIMMED text. Same rule
/// as profileRange above: what the validator accepted and what gets written
/// have to be the same string. A trailing space surviving into storage is
/// the harmless-looking end of the disagreement that froze the sheet.
String? validateEmail(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return null;
  // Whitespace inside is the paste that brought the name along with the
  // address: "Gajendran <g@example.com>".
  if (s.contains(RegExp(r'\s'))) return 'No spaces';
  final at = s.indexOf('@');
  if (at <= 0 || at != s.lastIndexOf('@')) return 'Needs one @';
  final domain = s.substring(at + 1);
  if (!domain.contains('.') ||
      domain.startsWith('.') ||
      domain.endsWith('.') ||
      domain.contains('..')) {
    return 'Domain looks incomplete';
  }
  return null;
}

String? validatePhone(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return null;
  // Digits are counted; punctuation is not. +44 (0)20 7946 0018 and
  // 020-7946-0018 are one number written by two people, and refusing either
  // is the lockout again.
  if (s.contains(RegExp(r'[^0-9+()\-.\s]'))) return 'Digits only';
  // A + is a country prefix, so it means something at the front and nowhere
  // else.
  if (s.lastIndexOf('+') > 0) return 'Phone looks like a typo';
  final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
  // 15 is E.164's ceiling; the floor is low enough to admit a local number
  // typed without its area code. Wide on purpose, like the ranges above:
  // this is here to catch a slipped digit, not to rule on dialling plans.
  if (digits.length < 7 || digits.length > 15) {
    return 'Phone looks like a typo (7–15 digits)';
  }
  return null;
}

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final _form = GlobalKey<FormState>();

  // Pre-filled from whatever the profile already holds. On a phone upgrading
  // from an older build that is a real profile carried over from
  // SharedPreferences, so the sheet asks to confirm rather than to re-enter.
  late final _name = TextEditingController(text: Profile.instance.name);
  late final _age = TextEditingController(
      text: Profile.instance.age > 0 ? '${Profile.instance.age}' : '');
  late final _height = TextEditingController(
      text: Profile.instance.heightCm > 0
          ? '${Profile.instance.heightCm}'
          : '');
  late final _weight = TextEditingController(
      text: Profile.instance.weightKg > 0
          ? Profile.instance.weightKg.toStringAsFixed(0)
          : '');
  late final _phone = TextEditingController(text: Profile.instance.phoneNumber);
  late final _email = TextEditingController(text: Profile.instance.email);

  Sex _sex = Profile.instance.sex;
  DateTime? _periodStart = Profile.instance.periodStarts.isEmpty
      ? null
      : Profile.instance.periodStarts.last;
  bool _saving = false;

  /// Set only once the answers are stored.
  ///
  /// PopScope.canPop vetoes EVERY pop of the route, including the one
  /// this dialog makes when Save succeeds — not just the system back
  /// gesture. Flipping it first is what lets the sheet close itself while
  /// staying undismissable until then.
  bool _done = false;

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _pickPeriodStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _periodStart ?? now.subtract(const Duration(days: 14)),
      // A cycle start in the future is not a thing, and one more than a year
      // back tells the phase maths nothing useful.
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      helpText: 'First day of your last period',
    );
    if (picked != null) setState(() => _periodStart = picked);
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_sex == Sex.unspecified) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please choose male or female')));
      return;
    }
    if (_sex == Sex.female && _periodStart == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please set the first day of your last period')));
      return;
    }

    // Parsed with tryParse and a fallback even though the validator has
    // already passed: a validator and a parser that disagree is exactly how
    // this crashed before, and the sheet has no error path of its own.
    final age = num.tryParse(_age.text.trim())?.round();
    final height = num.tryParse(_height.text.trim())?.round();
    final weight = num.tryParse(_weight.text.trim())?.toDouble();
    if (age == null || height == null || weight == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please check the numbers')));
      return;
    }

    setState(() => _saving = true);
    try {
      await Profile.instance.completeOnboarding(
        name: _name.text,
        age: age,
        sex: _sex,
        heightCm: height,
        weightKg: weight,
        // Trimmed because that is the string the validator passed. Blank is a
        // legal answer to both and is stored as the empty string, not skipped.
        phoneNumber: _phone.text.trim(),
        email: _email.text.trim(),
        lastPeriodStart: _periodStart,
      );
    } catch (e) {
      // Storage failed. Do not trap the user behind an undismissable sheet.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    // PopScope reads canPop from the LAST BUILD, so the flag has to reach the
    // tree before the pop is attempted — otherwise the dialog vetoes its own
    // dismissal and Save appears to do nothing. A post-frame callback runs
    // after that rebuild; awaiting endOfFrame instead deadlocks under
    // pumpAndSettle, which stops pumping once nothing is left to settle.
    setState(() => _done = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return PopScope(
      // Undismissable until answered: the metrics downstream have no honest
      // default. Opens back up once Save has stored them.
      canPop: _done,
      child: AlertDialog(
        backgroundColor: kCard,
        title: const Text('About you'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ⚠ This used to end "Nothing is sent anywhere." That was
                  // already only true of a phone with no server configured —
                  // CloudSync PUTs the whole profile to /api/v1/profile — and
                  // printing it directly above an email field would have made
                  // it a promise about contact details specifically.
                  //
                  // The replacement then said "if you have pointed the app at
                  // your own server", which describes an opt-in the app does
                  // not have: `enabled` defaults TRUE and `baseUrl` defaults
                  // to a LAN address, so on a fresh install the profile is
                  // already being pushed to a server the user never chose. A
                  // privacy line that is conditional on a condition that is
                  // always met is worse than the sentence it replaced.
                  // Corrected rather than deleted: where the answers go is
                  // the reason someone hesitates over this sheet.
                  Text(
                    'Used for the derived metrics and stored on this phone. '
                    'Also sent to the server set on the Device tab, which is '
                    'on by default, and nowhere else.',
                    style: t.textTheme.bodySmall?.copyWith(color: kMuted),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: validateName,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _age,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Age'),
                    validator: validateAge,
                  ),
                  const SizedBox(height: 16),
                  Text('Sex', style: t.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SegmentedButton<Sex>(
                    segments: const [
                      ButtonSegment(value: Sex.female, label: Text('Female')),
                      ButtonSegment(value: Sex.male, label: Text('Male')),
                    ],
                    selected: {_sex},
                    emptySelectionAllowed: true,
                    onSelectionChanged: (s) =>
                        setState(() => _sex = s.isEmpty ? Sex.unspecified : s.first),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _weight,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Weight (kg)'),
                    validator: validateWeightKg,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _height,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Height (cm)'),
                    validator: validateHeightCm,
                  ),
                  const SizedBox(height: 12),
                  // "(optional)" is in the label rather than in a note
                  // underneath, because the note is what nobody reads. Save
                  // stays enabled with both of these blank — see
                  // validatePhone/validateEmail for why that is not
                  // negotiable on an undismissable sheet.
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'Phone (optional)'),
                    validator: validatePhone,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    // The one field on this sheet where autocorrect actively
                    // corrupts the answer: a capitalised first letter and a
                    // "helpfully" respelled domain are both wrong.
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: const InputDecoration(
                        labelText: 'Email (optional)'),
                    validator: validateEmail,
                  ),
                  // Only asked of those it applies to, and only because cycle
                  // phase has to be counted from a known start.
                  if (_sex == Sex.female) ...[
                    const SizedBox(height: 16),
                    Text('Cycle', style: t.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: _pickPeriodStart,
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(_periodStart == null
                          ? 'First day of last period'
                          : '${_periodStart!.day}/${_periodStart!.month}/'
                              '${_periodStart!.year}'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
