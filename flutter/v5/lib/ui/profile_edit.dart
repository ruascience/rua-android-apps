/// Editing the details the first-run sheet collected.
///
/// The sheet asks once, and until this screen existed that was the only time
/// anyone was ever asked — so a typo at install time was permanent. It does
/// not announce itself either: age feeds VO2max, strain and the BioAge
/// comparison, height and weight feed the calorie and distance figures, and a
/// wrong one produces a believable number rather than an error.
///
/// The sheet's opposite in one respect, on purpose. Onboarding is
/// undismissable because there is no honest default to fall back to; an edit
/// always has one — whatever is already stored — so Cancel is there, the back
/// gesture works, and neither writes anything. That is why there is no
/// PopScope here.
///
/// The validation rules come from onboarding.dart rather than being restated:
/// two sets of bounds that disagree is the state this screen replaces.
library;

import 'package:flutter/material.dart';

import '../data/profile.dart';
import 'kit.dart';
import 'onboarding.dart';

/// Weight as the person would write it: 70 rather than 70.0, and 60.5 kept.
///
/// The first-run sheet prefills with `toStringAsFixed(0)` because it is
/// asking you to confirm a number carried over from an older build. Here the
/// field IS the stored value, and rounding 60.5 to 61 the moment the screen
/// opens would rewrite a weight nobody touched.
String formatWeightKg(double kg) =>
    kg == kg.roundToDouble() ? kg.toStringAsFixed(0) : '$kg';

/// Pushed from the Device tab. Pops `true` once the edit is stored, and null
/// on cancel — nothing is written on that path.
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  final _form = GlobalKey<FormState>();
  final profile = Profile.instance;

  late final _name = TextEditingController(text: profile.name);
  late final _age =
      TextEditingController(text: profile.age > 0 ? '${profile.age}' : '');
  late final _height = TextEditingController(
      text: profile.heightCm > 0 ? '${profile.heightCm}' : '');
  late final _weight = TextEditingController(
      text: profile.weightKg > 0 ? formatWeightKg(profile.weightKg) : '');
  // Straight through, unlike the numbers above: these are stored as the
  // person typed them, so there is nothing to format and nothing to round.
  late final _phone = TextEditingController(text: profile.phoneNumber);
  late final _email = TextEditingController(text: profile.email);

  late Sex _sex = profile.sex;

  /// The start being corrected. The sheet stores the one it collected as the
  /// last entry, so that is the one this screen shows and replaces.
  late DateTime? _periodStart =
      profile.periodStarts.isEmpty ? null : profile.periodStarts.last;

  bool _saving = false;

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
    var initial = _periodStart ?? now.subtract(const Duration(days: 14));
    // showDatePicker asserts when initialDate falls outside its range, and
    // this screen opens on whatever is already on file rather than on a date
    // it just chose. A profile last touched 14 months ago — or one carrying a
    // start typed with the wrong year — would otherwise crash the picker on
    // the way to being fixed.
    if (initial.isAfter(now)) initial = now;
    final yearAgo = now.subtract(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(yearAgo) ? initial : yearAgo,
      lastDate: now,
      helpText: 'First day of your last period',
    );
    if (picked != null) setState(() => _periodStart = picked);
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    // Captured before the awaits: the screen may be gone by the time an error
    // comes back, and the messenger above the route is still there.
    final messenger = ScaffoldMessenger.of(context);

    if (_sex == Sex.unspecified) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Please choose male or female')));
      return;
    }
    if (_sex == Sex.female && _periodStart == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Please set the first day of your last period')));
      return;
    }

    // Parsed with tryParse and a fallback even though the validator has
    // already passed, for the reason recorded in profileRange: a validator
    // and a parser that disagreed once froze the sheet with the spinner up
    // and no error, and nothing about that changes on this screen.
    final age = num.tryParse(_age.text.trim())?.round();
    final height = num.tryParse(_height.text.trim())?.round();
    final weight = num.tryParse(_weight.text.trim())?.toDouble();
    if (age == null || height == null || weight == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Please check the numbers')));
      return;
    }

    setState(() => _saving = true);
    try {
      await profile.updateDetails(
        name: _name.text,
        age: age,
        sex: _sex,
        heightCm: height,
        weightKg: weight,
        // Trimmed to match what the validator judged, and passed even when
        // empty: clearing an address that is no longer yours is an edit, and
        // skipping the blank case would make it the one edit this screen
        // cannot perform.
        phoneNumber: _phone.text.trim(),
        email: _email.text.trim(),
        lastPeriodStart: _periodStart,
      );
    } catch (e) {
      // Storage can fail — a full disk, a half-applied migration. Say so and
      // leave the screen up with the answers still in it, rather than popping
      // as though it had worked or freezing on a spinner that never clears.
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your details')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            SectionCard(
              title: 'About you',
              subtitle:
                  'used only for the derived metrics, stored on this phone',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                    // A profile carried over from an older build can still be
                    // Sex.unspecified, which matches neither segment. Without
                    // this the button has no legal state to render.
                    emptySelectionAllowed: true,
                    onSelectionChanged: (s) => setState(
                        () => _sex = s.isEmpty ? Sex.unspecified : s.first),
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
                ],
              ),
            ),
            // Its own card rather than two more rows in "About you", which
            // says "used only for the derived metrics" — true of every field
            // above it and of neither of these. A subtitle that is false for
            // the bottom two fields of the card it heads is how a screen
            // starts lying quietly.
            const SizedBox(height: 12),
            SectionCard(
              title: 'Contact',
              subtitle: 'both optional — Save works with them blank',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'Phone (optional)'),
                    validator: validatePhone,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    // Autocorrect is the one thing that can corrupt an
                    // address between typing it and saving it: a capitalised
                    // first letter, a respelled domain.
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration:
                        const InputDecoration(labelText: 'Email (optional)'),
                    validator: validateEmail,
                  ),
                ],
              ),
            ),
            // Only asked of those it applies to, exactly as the sheet asks it:
            // cycle phase has to be counted from a known start, and collecting
            // one from everybody else stores a date that means nothing.
            if (_sex == Sex.female) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Cycle',
                subtitle: 'phase is counted from the day this period started',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _pickPeriodStart,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_periodStart == null
                        ? 'First day of last period'
                        : '${_periodStart!.day}/${_periodStart!.month}/'
                            '${_periodStart!.year}'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A date close to one already logged corrects it; a date '
                'further out is recorded as a new cycle. Earlier cycles are '
                'left alone either way.',
                style: t.textTheme.bodySmall?.copyWith(color: kMuted),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Saving re-derives everything these feed — VO₂max, strain, the '
              'BioAge comparison, calories and distance. Insights and Home '
              'pick the new figures up straight away rather than at the next '
              'sync.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted),
            ),
          ],
        ),
      ),
      // Pinned rather than sitting at the end of the list. Six fields and
      // their notes are taller than a phone screen, and a Save the user has
      // to go looking for is how an edit gets abandoned half-typed.
      persistentFooterButtons: [
        OutlinedButton(
          // Cancel writes nothing. Disabled only while a save is actually in
          // flight, so the screen can never be left with a half-applied edit
          // behind it.
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
