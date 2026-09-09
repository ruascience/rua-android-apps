/// User profile and manually logged events.
///
/// Kept separate from the band's own stored profile: opcode 0x02
/// (`CMD_SET_USERINFO`) writes height/weight/age *to the band*, which we do
/// not do — the band only needs it for its own on-device step/calorie maths,
/// and writing it is a device mutation we would rather not perform. Our
/// derived metrics use this local copy instead.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'store.dart';
import 'uuid.dart';

enum Sex { female, male, unspecified }

/// What the server knows about a band's profile — three answers, not two.
///
/// ⚠ [none] and [unreachable] are the trap. "The server has no profile for
/// this band" is a licence to mint a new id; "I could not ask" is not, and
/// collapsing the two into a nullable String is precisely how a phone ends up
/// minting an id for a person who already has one, and the user ends up with
/// two profiles.
enum ProfileLookup { found, none, unreachable }

/// The answer to "does the server already hold a profile for this band?".
class ProfileLookupResult {
  const ProfileLookupResult.found(String this.id)
      : outcome = ProfileLookup.found;
  const ProfileLookupResult.none()
      : id = null,
        outcome = ProfileLookup.none;
  const ProfileLookupResult.unreachable()
      : id = null,
        outcome = ProfileLookup.unreachable;

  final ProfileLookup outcome;

  /// The server's `_id` for this band, when [outcome] is [ProfileLookup.found].
  final String? id;
}

/// Asks the server for the profile filed under a band.
///
/// Injected rather than called directly so that this file stays free of HTTP:
/// the profile is storage and identity, the network belongs to CloudSync, and
/// a test can answer "the server is down" without a socket.
typedef ProfileIdLookup = Future<ProfileLookupResult> Function(
    String bandId, String? device);

/// Asks the server whether it holds ANY profile at all.
///
/// Returns true ONLY for a server that answered and said zero. Every other
/// state — it holds some, it could not be reached, it is an older build that
/// does not report the number — is false, because every one of them means
/// "we do not know", and not knowing is not a licence to mint.
///
/// This exists because a 404 from the by-band lookup is not the fact the
/// caller actually needs. 404 means "I did not find it", and there are at
/// least three ways to not find a profile that is really there: the migration
/// files it under one band's advertised name and this user has two; an
/// un-migrated document carries neither `band_id` nor `device`; a jar older
/// than this app has no by-band route at all and 404s the URL itself. A COUNT
/// is immune to all three — if the server holds no profiles, there is nothing
/// to duplicate.
typedef ProfileMintGate = Future<bool> Function();

class Profile {
  Profile._();
  static final Profile instance = Profile._();

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Fired whenever the profile is saved.
  ///
  /// Age feeds VO2max, strain and the BioAge comparison, so editing it on the
  /// Device tab has to invalidate those cards. Without this, changing age from
  /// 35 to 60 left Insights showing the old figures — and a card captioned
  /// "vs your 35" — until the next sync.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  static const _kAge = 'profile.age';
  static const _kSex = 'profile.sex';
  static const _kHeight = 'profile.height_cm';
  static const _kWeight = 'profile.weight_kg';
  static const _kPeriods = 'profile.period_starts';
  static const _kBandId = 'band.remote_id';
  static const _kBandName = 'band.internal_name';
  static const _kBandDisplay = 'band_display_name';

  int age = 35;
  Sex sex = Sex.unspecified;
  int heightCm = 170;
  double weightKg = 70;
  List<DateTime> periodStarts = [];

  /// The BLE address of the band we last connected to, and the internal name
  /// it reported via 0x3E.
  ///
  /// The ADVERTISED name is mutable — this band renamed itself from
  /// "JCV8B 44300D" to "V5" mid-session, which would drop it from a
  /// name-based match. The address is stable, so once we have met a band we
  /// recognise it regardless of what it calls itself.
  String? bandId;
  String? bandInternalName;

  /// The band's ADVERTISED name — the key samples are stored under.
  ///
  /// Kept separately from [bandInternalName] because they differ: the V5
  /// advertises "JCV5 6C6BB3" but reports "6C6BB3" to 0x3E. The store is
  /// keyed on the advertised one, so that is what the app needs to read its
  /// own history back while disconnected.
  String? bandDisplayName;

  /// The id the server files this person under: a v4 UUID.
  ///
  /// Null until it has been either adopted from the server or minted here —
  /// see [ensureProfileId], which is the only thing that may set it. Once set
  /// it is permanent. Regenerating it does not "fix" anything; it creates a
  /// second person on the server and orphans everything already pushed under
  /// the first.
  String? profileId;

