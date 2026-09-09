/// A v4 UUID, minted on the phone.
///
/// No package for this. `uuid` would do it in one line, and would pull a
/// dependency in for sixteen random bytes and a hex string — the whole of
/// RFC 4122 §4.4 that we need is below, and it can be read end to end in less
/// time than it takes to check what a pubspec entry brought with it.
library;

import 'dart:math';
import 'dart:typed_data';

/// [Random.secure], not [Random].
///
/// The default generator is seeded from the clock, and a profile id is the
/// one value in this app that must never collide with another install's: two
/// phones finishing onboarding in the same millisecond would mint the same
/// id and then quietly write to the same server document. secure() draws from
/// the platform CSPRNG and THROWS where one is unavailable rather than
/// falling back to something weaker, which is the failure we would want to
/// hear about rather than the one we would not.
final Random _entropy = Random.secure();

const _hex = '0123456789abcdef';

/// A version-4, variant-1 UUID in canonical 8-4-4-4-12 form.
String uuidV4() {
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = _entropy.nextInt(256);
  }
  // The two nibbles that are NOT random, and the reason this is a UUID rather
  // than 128 bits that merely look like one. Version says how the id was
  // made and variant says whose layout it follows; a reader entitled to check
  // them — Java's UUID.fromString, Mongo's UUID binary subtype, half the
  // validators on the wire — will reject or mis-sort an id that claims
  // neither.
  b[6] = (b[6] & 0x0f) | 0x40; // version 4: random
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx: RFC 4122
  final s = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s
      ..write(_hex[b[i] >> 4])
      ..write(_hex[b[i] & 0x0f]);
  }
  return s.toString();
}

/// Is this a canonical v4 UUID — version nibble 4, variant 8/9/a/b?
///
/// Used at the ADOPTION boundary, not just at mint. The phone takes its
/// profile id from whatever the server hands back, and that id becomes
/// permanent: nothing clears it. So the one thing that must never be adopted
/// is the pre-migration key, which is the band's ADVERTISED NAME — adopting it
/// would leave the phone pushing to a document the migration is about to move
/// to a UUID, which is the duplicate-profile trap arriving through the other
/// door. Checking the shape is cheaper than trusting every route that can
/// return a document.
bool isUuidV4(String s) => _v4.hasMatch(s);

final RegExp _v4 = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}'
    r'-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');
