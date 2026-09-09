/// What is known about the **JCVital V5** — and, just as importantly, what is
/// only *assumed* because it was true of a different band.
///
/// ## The problem this file exists to prevent
///
/// The V5 has no public SDK, no protocol document, no GATT dump, and no
/// third-party code anywhere. Everything in this app's protocol layer was
/// established on a **JCVital Pro V8**, and carrying it over is a hypothesis,
/// not a finding.
///
/// It would be very easy — and completely wrong — to ship the V8's results
/// under a V5 label. A band that answers on the same characteristics is not
/// thereby proven to use the same record layouts, and a decode that is right
/// for one and wrong for another produces plausible numbers rather than
/// obvious failures. That is the dangerous kind of wrong.
///
/// So every entry carries [Finding.provenance]. Nothing reaches
/// [FindingStatus.confirmed] for the V5 until it has been checked **on the
/// V5**. Until then it is [FindingStatus.assumed], and the app says so.
library;

/// How settled a finding is *for the V5*.
enum FindingStatus {
  /// Established on a V5, on hardware.
  confirmed,

  /// Carried over from another band and NOT yet checked here. Treat every
  /// number as a hypothesis.
  assumed,

  /// Investigated on a V5 to a conclusion that closed the question.
  closed,

  /// A claim the V5 contradicted.
  refuted,

  /// Unknown, and not yet attempted.
  open,
}

extension FindingStatusLabel on FindingStatus {
  String get label => switch (this) {
        FindingStatus.confirmed => 'CONFIRMED ON V5',
        FindingStatus.assumed => 'ASSUMED — NOT VERIFIED ON V5',
        FindingStatus.closed => 'CLOSED',
        FindingStatus.refuted => 'REFUTED',
        FindingStatus.open => 'OPEN',
      };

  /// True when this app must not present the finding as fact.
  bool get isProvisional =>
      this == FindingStatus.assumed || this == FindingStatus.open;
}

/// Where a finding actually came from.
enum FindingProvenance { v5Hardware, v8Hardware, vendorSdk, none }

extension FindingProvenanceLabel on FindingProvenance {
  String get label => switch (this) {
        FindingProvenance.v5Hardware => 'measured on a V5',
        FindingProvenance.v8Hardware => 'measured on a V8 — a different band',
        FindingProvenance.vendorSdk => 'vendor SDK / third-party code',
        FindingProvenance.none => 'not established anywhere',
      };
}

enum FindingArea { transport, framing, paging, records, sensors, safety }

extension FindingAreaLabel on FindingArea {
  String get label => switch (this) {
        FindingArea.transport => 'Transport',
        FindingArea.framing => 'Framing',
        FindingArea.paging => 'History paging',
        FindingArea.records => 'Record layouts',
        FindingArea.sensors => 'Sensors',
        FindingArea.safety => 'Safety',
      };
}

class Finding {
  final String id;
  final String title;
  final FindingStatus status;
  final FindingProvenance provenance;
  final FindingArea area;
  final String summary;
  final String evidence;

  /// What must be done on a V5 to promote this out of [FindingStatus.assumed].
  final String howToVerify;

  final String supersedes;
  final List<int> opcodes;

  const Finding({
    required this.id,
    required this.title,
    required this.status,
    required this.provenance,
    required this.area,
    required this.summary,
    required this.evidence,
    this.howToVerify = '',
    this.supersedes = '',
    this.opcodes = const [],
  });

  bool get correctsSomething => supersedes.isNotEmpty;

  /// True when the app must not present this as established fact about the V5.
  bool get isProvisional => status.isProvisional;
}