  /// Contact details. Both OPTIONAL, and both stored as the empty string when
  /// not given rather than as null — the screens bind them straight to text
  /// fields, and one nullable String there is one null check away from a
  /// crash on a field that is allowed to be blank.
  ///
  /// Empty is written to SQLite as NULL, so "not answered" has exactly one
  /// representation in storage. It is read back as ''.
  String phoneNumber = '';
  String email = '';

  /// The person's name. Blank until onboarding collects it.
  String name = '';

  /// False until the first-run sheet has been completed.
  ///
  /// Stored in the database rather than inferred from "is age still 35?" —
  /// a real 35-year-old would otherwise be asked forever.
  bool onboarded = false;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Band identity stays in SharedPreferences; the person's details live in
  /// SQLite.
  ///
  /// They are different kinds of thing. The band id is connection scaffolding
  /// the app rewrites on every connect, while the profile is user data that
  /// belongs with the samples it feeds — same file, same backup, one export.
  Future<void> load() async {
    // Idempotent: main() loads once at startup and DevicePage asks again in
    // initState. Without this the profile is re-read from SQLite on every
    // page build, and in a widget test that leaves a live database timer
    // outliving the test that started it.
    if (_loaded) return;
    final p = await _p;
    bandId = p.getString(_kBandId);
    bandInternalName = p.getString(_kBandName);
    bandDisplayName = p.getString(_kBandDisplay);

    final row = await Store.instance.readProfile();
    if (row != null) {
      name = (row['name'] as String?) ?? '';
      age = (row['age'] as int?) ?? 35;
      sex = Sex.values[((row['sex'] as int?) ?? Sex.unspecified.index)
          .clamp(0, Sex.values.length - 1)];
      heightCm = (row['height_cm'] as int?) ?? 170;
      weightKg = (row['weight_kg'] as num?)?.toDouble() ?? 70;
      onboarded = ((row['onboarded'] as int?) ?? 0) == 1;
      final id = (row['profile_id'] as String?)?.trim();
      profileId = (id == null || id.isEmpty) ? null : id;
      phoneNumber = (row['phone'] as String?) ?? '';
      email = (row['email'] as String?) ?? '';
      periodStarts = await Store.instance.readPeriodStarts();
    } else {
      // First run on this schema. Anything already in SharedPreferences was
      // put there by an older build and is carried over rather than dropped —
      // one phone here had a real 48/183/136 profile that a naive migration
      // would have silently replaced with the defaults.
      age = p.getInt(_kAge) ?? 35;
      sex = Sex.values[(p.getInt(_kSex) ?? Sex.unspecified.index)
          .clamp(0, Sex.values.length - 1)];
      heightCm = p.getInt(_kHeight) ?? 170;
      weightKg = p.getDouble(_kWeight) ?? 70;
      periodStarts = (p.getStringList(_kPeriods) ?? [])
          .map(DateTime.tryParse)
          .whereType<DateTime>()
          .toList()
        ..sort();
      // Carried-over values still leave the sheet to run once: no older build
      // ever collected a name, so nobody is "already onboarded".
      onboarded = false;
      await save();
    }
    _loaded = true;
  }

  Future<void> save() async {
    await Store.instance.writeProfile(
      name: name,
      age: age,
      sex: sex.index,
      heightCm: heightCm,
      weightKg: weightKg,
      onboarded: onboarded,
      profileId: profileId,
      // Blank goes down as NULL: an empty string and a null would be two
      // storable spellings of "not answered", and the pusher would then have
      // to know which one the server means.
      phone: _orNull(phoneNumber),
      email: _orNull(email),
    );
    await Store.instance.writePeriodStarts(periodStarts);

    final p = await _p;
    if (bandId != null) await p.setString(_kBandId, bandId!);
    if (bandDisplayName != null) {
      await p.setString(_kBandDisplay, bandDisplayName!);
    }
    if (bandInternalName != null) {
      await p.setString(_kBandName, bandInternalName!);
    }
    _changes.add(null);
  }

  /// Record what the first-run sheet collected.
  Future<void> completeOnboarding({
    required String name,
    required int age,
    required Sex sex,
    required int heightCm,
    required double weightKg,
    String? phoneNumber,
    String? email,
    DateTime? lastPeriodStart,
  }) async {
    this.name = name.trim();
    this.age = age;
    this.sex = sex;
    this.heightCm = heightCm;
    this.weightKg = weightKg;
    _setContact(phoneNumber, email);
    if (sex == Sex.female && lastPeriodStart != null) {
      final d = DateTime(lastPeriodStart.year, lastPeriodStart.month,
          lastPeriodStart.day);
      if (!periodStarts.any((e) => e.difference(d).abs().inDays < 10)) {
        periodStarts
          ..add(d)
          ..sort();
      }
    }
    onboarded = true;
    await save();
  }

  /// Record an edit of those same details.
  ///
  /// Separate from [completeOnboarding] because the cycle start means a
  /// different thing here. Onboarding APPENDS the first start it is ever
  /// told about; an edit CORRECTS the one it appended. Routing the edit
  /// through completeOnboarding leaves both, because its 10-day guard only
  /// catches a mis-tap: a 14 August typo corrected to 1 August survives as a
  /// second cycle, and phase is then counted from whichever sorts last.
  ///
  /// Only the most recent start is replaced, because that is the one the
  /// screen shows; earlier cycles stay where they are. Switching sex to male
  /// leaves the whole list alone too — an edit screen correcting one field
  /// must not silently discard what is stored behind another.
  Future<void> updateDetails({
    required String name,
    required int age,
    required Sex sex,
    required int heightCm,
    required double weightKg,
    String? phoneNumber,
    String? email,
    DateTime? lastPeriodStart,
  }) async {
    this.name = name.trim();
    this.age = age;
    this.sex = sex;
    this.heightCm = heightCm;
    this.weightKg = weightKg;
    _setContact(phoneNumber, email);
    if (sex == Sex.female && lastPeriodStart != null) {
      final d = DateTime(
          lastPeriodStart.year, lastPeriodStart.month, lastPeriodStart.day);
      // Correction or new cycle? The screen cannot ask, so infer it from the
      // gap. The boundary sits at 15 days — below the ~21-day shortest
      // plausible cycle, so a real new period always clears it, and above a
      // fortnight of misremembering, so a correction never does.
      //
      // NOT the 10 days completeOnboarding dedupes with: correcting Aug 14
      // back to Aug 1 is a 13-day move, which 10 would misread as a second
      // cycle starting 13 days after the first.
      //
      // ⚠ This used to removeLast() unconditionally, which cannot tell the two
      // apart and always chose "correction". A user whose period started today
      // opens this screen, enters today, and silently LOSES the previous
      // start — so the cycle length that every phase calculation is counted
      // from is destroyed by the act of recording a cycle.
      const correctionWindow = 15;
      final near = periodStarts
          .where((e) => e.difference(d).abs().inDays < correctionWindow)
          .toList();
      if (near.isNotEmpty) {
        // A correction: drop the neighbours it supersedes. Also covers the
        // exact-same-day case, where two identical starts would otherwise read
        // as a one-day cycle.
        periodStarts.removeWhere((e) => near.contains(e));
      }
      periodStarts
        ..add(d)
        ..sort();
    }
    // save() is what fires [changes]; Insights and Home are listening, and
    // without the event they keep showing figures derived from the old age.
    await save();
  }