/// The V5 corpus.
///
/// Note the shape of it: almost everything is ASSUMED. That is the honest
/// state of knowledge for this band, and the app is built to change it.
const List<Finding> findings = [
  // ------------------------------------------- the overall state of play
  Finding(
    id: 'v5-unknown',
    title: 'The V5 is undocumented — what is known here was measured, not read',
    status: FindingStatus.open,
    provenance: FindingProvenance.none,
    area: FindingArea.transport,
    summary: 'The JCVital V5 still has no public SDK, protocol document or '
        'GATT dump anywhere. Everything below marked CONFIRMED was measured '
        'directly on band JCV5 6C6BB3; everything marked ASSUMED is a '
        'hypothesis carried from a JCVital Pro V8 and may not hold. The '
        'transport and three record layouts are now settled; the sensor '
        'story is not.',
    evidence: 'Searched for SDK, docs, GATT information and code: only V8 and '
        'V8 Pro appear publicly. A read-only probe on 2026-08-27 supplied '
        'everything now marked CONFIRMED; the sensor questions below are not '
        'attempted.',
    howToVerify: 'The remaining gaps are listed as ASSUMED and OPEN below, '
        'each with its own route to resolution.',
  ),

  // =================================================== CONFIRMED ON A V5
  // Established 2026-08-27 against band "JCV5 6C6BB3" over BLE, read-only.
  Finding(
    id: 'v5-gatt',
    title: 'GATT matches the J-Style family exactly',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.transport,
    summary: 'Service fff0 with write fff6 (write / write-without-response / '
        'read) and notify fff7. The undocumented 0000190e service is present '
        'too, with chars 0004 (write/read) and 0003 (notify) — the same shape '
        'the V8 carries and the vendor app never uses.',
    evidence: 'Full GATT dump of JCV5 6C6BB3. Reading fff6 directly returned '
        'a live 16-byte frame: 09 01 00..00 0a.',
  ),
  Finding(
    id: 'v5-frame-format',
    title: '16-byte frames confirmed — but the V5 does NOT check the checksum',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.framing,
    opcodes: [0x3E],
    summary: 'Frames are 16 bytes, [0]=opcode [1]=mode [2..14]=payload '
        '[15]=checksum, and the band GENERATES a plain sum. But it ACCEPTS '
        'any checksum: sum, xor, sum_inv, sum_plus1 and even none all got '
        'identical replies. Checksum detection is therefore meaningless here '
        '— a wrong checksum will not tell you your frame was malformed.',
    evidence: 'csdetect against 0x3E: all five variants answered identically. '
        'The frame read back from fff6 (09 01 .. 0a) carries a correct sum, '
        'so the band generates one even though it does not validate one.',
    supersedes: 'The assumption, carried from the V8, that a silent band '
        'means a wrong checksum. On a V5 that diagnostic does not work.',
  ),
  Finding(
    id: 'v5-model-string',
    title: '0x3E returns the device id, NOT a protocol-family string',
    status: FindingStatus.refuted,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.transport,
    opcodes: [0x3E],
    summary: 'A V5 answers 0x3E with "6C6BB3" — its own id, matching the '
        'advertised name JCV5 6C6BB3. It does NOT return a family string. So '
        'the model discriminator that works on the V8 (which answers '
        '"J2208   B920") cannot identify the family on a V5.',
    evidence: 'Reply: 3e 36 43 36 42 42 33 00 .. = ASCII "6C6BB3", 24 bytes.',
    supersedes: 'That 0x3E is a reliable protocol-family discriminator across '
        'this vendor\'s bands. It is not — on the V5 it identifies the unit, '
        'not the protocol.',
  ),
  Finding(
    id: 'v5-bcd',
    title: 'Timestamps are BCD, as on the V8',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.framing,
    summary: 'Record timestamps decode as BCD year/month/day/hour/min/sec.',
    evidence: 'Actigraphy records decoded to 2026-08-27 12:37:59 and counted '
        'backwards exactly one minute per record, matching wall-clock time at '
        'the moment of capture.',
  ),
  Finding(
    id: 'v5-record-index',
    title: 'Record index is LE16 at [1:3]',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    summary: 'Indices increment sequentially from 0 across a pull.',
    evidence: 'Observed 0,1,2,… on both 0x54 and 0x58 pulls.',
  ),
  Finding(
    id: 'v5-hr-0x54',
    title: '0x54 heart rate: 24-byte records, 15 slots at 5 s, 75 s apart',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    opcodes: [0x54],
    summary: 'The V8 layout decodes exactly. Records are 24 bytes; timestamps '
        'are 75 s apart, which only fits 15 slots at 5 s spacing. Values read '
        '83–103 bpm, which is plausible for a band just handled.',
    evidence: '18 consistent 24-byte strides. Timestamps 12:37:18, 12:36:03, '
        '12:34:48, 12:33:33 — exactly 75 s apart. This independently confirms '
        'the 5 s sample interval first measured on a V8.',
  ),
  Finding(
    id: 'v5-actigraphy-0x58',
    title: '0x58 per-minute actigraphy is present, 35-byte records',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    opcodes: [0x58],
    summary: 'The richest stream on this band, exactly as on the V8, and the '
        'vendor app exposes nothing like it. 35-byte records at one-minute '
        'resolution carrying six LE uint16 motion-energy values.',
    evidence: '299 consistent 35-byte strides in a single pull; timestamps '
        'decrement exactly one minute per record.',
  ),
  Finding(
    id: 'v5-daily-0x51',
    title: '0x51 daily totals decode, and cross-check against 0x09',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    opcodes: [0x51, 0x09],
    summary: 'Records are 27 bytes: [2:5] BCD date, [5:9] steps, [9:13] '
        'active seconds, [13:17] decametres, [17:21] 0.01 kcal.',
    evidence: 'Decoded 2026-08-27 as 54 steps / 23 active s / 3 decametres / '
        '1.48 kcal — and the live 0x09 realtime frame reported the SAME four '
        'values independently. Two separate opcodes agreeing is what makes '
        'this a decode rather than a guess.',
  ),
  Finding(
    id: 'v5-no-hrv-sleep-temp-spo2',
    title: 'The V5 returns NO HRV, sleep, temperature or SpO2 history',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x56, 0x53, 0x3B, 0x44],
    summary: 'Every one of these answered with the empty marker: 0x56 HRV, '
        '0x53 sleep, 0x3B temperature and 0x44 SpO2 all returned byte[1]=0xFF '
        '— "nothing here". This matters a lot: on the V8, HR and HRV came '
        'from 0x56. On this V5 that path is empty, so Recovery, Strain, '
        'BioAge and anything else built on HRV has no input.',
    evidence: 'Replies: 56 ff / 53 ff / 3b ff / 44 ff. Note this may mean the '
        'sensors are absent, OR that background recording was never enabled '
        '(0x2A gates it) — empty history cannot distinguish the two.',
  ),

  // ============================================================== ASSUMED
  Finding(
    id: 'paging-50-frame-stall',
    title: 'History stalls every 50 frames without a mode-0x02 resume',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.v8Hardware,
    area: FindingArea.paging,
    summary: 'A pull silently stops after 50 frames unless the continue frame '
        'is sent, giving a partial history that looks complete.',
    evidence: 'Reproduced on every history opcode on a V8. The V5 actigraphy '
        'pull returned exactly 50 packets, which is consistent with the same '
        'limit — but that was not tested to exhaustion.',
    howToVerify: 'Pull 0x58 to the end and check indices stay contiguous past '
        'the 50th frame.',
  ),
  Finding(
    id: 'paging-0x99-delete',
    title: '0x99 is DELETE — hex, not decimal 99',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.v8Hardware,
    area: FindingArea.paging,
    summary: 'Sync modes: 0x00 all, 0x01 today, 0x02 continue, 0x99 delete. '
        'Decimal 99 is 0x63 and means something else. The app refuses delete '
        'unless explicitly asked.',
    evidence: 'Confirmed against the SDK on the V8 build.',
    howToVerify: 'Do not verify this destructively. Trust the guard.',
  ),
  Finding(
    id: 'error-bit',
    title: 'Bit 7 of a reply is an ERROR flag, not "is-response"',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.v8Hardware,
    area: FindingArea.framing,
    summary: 'Mask it to recover the opcode, but treat a set bit as a NAK.',
    evidence: 'On a V8, set on rejected replies and clear on accepted ones.',
    howToVerify: 'Harder to test on a V5, which accepts any checksum and so '
        'rejects less.',
    supersedes: 'Public research describing bit 7 as an is-response marker.',
  ),
  Finding(
    id: 'op-0x64-not-ppi',
    title: '0x64 is a social-distance WRITE, not a PPI read',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.vendorSdk,
    area: FindingArea.safety,
    opcodes: [0x64],
    summary: '`64 01 hi lo` overwrites the band\'s scan interval, duration '
        'and RSSI threshold with whatever you passed as a record id. Never '
        'send it with byte[1] != 0.',
    evidence: 'Vendor SDK and phone app both define it as social-distance '
        'settings; one third-party client calls it GET_PPI, unconfirmed.',
    howToVerify: 'Do not verify by sending it.',
    supersedes: 'That 0x64 returns peak-to-peak intervals — acting on which '
        'would silently reconfigure the band.',
  ),
  Finding(
    id: 'op-0x2A-conflict',
    title: '0x2A is conflicted, and gates background recording',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.vendorSdk,
    area: FindingArea.safety,
    opcodes: [0x2A],
    summary: 'One implementation reads it as HRV history, another as a '
        'schedule WRITE. A sensor never enabled records nothing, and its '
        'history then reads empty — which is exactly what this V5 shows for '
        'HRV, sleep, temperature and SpO2.',
    evidence: 'The V8 downloader and the 2501 map disagree.',
    howToVerify: 'Resolving this would likely explain the four empty '
        'histories above — but it is a WRITE of unknown meaning, so not '
        'attempted.',
  ),
  Finding(
    id: 'raw-ppg-no-pulse-v8',
    title: 'On the V8, raw PPG (0x78 → 0x3A) carried no pulse',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.v8Hardware,
    area: FindingArea.sensors,
    opcodes: [0x78, 0x3A],
    summary: 'On a V8 the stream decoded to 203-byte frames of 50 × 4-byte '
        'big-endian at 48.4 Hz and contained no cardiac signal at all. On '
        'this V5, a bare read of 0x3A returned 153 zero bytes — the same '
        'idle response the V8 gave — but the stream itself was never started.',
    evidence: 'V8: two 30 s captures, band worn at 33.6 °C, autocorrelation '
        'with no local maximum in lags 3–150. V5: 0x3A bare read = 153 zeros.',
    howToVerify: 'Start it with 0x78 [01], capture 30 s, stop with 0x78 [00]. '
        'The periodicity gate in this app will refuse to report a rate it '
        'cannot justify. Given the V5 has no HRV history at all, this is the '
        'one path that might yet yield beat data here.',
  ),
  Finding(
    id: 'ppg-decoy-numbers',
    title: 'Raw PPG data fakes a heart rate in two distinct ways',
    status: FindingStatus.assumed,
    provenance: FindingProvenance.v8Hardware,
    area: FindingArea.sensors,
    opcodes: [0x3A],
    summary: 'On V8 data a naive threshold detector reported ~49 bpm, and '
        'decoding the same frames as 3-byte rather than 4-byte reported a far '
        'more convincing ~161 bpm. Both fictional. Relevant here because the '
        'V5 sample width is unknown.',
    evidence: 'Correct decode: 2 crossings → 1 interval → 49 bpm. 3-byte '
        'misdecode: 109 intervals → 161 bpm, genuinely periodic at an '
        'artificial 4-sample byte-alignment period whose harmonic at lag 16 '
        'reaches r=+0.367 — inside the pulse band, so periodicity alone does '
        'not catch it.',
    howToVerify: 'Already guarded: the shipped gate rejects both regardless '
        'of which band produced the samples.',
  ),

  // ================================================================= OPEN
  Finding(
    id: 'v5-schedule-all-on',
    title: 'Every sensor IS scheduled — including HRV, hourly',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x2B, 0x56, 0x3B],
    summary: 'Read from the band with 0x2B, raw bytes:\n\n'
        '  heart rate       ON  00:00-23:59, every 10 min\n'
        '  blood oxygen     ON  00:00-23:59, every 30 min\n'
        '  skin temperature ON  00:00-23:59, every 30 min\n'
        '  HRV              ON  00:00-23:59, every 60 min\n\n'
        'So nothing is switched off, and the empty 0x56 and 0x3B histories '
        'are NOT explained by scheduling. Something else is going on — most '
        'likely the same thing as on the 2208A, where heart rate turned out '
        'to live on 0x55 rather than the 0x54 the map named. The histories '
        'for temperature and HRV are probably under different opcodes '
        '(0x62 / 0x65 for temperature, 0x77 for HRV) rather than absent.',
    evidence: 'Raw 0x2B replies:\n'
        '  sensor 3: 2b 02 00 00 23 59 ff 1e 00 03  -> ON, 30 min\n'
        '  sensor 4: 2b 02 00 00 23 59 ff 3c 00 04  -> ON, 60 min',
    supersedes: 'This entry\'s own earlier text, which said temperature was '
        'OFF and that HRV drew no reply and was "likely unsupported". BOTH '
        'were wrong, and they were wrong for the same reason: a 1200 ms read '
        'window that timed out. A timeout returned null, and null was '
        'rendered as "no reply (likely unsupported)" — so a transport failure '
        'became a claim about the hardware, and then a claim that Recovery '
        'could never work on this band. The read now retries with 2500 ms '
        'and reports "could not read (unknown)".',
  ),
  Finding(
    id: 'v5-hrv-0x77-empty',
    title: '0x77 GET_HRV_HISTORY is empty too — no stored HRV by any route',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x77, 0x56],
    summary: 'The SDK map has TWO HRV opcodes, and the names matter: 0x56 is '
        'GET_HRV_TEST_DATA — the results of on-demand tests — while 0x77 is '
        'GET_HRV_HISTORY, a separate opcode the research called uncharted.\n\n'
        'That naming exactly fits what this band does: 0x56 fills after a '
        'manual measurement and is otherwise empty. So 0x77 was the obvious '
        'place for a background series to live. It is empty as well.\n\n'
        'Between them, 0x56, 0x77 and the 0x2B schedule read, there is no '
        'route to stored HRV on this band.',
    evidence: '0x77 returned "77 00 00 .. 00 77" — a well-formed, zero-filled '
        'frame.\n\n'
        'A control rules out the obvious confound: 0x71 GET_ECG_HISTORY, a '
        'feature the V5 certainly does not have, answered "71 ff .. 70" — the '
        'normal empty marker. So an absent feature still uses ff, and 0x77 is '
        'doing something different.\n\n'
        'What that difference MEANS is not settled. Zero-filled frames also '
        'come back from opcodes that are real but empty (0x3B on the 2208A '
        'does exactly this), so "implemented but holds nothing" and "not '
        'implemented on this firmware" both remain live. The practical answer '
        'is the same either way: nothing to read.',
    howToVerify: 'If a V5 ever accumulates background HRV — after the vendor '
        'app enables something we have not found — re-read 0x77 and see '
        'whether the zeros become records.',
  ),
  Finding(
    id: 'v5-sleep-empty-not-worn',
    title: 'Sleep history is empty because the band is never worn overnight',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x53],
    summary: '0x53 answers with the empty marker, and unlike temperature and '
        'SpO2 this one is NOT a case of the data hiding under another '
        'opcode. There is simply no sleep to record.',
    evidence: 'A month of heart-rate history covers only daytime: 10:00, '
        '12:00-14:00 and a handful at 20:00. Nothing at all between 21:00 '
        'and 09:00, while the 0x2B schedule samples 00:00-23:59 — so if the '
        'band were on a wrist overnight there would be records.\n\n'
        '0x53 is also the documented sleep opcode with two known shapes '
        '(stride 34, or a single 130-byte frame), so there is no obvious '
        'alternative to look under. 0x08 SLEEP_F_DATA appears in the opcode '
        'table with no documentation of any kind, and sending an opcode whose '
        'direction is unknown was not worth the risk for this.',
    howToVerify: 'Wear the band overnight, then re-pull 0x53. If it is still '
        'empty after a night of HR records existing, THEN look for another '
        'opcode.',
  ),
  Finding(
    id: 'v5-temperature-0x62',
    title: 'Temperature history is on 0x62, not 0x3B',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    opcodes: [0x62, 0x3B],
    summary: '0x3B — where the published map puts temperature history — '
        'answers "nothing stored" forever on this band. 0x62 holds the real '
        'records, in the same 11-byte layout: [1:3] LE16 index, [3:9] BCD '
        'timestamp, [9:11] LE16 tenths of a degree.\n\n'
        'This is the THIRD time a band has kept data under a different opcode '
        'than the map names, after 2208A heart rate on 0x55 and V5 SpO2 on '
        '0x66. The pattern is now the thing to remember: an opcode answering '
        '"empty" is not evidence the feature is absent.',
    evidence: 'Raw 0x62 reply: "62 00 00 26 08 29 11 19 59 40 01" then '
        '"62 01 00 26 08 29 11 09 59 3e 01" — 32.0 °C at 11:19:59 and 31.8 °C '
        'at 11:09:59, ten minutes apart.\n\n'
        'Found by following a contradiction rather than by guessing: the '
        '0x2B schedule says temperature IS sampled, so the data had to be '
        'somewhere, and 0x3B being empty could not be the whole story.',
    supersedes: 'The claim that the V5 has no temperature history and that '
        'temperature "arrives with a measurement or not at all". It has a '
        'history; the app was reading the wrong opcode.',
  ),
  Finding(
    id: 'v5-spo2-0x66',
    title: 'SpO2 lives on 0x66, not 0x44 — 10-byte records',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.records,
    opcodes: [0x66, 0x44],
    summary: '0x44 answers with the empty marker; 0x66 carries the data. '
        'Records are 10 bytes: [0] opcode, [1:3] LE16 index, [3:9] BCD '
        'timestamp, [9] SpO2 as a plain percentage. Indices count backwards '
        'from the newest, and the stream ends with 66 ff. Sampling looks '
        'half-hourly.',
    evidence: 'Sent each opcode separately to isolate the source. 0x44 -> '
        '44 ff (nothing stored). 0x66 -> two records then 66 ff:\n'
        '  idx 0  2026-08-27 13:01:41  0x62 = 98%\n'
        '  idx 1  2026-08-27 12:31:41  0x5E = 94%\n'
        'The app had already stored SpO2 94% at 12:31:41 — byte-for-byte the '
        'same record — which is what pins the source rather than inferring '
        'it from which opcodes the sync happens to pull.',
    supersedes: 'The earlier note that the SpO2 source was unknown because a '
        'value appeared while 0x44 read empty. It came from 0x66.',
  ),
  Finding(
    id: 'v5-hrv-history-works',
    title: 'HRV history DOES exist on 0x56 and fills hourly',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x56, 0x2B, 0x28],
    summary: '0x56 holds real HRV history, written on the hourly schedule '
        '0x2B reports. It is not on-demand only.\n\n'
        'Scheduled and manual records differ in WHICH fields they fill, and '
        'that is the useful part:\n'
        '  scheduled: HRV, vascular age, stress. Heart rate and blood '
        'pressure are ZERO.\n'
        '  manual:    all six fields, including HR and BP.\n\n'
        'So a zero heart rate in a 0x56 record is not a bad reading — it '
        'means nobody asked for one. Treat 0 as absent, never as a value.',
    evidence: 'Three records pulled from the band:\n'
        '  2026-08-29 11:03:30  HRV 94  HR 0   BP 0/0    <- scheduled\n'
        '  2026-08-27 14:03:30  HRV 93  HR 0   BP 0/0    <- scheduled\n'
        '  2026-08-27 13:03:30  HRV 26  HR 71  BP 113/63 <- manual\n\n'
        'The two 2026-08-27 records are exactly 60 minutes apart, matching '
        'the 0x2B interval, and only one manual measurement was taken that '
        'day. The 08-29 record appeared with no measurement at all.',
    supersedes: 'The claim that this band gives HRV "only on demand, never '
        'in the background", and the earlier claim that HRV was unsupported '
        'entirely. Both came from reading 0x56 while it happened to be empty '
        'and treating a snapshot as a property of the hardware — the same '
        'mistake, twice, on the same opcode.',
  ),
  Finding(
    id: 'v5-blood-pressure',
    title: 'Blood pressure is reported, and should not be trusted',
    status: FindingStatus.confirmed,
    provenance: FindingProvenance.v5Hardware,
    area: FindingArea.sensors,
    opcodes: [0x28],
    summary: 'The on-demand frame carries systolic and diastolic values (read '
        '113/63). They decode cleanly and look plausible, which is exactly '
        'the problem: a wrist optical sensor cannot measure blood pressure '
        'without a cuff calibration, and nothing here establishes one. The '
        'app stores the numbers because the band reports them, and says so '
        'rather than presenting them as a health measurement.',
    evidence: 'Decoded from the 0x28 reply at 13:03:30. Plausibility is not '
        'validity: no reference cuff measurement was taken alongside it.',
    howToVerify: 'Would require simultaneous readings against a validated '
        'cuff across a range of pressures. Not attempted, and not worth '
        'treating as clinical either way.',
  ),
];

List<Finding> findingsForOpcode(int opcode) =>
    [for (final f in findings) if (f.opcodes.contains(opcode)) f];

List<Finding> get corrections =>
    [for (final f in findings) if (f.correctsSomething) f];

/// Everything not yet established on a V5.
List<Finding> get provisional =>
    [for (final f in findings) if (f.isProvisional) f];

/// True while nothing has been confirmed on a V5 yet.
///
/// The app uses this to keep a standing caveat on screen rather than
/// presenting inherited numbers as if they were measurements of this band.
bool get nothingConfirmedOnV5 =>
    !findings.any((f) => f.status == FindingStatus.confirmed);