  /// Apply whatever the caller said about the two optional answers.
  ///
  /// ⚠ Null and '' mean different things, and both are legal.
  ///
  ///   null → the caller did not ask about this field; leave what is stored.
  ///   ''   → the caller asked and the answer is blank; CLEAR what is stored.
  ///
  /// Both cases are real. Anything that saves the profile without touching
  /// contact details passes null, and must not silently wipe an address it
  /// never showed the user. The edit screen passes the text field's contents
  /// even when empty, because deleting an address that is no longer yours is
  /// an edit — and folding '' into "unchanged" would make it the one edit the
  /// screen cannot perform.
  ///
  /// Trimmed, because that is the string the screens' validators judged. A
  /// trailing space surviving into storage is the harmless-looking half of a
  /// validator and a writer disagreeing about what the answer was.
  void _setContact(String? phone, String? mail) {
    // Whitespace is COLLAPSED, not just trimmed at the ends.
    //
    // The two validators disagree about what a space is. Ours treats every
    // `\s` as punctuation to be ignored, so a number pasted out of a contacts
    // app or a web page — where the separator is often a non-breaking space
    // or a tab — sails through the sheet. The server's pattern admits only a
    // literal U+0020, so it answers 400 on the same string, and a contact
    // detail the app shows as saved never reaches the server. Normalising
    // here means both sides see the same characters.
    if (phone != null) {
      phoneNumber = phone.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (mail != null) email = mail.trim();
  }

  static String? _orNull(String s) => s.trim().isEmpty ? null : s.trim();

  /// The id this profile is pushed under, adopting the server's before
  /// minting one. Null when the question is still open.
  ///
  /// ⚠ This is the whole defence against the two-UUID trap, and the trap is
  /// not hypothetical — there is one profile on the live server today whose
  /// `_id` is the band's ADVERTISED NAME, and the migration is about to give
  /// it a UUID. A phone that mints its own on upgrade would push under that
  /// second id, and the user would own two profiles: one with their history
  /// and one with their name.
  ///
  /// So the order is: stored id, then the server's, and only then a new one.
  ///
  /// The rule for the third step is stricter than "ask, and mint if that
  /// fails": it mints only on a DEFINITE no. A lookup that could not be made
  /// — server down, no lookup supplied, DNS, a 500 — leaves the question open
  /// and this returns null. Deferring costs nothing, because the only thing
  /// an id is needed for is a push, and a push needs the same server that
  /// just failed to answer. Minting on silence, by contrast, costs exactly
  /// the duplicate this method exists to prevent.
  ///
  /// Once set, it is never regenerated. There is no code path that clears it.
  Future<String?> ensureProfileId(
      {ProfileIdLookup? lookup, ProfileMintGate? mintGate}) async {
    final stored = profileId;
    if (stored != null && stored.isNotEmpty) return stored;

    final band = bandId;
    if (band != null && band.isNotEmpty) {
      // No lookup to ask with is the same state as a lookup that did not
      // answer: we do not know whether this band already has a profile, and
      // "do not know" is not a licence to mint.
      if (lookup == null) return null;
      final found = await lookup(band, bandDisplayName);
      final id = found.id;
      if (found.outcome == ProfileLookup.found && id != null && id.isNotEmpty) {
        profileId = id;
        await save();
        return profileId;
      }
      if (found.outcome != ProfileLookup.none) return null;
    }

    // The by-band lookup has looked and found nothing. That is still not
    // enough to mint on, because "found nothing" and "there is nothing" are
    // different facts and only the second one is safe.
    //
    // Three ways the lookup misses a profile that exists, all of them live on
    // this phone: the migration files the document under ONE band's
    // advertised name and this user has two; an un-migrated document carries
    // neither `band_id` nor `device` to match on; a server older than this
    // app has no by-band route, so the 404 is the URL, not the answer. In all
    // three the honest reading of 404 is "I did not find it".
    //
    // So the last word goes to a count, which cannot be wrong in that
    // direction: a server holding zero profiles has nothing to duplicate. No
    // gate, an unreachable server, or a build too old to report the number
    // all mean defer — which is free, because an id is only needed for a
    // push and a push needs the same server that just failed to answer.
    if (mintGate != null && !await mintGate()) return null;
    if (mintGate == null && bandId != null && bandId!.isNotEmpty) return null;

    profileId = uuidV4();
    await save();
    return profileId;
  }

  /// Mark the profile ready without touching storage. Tests only.
  ///
  /// Widget tests pump the whole app, and the Shell now blocks on the
  /// first-run sheet — which would otherwise cover every screen under test
  /// and needs both SharedPreferences and SQLite to answer.
  @visibleForTesting
  void markLoadedForTest({bool onboarded = true}) {
    _loaded = true;
    this.onboarded = onboarded;
  }

  /// Record what we know about the band we are talking to.
  ///
  /// `remoteId` is NULLABLE and is ignored when null or empty, which is the
  /// whole guard: [bandId] is the BLE address and it is now identity — the
  /// server stores it as `band_id` and matches profiles on it precisely
  /// because it survives the band renaming itself, which this hardware does
  /// ("JCV8B 44300D" -> "V5"). The recovery path in the pages knows only an
  /// advertised NAME, read back out of the samples table, and before this
  /// guard it passed that name in as the address whenever none was stored.
  /// That writes a mutable display name into the one field whose entire job
  /// is to be immutable, and nothing on either side of the wire can tell the
  /// difference afterwards. A caller with no address must pass none.
  Future<void> rememberBand(String? remoteId, String? internalName,
      {String? displayName}) async {
    if (remoteId != null && remoteId.isNotEmpty) bandId = remoteId;
    if (internalName != null && internalName.isNotEmpty) {
      bandInternalName = internalName;
    }
    if (displayName != null && displayName.isNotEmpty) {
      bandDisplayName = displayName;
    }
    await save();
  }

  Future<void> logPeriodStart(DateTime day) async {
    final d = DateTime(day.year, day.month, day.day);
    // Two starts within 10 days is a mis-tap, not two cycles.
    periodStarts.removeWhere((e) => e.difference(d).abs().inDays < 10);
    periodStarts.add(d);
    periodStarts.sort();
    await save();
  }

  Future<void> removePeriodStart(DateTime day) async {
    periodStarts.removeWhere((e) =>
        e.year == day.year && e.month == day.month && e.day == day.day);
    await save();
  }
}
