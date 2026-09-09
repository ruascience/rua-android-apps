/// J-Style / JCVital band protocol.
///
/// Mirrors `tools/jstyle.py` — the Python prober and this app must agree
/// byte-for-byte, because the prober is what establishes the truth against
/// real hardware and this is what ships it.
///
/// Confidence levels are marked per opcode. Anything not marked CONFIRMED has
/// not yet been seen answering on one of our own bands.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------- GATT

String uuid16(String short) =>
    '0000${short.toLowerCase()}-0000-1000-8000-00805f9b34fb';

/// The J-Style command service. `fee7` is the filter several Chinese band
/// SDKs advertise under, and on at least one band family the advertised
/// service differs from the data service — so both are checked.
final serviceCandidates = [uuid16('fff0'), uuid16('fee7'), uuid16('fe00')];
final writeCandidates = [uuid16('fff6'), uuid16('fff2'), uuid16('fee1')];
final notifyCandidates = [
  uuid16('fff7'),
  uuid16('fff1'),
  uuid16('fee2'),
  uuid16('fee3'),
];

final disService = uuid16('180a');
final disManufacturer = uuid16('2a29');
final disModel = uuid16('2a24');
final disSerial = uuid16('2a25');
final disHardware = uuid16('2a27');
final disFirmware = uuid16('2a26');
final disSoftware = uuid16('2a28');
final batteryService = uuid16('180f');
final batteryLevel = uuid16('2a19');

/// Substrings these bands advertise under. Matched case-insensitively.
/// Verified on hardware: the Pro V8 advertises as "JCV8B 300D" (name + the
/// last two MAC octets). "jcv" is the reliable prefix, not "jcvital".
// This app targets the V5, so 'v5' is a strong signal here — the opposite of
// the V8 build, where it was weak. Note a band may advertise a name that has
// nothing to do with its protocol family: one renamed itself from
// "JCV8B 44300D" to "V5" mid-session, so the name is a hint, never proof.
// 0x3E is what actually settles the family.
const strongNameHints = [
  'v5',
  'jcv',
  'jcvital',
  'jstyle',
  'j-style',
  '2208',
  '2501'
];
const weakNameHints = ['v8', 'band', 'health', 'youhong', 'joint'];

// ------------------------------------------------------------ checksums

typedef Checksum = int Function(List<int> body);

int csSum(List<int> b) => b.fold<int>(0, (a, v) => a + v) & 0xFF;
int csXor(List<int> b) => b.fold<int>(0, (a, v) => a ^ v);
int csSumInv(List<int> b) => (~b.fold<int>(0, (a, v) => a + v)) & 0xFF;
int csSumPlus1(List<int> b) => (b.fold<int>(0, (a, v) => a + v) + 1) & 0xFF;
int csZero(List<int> b) => 0;

const kChecksumSum = 'sum';
final Map<String, Checksum> checksums = {
  kChecksumSum: csSum, // CONFIRMED on the V8 downloader
  'xor': csXor,
  'sum_inv': csSumInv,
  'sum_plus1': csSumPlus1,
  'none': csZero,
};

const frameLen = 16;

/// Build a command frame.
///
/// Layout: `[0]` opcode, `[1]` mode, `[2..14]` payload, `[15]` checksum over
/// bytes 0..14.
Uint8List frame(
  int opcode, {
  List<int> payload = const [],
  int length = frameLen,
  String checksum = kChecksumSum,
}) {
  if (opcode < 0 || opcode > 0xFF) {
    throw ArgumentError('opcode out of range: $opcode');
  }
  if (payload.length > length - 2) {
    throw ArgumentError('payload too long: ${payload.length} > ${length - 2}');
  }
  final body = Uint8List(length - 1);
  body[0] = opcode;
  for (var i = 0; i < payload.length; i++) {
    body[i + 1] = payload[i] & 0xFF;
  }
  final fn = checksums[checksum];
  if (fn == null) throw ArgumentError("unknown checksum '$checksum'");
  final out = Uint8List(length);
  out.setRange(0, length - 1, body);
  out[length - 1] = fn(body);
  return out;
}

bool verifyFrame(List<int> data, {String checksum = kChecksumSum}) {
  if (data.length < 2) return false;
  // An unknown name is a caller bug, not a reason to throw from the middle of
  // a notification handler — frame() reports it, this just declines.
  final fn = checksums[checksum];
  if (fn == null) return false;
  return fn(data.sublist(0, data.length - 1)) == data.last;
}

/// Every checksum variant consistent with this frame — lets us identify the
/// firmware's scheme from its replies without writing anything.
List<String> whichChecksum(List<int> data) {
  if (data.length < 2) return const [];
  final body = data.sublist(0, data.length - 1);
  return checksums.entries
      .where((e) => e.value(body) == data.last)
      .map((e) => e.key)
      .toList();
}

// ------------------------------------------------------------------ BCD

int toBcd(int v) {
  if (v < 0 || v > 99) throw ArgumentError('not BCD-representable: $v');
  return ((v ~/ 10) << 4) | (v % 10);
}

int fromBcd(int v) => ((v >> 4) & 0x0F) * 10 + (v & 0x0F);
bool looksLikeBcd(int v) => ((v >> 4) & 0x0F) <= 9 && (v & 0x0F) <= 9;

// -------------------------------------------------------------- opcodes

/// The settled conclusion about `0x78` -> `0x3A` on this band family.
///
/// Surfaced in the Lab so the dead end is visible with the band on your wrist,
/// rather than rediscovered.
const rawPpgVerdict =
    'MEASURED ON A V8, NOT ON THIS BAND — on a JCVital Pro V8 the 0x78 -> '
    '0x3A stream was fully decoded (203-byte frames, 50 x 4-byte big-endian, '
    '48.4 Hz, single channel) and contained NO pulse: after a 0.67 Hz '
    'high-pass the autocorrelation had no local maximum anywhere in lags '
    '3-150. Whether a V5 behaves the same way is untested. HR/HRV on the V8 '
    'came from 0x56 history + 0x28 on-demand.\n\n'
    'Two decoy numbers to recognise if you do capture a V5 stream: a naive '
    'threshold detector reported ~49 bpm from V8 data, and decoding it as '
    '3-byte instead of 4-byte reported a very convincing ~161 bpm. Both were '
    'fictional. The gate in this app rejects both.';

/// Where the heart-rate and HRV numbers in this app actually come from.
///
/// Worth stating plainly in the UI: the obvious guess — that a wrist band
/// derives these from its optical sensor in the app — is wrong here. The raw
/// optical stream was fully decoded and carries no pulse ([rawPpgVerdict]),
/// so every HR and HRV figure is the band's own computation.
const hrProvenance =
    'Heart rate comes from the band\'s own 0x54 history — 24-byte records, '
    '15 samples at 5 s spacing, confirmed on this V5.\n\n'
    'HRV comes from 0x56, which this band fills on an hourly schedule as '
    'well as after a manual measurement. Scheduled records carry HRV, '
    'vascular age and stress but leave heart rate and blood pressure at '
    'ZERO — a zero there means nobody asked, not a reading of zero.\n\n'
    'Skin temperature history is on 0x62, not the 0x3B the published map '
    'names; 0x3B answers empty forever on this band.\n\n'
    'Blood pressure from a wrist optical sensor is not a clinical '
    'measurement. It is stored because the band reports it.\n\n'
    'The raw optical stream (0x78/0x3A) is not used for anything.';

class Op {
  final int code;
  final String name;
  final String source;
  final bool reads;
  final String risk;
  final String note;

  /// A settled conclusion about this opcode, when one has been reached on
  /// hardware and the question is CLOSED.
  ///
  /// This exists so a dead end stays dead. The Lab shows it next to the
  /// opcode, which is the moment it matters: standing there with the band on
  /// your wrist, about to re-run an experiment that already has an answer.
  final String verdict;

  const Op(this.code, this.name, this.source,
      {this.reads = true, this.risk = '', this.note = '', this.verdict = ''});
  bool get safe => reads && risk.isEmpty;

  /// True when this opcode has been investigated to a conclusion.
  bool get settled => verdict.isNotEmpty;
}

/// Bit 7 of a reply's first byte.
///
/// Public research called this an "is-response" marker. On our own JCV8B
/// hardware it is an ERROR/NAK flag: a frame with a bad checksum comes back as
/// `opcode | 0x80` with an empty payload, while a well-formed one echoes the
/// bare opcode. Mask it before lookup, but treat it as a rejection.
const responseBit = 0x80;
const errorBit = 0x80;
int replyOpcode(int first) => first & ~responseBit & 0xFF;

/// CONFIRMED on JCV8B 44300D, firmware V0.0.8.8 (2026-08-26): a 0x54 record
/// carries 15 sample slots and consecutive records are exactly 75 s apart, so
/// the sample interval is 75/15 = 5 s. No public implementation could prove
/// this — the record spacing does.
const hrSampleIntervalSeconds = 5;
const hrSamplesPerRecord = 15;
const hrRecordPeriodSeconds = hrSampleIntervalSeconds * hrSamplesPerRecord;

/// A history transfer ends with a bare `[opcode, 0xFF]` frame; the same shape
/// arriving first means "nothing stored".
bool isNothingHere(List<int> packet) =>
    packet.length >= 2 && packet[1] == 0xFF;

const opBattery = 0x13;
/// ⚠ 0x20 is ENTER_CAMERA, **not** get-device-info.
///
/// The 2501 map this table was seeded from labelled it `get_device_info`, so
/// it was marked safe and included in read sweeps. The vendor SDK has 0x20 as
/// ENTER_CAMERA — shutter-remote mode — and GET_DEVICE_INFO at **0x04**.
///
/// Found while wiring the 2208A app; the same mislabel was present here.
const opEnterCamera = 0x20;

/// The real get-device-info.
const opDeviceInfo = 0x04;
const opStepsToday = 0x26;
const opMeasure = 0x28;
const opHistTemperature = 0x3B;
const opHistSpo2 = 0x44;
const opHistSleep = 0x53;
const opHistHeartRate = 0x54;
const opHistHrv = 0x56;
const opHistSpo2Alt = 0x66;
/// Spot heart rate — where a 2208A keeps its series while 0x54 stays empty.
/// Declared so all three apps share one history decoder; this build does not
/// list it as a hist_ opcode, so nothing pulls it here.
const opHeartRateOnce = 0x55;

const opGetPpi = 0x64;
const opConflicted2A = 0x2A;
const opSetTime = 0x01;
const opGetName = 0x3E;
const opStartRawPpg = 0x78;
const opRawPpgStream = 0x3A;
/// Firmware version. `[1..4]` nibble-hex.
const opGetVersion = 0x27;

/// Background-monitoring schedule: 0x2A writes it, 0x2B reads it back.
///
/// ⚠ 0x2A is the opcode that gates whether the band records ANYTHING
/// optically. A sensor never enabled here samples nothing, and its history
/// then reads empty in a way indistinguishable from a model that lacks the
/// hardware.
const opSetAutoMonitor = 0x2A;
const opGetAutoMonitor = 0x2B;

/// Sensor ids used by 0x2A / 0x2B.
const autoSensorHeartRate = 1;
const autoSensorSpo2 = 2;
const autoSensorTemperature = 3;
const autoSensorHrv = 4;

/// Temperature history — **where the V5 actually keeps it**.
///
/// The map puts temperature history on 0x3B, and on a V8 that is right. On
/// the V5, 0x3B answers "nothing stored" forever while 0x62 holds the real
/// records: same 11-byte layout, LE16 tenths-of-a-degree at [9:11].
///
/// This is the third time a band has kept data under a different opcode than
/// the published map names — after 2208A heart rate on 0x55 and V5 SpO2 on
/// 0x66. An opcode answering "empty" is not evidence the feature is absent.
const opTemperatureHistory = 0x62;

const opActigraphy = 0x58;
const opRealtime = 0x09;
const opDailyTotals = 0x51;

const ops = <Op>[
  Op(opBattery, 'get_battery', 'HW CONFIRMED',
      note: 'reply [1] = battery percent (read 100 on a full band)'),
  Op(opEnterCamera, 'enter_camera_NOT_device_info', 'SDK', reads: false,
      risk: 'puts the band into camera shutter-remote mode. It was labelled '
          'get_device_info here, inherited from the 2501 map, and swept as a '
          'safe read. The SDK has 0x20 as ENTER_CAMERA and get-device-info '
          'at 0x04.'),

  Op(opDeviceInfo, 'get_device_info', 'SDK',
      note: 'the real device-info read — 0x04, not 0x20.'),
  Op(opStepsToday, 'settings_frame_NOT_steps', 'HW CONFIRMED',
      note: 'returns a 16-byte frame that is byte-identical hours apart, so '
          'it is settings, not a counter. Steps live on 0x51.'),
  Op(opDailyTotals, 'daily_totals', 'HW CONFIRMED',
      note: '28-byte records, one per day. [2:5] BCD date, [5:9] steps, '
          '[9:13] active seconds, [13:17] distance in decametres, [17:21] '
          'calories in 0.01 kcal. Both scalings match the vendor app ratios.'),
  Op(opMeasure, 'measure_ondemand', 'V8 CONFIRMED',
      note: 'request [0x04, on/off, 0x00, 0x60]; reply valid only when '
          'byte[1]==1, then [2]=HR [3]=SpO2 [4]=HRV [5]=stress [6]=sys [7]=dia'),
  Op(opHistTemperature, 'hist_temperature', 'V8 CONFIRMED',
      note: '11-byte records; [9:11] uint16 LE * 0.1 degC'),
  Op(opHistSpo2, 'hist_spo2', 'V8',
      note: '10-byte records; [9] = percent. On JCV8B firmware this answers '
          '[0x44,0xFF] = nothing stored — SpO2 lives on 0x66 instead.'),
  Op(opHistSleep, 'hist_sleep', 'HW CONFIRMED',
      note: '34-byte records; [9] = segment minutes, [11:] = stage codes '
          '(1 deep, 2 light, 4 awake). Window decoded to the minute against '
          "the vendor app. Empty until 0x2A background monitoring is on."),
  Op(opHistHeartRate, 'hist_heart_rate', 'V8 CONFIRMED',
      note: '24-byte records; [9..23] = 15 x uint8 bpm, 0 = empty slot. '
          'mode byte: 0 = start, 2 = next page (max ~10 pages)'),
  Op(opHistHrv, 'hist_hrv', '2501',
      note: '15-byte records; [9]=hrv_ms raw uint8 (unscaled, saturates at '
          '255) [10]=vascular_aging [11]=HR [12]=stress [13]=sys [14]=dia'),
  Op(0x77, 'hist_hrv_history', 'SDK',
      note: 'GET_HRV_HISTORY — a SECOND HRV opcode, distinct from 0x56 '
          'GET_HRV_TEST_DATA. The names matter: 0x56 holds on-demand TEST '
          'results, so 0x77 was the obvious home for a background series. '
          'On this V5 it answers with a zero-filled frame — empty. A control '
          '(0x71 ECG history, a feature this band lacks) answered with the '
          'usual ff marker instead, so the two responses genuinely differ; '
          'what that difference means is unsettled.'),

  Op(opTemperatureHistory, 'hist_temperature_0x62', 'HW CONFIRMED',
      note: 'WHERE THE V5 ACTUALLY KEEPS TEMPERATURE. 11-byte records: '
          '[1:3] LE16 index, [3:9] BCD timestamp, [9:11] LE16 tenths of a '
          'degree. 0x3B — where the map puts it — answers empty forever on '
          'this band. Read 32.0 C at 2026-08-29 11:19:59.'),

  Op(opHistSpo2Alt, 'hist_spo2_alt', 'HW CONFIRMED',
      note: 'THE SpO2 history opcode on JCV8B: 10-byte records, [9] = percent. '
          "Verified 94%/95% against the vendor app's own display."),
  Op(opGetName, 'get_name', 'SDK+HW',
      note: 'model discriminator. A band advertising "J2501 B920" answers '
          '"J2208   B920" — 2501 is a marketing SKU, 2208 is the protocol '
          'family. One round trip tells you which opcode map applies.'),
  Op(opActigraphy, 'actigraphy_per_minute', 'HW CONFIRMED',
      note: 'per-minute actigraphy, ~45 days deep — the richest stream on the band, and the vendor app exposes nothing like it. 35-byte records: [1:3] LE16 index, [3:9] BCD timestamp to the second, [9:21] six LE uint16 motion-energy values, [22:26] LE32 slow cumulative counter, [26] sequence byte +1/min wrapping at 256. One pull returned 1723 records over 46 days. NOT named hist_* on purpose: the sync loop pulls every safe hist_ opcode, and 1723 records would dominate every sync. Pull it deliberately from the Lab.'),

  Op(opGetVersion, 'get_version', 'SDK+HW',
      note: 'firmware version, [1..4] nibble-hex. Needed on bands with no '
          'Device Information Service — this family has none, which is why '
          'the firmware field reads blank without it.'),

  Op(opGetAutoMonitor, 'get_auto_monitor', 'SDK',
      note: 'reads the background-monitoring schedule per sensor. ALWAYS read '
          'this before concluding a sensor is disabled: on a 2208A the '
          'histories looked empty and the schedule turned out to be on the '
          'whole time.'),

  Op(opRealtime, 'realtime_frame', 'HW CONFIRMED',
      note: '32-byte realtime frame. [22:24] LE x 0.1 = skin temperature in C '
          '(read 33.4 and 32.4). All zeros unless a measurement is running, '
          'so pair it with 0x28. THE ONLY source of temperature — no history '
          'opcode carries it. The same frame also carries LIVE daily totals: '
          '[1:5] steps, [5:9] 0.01 kcal, [9:13] decametres, [13:17] active '
          'seconds — see parseRealtimeTotals.'),
  Op(opRawPpgStream, 'raw_ppg_stream', 'HW CONFIRMED',
      note: 'notify-only stream produced by 0x78; never requested directly. '
          'Sent directly it returns 153 zero bytes, which is what originally '
          'suggested 50 x 3-byte slots — that inference was wrong.',
      verdict: rawPpgVerdict),

  // 0x64 is NOT a PPI read on this family. The vendor app and the 2208A SDK
  // both call it social-distance settings; only one third-party client says
  // PPI, and neither reading is hardware-confirmed. `64 01 hi lo` is
  // byte-for-byte a social-distance WRITE that overwrites scan interval,
  // duration and RSSI threshold with the record-id bytes.
  Op(opGetPpi, 'social_distance_settings_OR_ppi', 'SDK/APP vs RE CONFLICT',
      reads: false,
      risk: 'on the 2208 family this WRITES social-distance settings. Never '
          'send with byte[1] != 0. There is no RR-interval read on this '
          'family: 0x78 -> 0x3A carries no pulse either, so use the band\'s '
          'own 0x56 HRV history and 0x28 on-demand measurement.'),

  Op(opStartRawPpg, 'start_raw_ppg', 'HW CONFIRMED',
      reads: false,
      risk: 'starts a raw stream on 0x3A and also drives the 0x09 push; '
          'stopping it stops both. Needs MTU > 206, and it costs battery. '
          'Always pair `78 01` with `78 00`.',
      note: 'Transport fully solved: 0x78 [01] starts, 0x78 [00] stops. '
          'Frames are 203 bytes (3a 00 NN + 200 B), 50 x 4-byte BIG-endian '
          'samples, one frame per 1.033 s = 48.4 Hz, single channel.',
      verdict: rawPpgVerdict),

  // The two public implementations disagree, and both cannot be right. The V8
  // downloader reads HRV history from this; the vendor SDK and app call it
  // "set auto-measure schedule" — a write.
  Op(opConflicted2A, 'set_auto_measure_OR_hist_hrv',
      'SDK/APP vs V8 CONFLICT',
      reads: false,
      risk: 'on the 2208 family this WRITES the background-monitoring '
          'schedule. It also gates everything else: a sensor never enabled '
          'records nothing, and its history then reads empty in a way that '
          'is indistinguishable from missing hardware.',
      note: 'the V8 downloader instead reads HRV history from this opcode'),

  Op(opSetTime, 'set_time', 'SDK',
      reads: false,
      risk: 'may reset the daily accumulators if the encoding is wrong '
          '(BCD vs decimal)'),
  Op(0x03, 'set_user_profile', 'SDK',
      reads: false, risk: 'overwrites height/weight/age/sex'),
  Op(0x72, 'factory_reset', 'SDK', reads: false, risk: 'ERASES THE BAND'),
];

final Map<int, Op> opsByCode = {for (final o in ops) o.code: o};

String opName(int code) =>
    opsByCode[code]?.name ?? 'unknown_0x${code.toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// Opcodes that must never be emitted by a blind sweep: state writes, the
/// reset/clear-data region and the DFU range.
final Set<int> sweepBlocklist = {
  ...ops.where((o) => !o.safe).map((o) => o.code),
  0x00,
  for (var c = 0xF0; c <= 0xFF; c++) c,
  0x70, 0x71, 0x72, 0x73,
};

// ------------------------------------------------------------- records
// Every history record repeats its own header, so a frame can be sliced
// without carrying state across frames:
//   [0]     echoed opcode (mask bit 7)
//   [1:3]   little-endian uint16 record index
//   [3:9]   BCD timestamp YY MM DD hh mm ss, year = 2000 + BCD, band-local
//   [9:]    payload
// Stride is fixed per type. History frames carry NO checksum — never try to
// verify one.

const headerLen = 9;
const tsOffset = 3;

/// Opcodes whose records carry an LE16 sequence index at `[1:3]`.
///
/// History records do. `0x51` daily totals do NOT — a BCD date sits there —
/// so anything reasoning about record ordering must ask this first rather
/// than assuming every record is numbered.
const recordsWithIndex = <int>{
  opHistHeartRate,
  opHistHrv,
  opHistSleep,
  opHistTemperature,
  opHistSpo2,
  opHistSpo2Alt,
  opActigraphy,
};

bool recordHasIndex(int opcode) => recordsWithIndex.contains(opcode);

const recordStride = <int, int>{
  opHistHeartRate: 24,
  opHistHrv: 15,
  opConflicted2A: 15,
  opHistTemperature: 11, // V8 only
  opHistSpo2: 10,
  opHistSpo2Alt: 10,
  opDailyTotals: 28,
  0x55: 10,
  0x60: 10,
  opTemperatureHistory: 11, // 0x62 — the V5's real temperature history
  0x65: 11,
  0x52: 25,
  0x5C: 25,
  // 0x51 measured at 28 bytes on this firmware (see opDailyTotals)
  0x53: 34, // sleep; some firmware answers with a single 130-byte frame
  0x5D: 57,
  0x5A: 59,
};

// -------------------------------------------------------- history paging
// Request: [0] opcode, [1] sync mode, [2:4] zero, [4:10] BCD cursor
// ("date of the last data the host already holds"), [10:15] zero.

const syncAll = 0x00; // everything stored, from the cursor if one is given
const syncToday = 0x01;
const syncContinue = 0x02; // resume the current stream

/// The SDK declares DATA_DELETE = 99 in *decimal*, but every delete branch
/// tests for 0x99 — the value is meant to pass through the decimal-to-BCD
/// converter first. On the wire the delete mode byte is 0x99.
const syncDelete = 0x99;

/// The firmware pauses after this many frames and waits for a mode-0x02
/// resume. Without it a multi-day sync stalls partway and looks exactly like
/// a dropped connection.
const streamBatchLimit = 50;

/// Build a history request.
///
/// Refuses the delete mode unless asked explicitly — `0x99` erases every
/// stored record of that type, and it is one keystroke away from `0x00`.
Uint8List historyFrame(
  int opcode, {
  int mode = syncAll,
  DateTime? cursor,
  String checksum = kChecksumSum,
  bool allowDelete = false,
}) {
  if (mode == syncDelete && !allowDelete) {
    throw ArgumentError(
        'mode 0x99 DELETES all stored records of this type; pass '
        'allowDelete: true if that is really what you want');
  }
  final payload = List<int>.filled(14, 0);
  payload[0] = mode;
  if (cursor != null) {
    final f = [
      cursor.year - 2000,
      cursor.month,
      cursor.day,
      cursor.hour,
      cursor.minute,
      cursor.second
    ];
    for (var i = 0; i < 6; i++) {
      payload[3 + i] = toBcd(f[i]);
    }
  }
  return frame(opcode, payload: payload, checksum: checksum);
}

/// True when this is the final frame of a history transfer.
///
/// The terminator is the trailing `0xFF` of the last frame. It is not part of
/// a whole record, so integer division by the stride naturally excludes it.
/// `[opcode, 0xFF]` means there was nothing (more) to send.
bool isStreamEnd(List<int> packet) {
  if (packet.length >= 2 && packet[1] == 0xFF && packet.length <= 3) {
    return true;
  }
  return packet.isNotEmpty && packet.last == 0xFF;
}

/// Records carry a little-endian uint16 index at `[1:3]`.
///
/// Used to stop a transfer that starts repeating itself — the firmware will
/// loop a page rather than signalling the end.
int? recordIndex(List<int> rec) =>
    rec.length < 3 ? null : rec[1] | (rec[2] << 8);

class SplitResult {
  final List<Uint8List> records;
  final Uint8List leftover;
  const SplitResult(this.records, this.leftover);
}

/// Split a notification buffer into whole records, resynchronising on the
/// opcode byte.
///
/// The obvious `buf[i..i+stride]` walk is wrong: a notification whose length
/// is not an exact multiple of the stride shifts every later record by the
/// remainder and silently corrupts the rest of the download. Anchoring on the
/// echoed opcode costs one record instead of all of them.
SplitResult splitRecords(Uint8List buf, int opcode, {int? stride}) {
  final s = stride ?? recordStride[opcode];
  if (s == null || s <= 0) return SplitResult(const [], buf);

  // 0x53 sleep has TWO shapes and only one of them is a stride.
  //
  //   stride 34   — up to 24 stage bytes, each covering 5 minutes
  //   ONE ~130 B  — a single record whose samples cover 1 minute each
  //
  // 130 is not a multiple of 34, so splitting the single-frame form at the
  // stride yields three bogus records and a remainder — silently losing the
  // night rather than failing. Detect it and emit one record.
  if (opcode == opHistSleep && buf.length >= 120 && buf.length <= 140) {
    final end = (buf.length >= 2 && buf[buf.length - 1] == 0xFF) ? buf.length - 2 : buf.length;
    final one = Uint8List.sublistView(buf, 0, end);
    if (one.isNotEmpty && replyOpcode(one[0]) == opcode) {
      return SplitResult([one], Uint8List.sublistView(buf, end));
    }
  }
  final out = <Uint8List>[];
  var i = 0;
  while (i + s <= buf.length) {
    if (replyOpcode(buf[i]) != opcode) {
      var next = i + 1;
      while (next < buf.length && replyOpcode(buf[next]) != opcode) {
        next++;
      }
      i = next;
      continue;
    }
    final rec = Uint8List.sublistView(buf, i, i + s);
    // An all-zero body is padding, not a record.
    //
    // Several opcodes answer "nothing stored" with a zero-filled frame rather
    // than the [op, 0xFF] marker — 0x3B does exactly that on the 2208A. The
    // opcode byte still matches, so the walk above happily emits a record of
    // zeros, and the caller reports "1 record" for an empty history. The
    // parsers reject it downstream, so no bad value is stored, but the COUNT
    // is a lie and it is the count people read.
    if (!rec.skip(1).every((b) => b == 0)) out.add(rec);
    i += s;
  }
  return SplitResult(out, Uint8List.sublistView(buf, i));
}

/// Decode the shared BCD timestamp at offsets 3..8.
///
/// Returns null when the bytes are not valid BCD or not a real date — which
/// is how zero padding and torn records announce themselves.
DateTime? recordTime(List<int> rec) {
  if (rec.length < tsOffset + 6) return null;
  final raw = rec.sublist(tsOffset, tsOffset + 6);
  if (!raw.every(looksLikeBcd)) return null;
  final v = raw.map(fromBcd).toList();
  try {
    final d = DateTime(2000 + v[0], v[1], v[2], v[3], v[4], v[5]);
    // DateTime silently rolls over impossible dates (month 13 -> next year),
    // so round-trip the fields to reject them.
    if (d.month != v[1] || d.day != v[2]) return null;
    return d;
  } catch (_) {
    return null;
  }
}

class HrRecord {
  final DateTime? time;
  final List<int> samples;
  const HrRecord(this.time, this.samples);
}

/// 15 one-byte bpm samples. Zero means "slot not recorded", not 0 bpm.
///
/// Zeros appear *between* real samples too, not only as trailing padding, so
/// they must be filtered rather than truncated at the first zero.
HrRecord parseHrRecord(List<int> rec) => HrRecord(
      recordTime(rec),
      rec.length <= headerLen
          ? const []
          : rec.sublist(headerLen).where((b) => b != 0).toList(),
    );

/// Per-sample (time, bpm) using the confirmed 5 s slot spacing.
///
/// The record timestamp is the time of the FIRST slot; slot i is i*5 s later.
/// Empty slots are skipped but still consume their slot, so surviving samples
/// keep their true positions in time.
List<MapEntry<DateTime, int>> hrSamplesTimed(List<int> rec) {
  final ts = recordTime(rec);
  if (ts == null) return const [];
  final out = <MapEntry<DateTime, int>>[];
  for (var i = 0; i + headerLen < rec.length; i++) {
    final b = rec[headerLen + i];
    if (b == 0) continue;
    out.add(MapEntry(
        ts.add(Duration(seconds: i * hrSampleIntervalSeconds)), b));
  }
  return out;
}

class TempRecord {
  final DateTime? time;
  final double? celsius;
  const TempRecord(this.time, this.celsius);
}

TempRecord parseTempRecord(List<int> rec) {
  final ts = recordTime(rec);
  if (rec.length < headerLen + 2) return TempRecord(ts, null);
  final raw = rec[headerLen] | (rec[headerLen + 1] << 8); // little-endian
  final c = raw * 0.1;
  return TempRecord(ts, (c >= 30.0 && c <= 43.0) ? c : null);
}

class Spo2Record {
  final DateTime? time;
  final int? percent;
  const Spo2Record(this.time, this.percent);
}

Spo2Record parseSpo2Record(List<int> rec) {
  final ts = recordTime(rec);
  if (rec.length < headerLen + 1) return Spo2Record(ts, null);
  final v = rec[headerLen];
  return Spo2Record(ts, (v >= 85 && v <= 100) ? v : null);
}

class HrvRecord {
  final DateTime? time;
  final int hrvMs;
  final int vascularAging;
  final int heartRate;
  final int stress;
  final int systolic;
  final int diastolic;
  const HrvRecord(this.time, this.hrvMs, this.vascularAging, this.heartRate,
      this.stress, this.systolic, this.diastolic);
}

/// `[9]`=hrv_ms, `[10]`=vascular_aging, `[11]`=heart_rate, `[12]`=stress,
/// `[13]`=systolic, `[14]`=diastolic.
///
/// Note the field order: heart rate is at offset 11, not 10.
HrvRecord? parseHrvRecord(List<int> rec) {
  if (rec.length < 15) return null;
  return HrvRecord(
      recordTime(rec), rec[9], rec[10], rec[11], rec[12], rec[13], rec[14]);
}

/// Sleep stage codes the band actually reports.
///
/// Confirmed against a real night (2026-08-26) whose decoded window —
/// 00:41–08:10, 7h29m — matched the vendor app's "In Bed Duration" exactly.
///
/// The band reports THREE states. The vendor app displays four by deriving REM
/// on the phone from within the light-sleep periods; the band never sends it.
class SleepStage {
  static const deep = 0x01;
  static const light = 0x02;
  static const awake = 0x04;

  static String label(int code) => switch (code) {
        deep => 'Deep',
        light => 'Light',
        awake => 'Awake',
        _ => 'Unknown',
      };
}

/// One 0x53 record: a contiguous slice of the night.
///
/// Layout (stride 34):
///   [0]      opcode
///   [1:3]    LE16 record index
///   [3:9]    BCD start time
///   [9]      segment duration in MINUTES  (the last record's start + this
///            value gives the wake time, verified to the minute)
///   [10]     unknown — varies 1..15, not a slot count            [OPEN]
///   [11:34]  stage codes, one per slot, 0 = unused padding
class SleepSegment {
  final DateTime start;
  final int minutes;
  final List<int> stages;
  const SleepSegment(this.start, this.minutes, this.stages);

  DateTime get end => start.add(Duration(minutes: minutes));

  /// Minutes represented by each stage slot.
  ///
  /// The band does not state this. Slots are spread evenly across the
  /// segment's declared duration, which reproduces the vendor's stage split to
  /// within a few percent. Treat per-slot boundaries as approximate; the
  /// segment start/end and the totals are exact.
  double get minutesPerSlot =>
      stages.isEmpty ? 0 : minutes / stages.length;
}

SleepSegment? parseSleepRecord(List<int> rec) {
  if (rec.length < 12) return null;
  final t = recordTime(rec);
  if (t == null) return null;
  final mins = rec[9];
  if (mins <= 0 || mins > 24 * 60) return null;
  final stages = rec.sublist(11).where((b) => b != 0).toList();
  if (stages.isEmpty) return null;
  return SleepSegment(t, mins, stages);
}

class LiveReading {
  final int heartRate, spo2, hrvMs, stress, systolic, diastolic;
  const LiveReading(this.heartRate, this.spo2, this.hrvMs, this.stress,
      this.systolic, this.diastolic);
  bool get hasAnything => heartRate > 0 || spo2 > 0 || hrvMs > 0;
}

/// Reply to 0x28. Valid only when byte[1] == 1 — note the asymmetry: the
/// request carries 0x04 in that slot, the reply carries 0x01.
///
/// The band acknowledges the request immediately with an all-zero frame and
/// only sends real values ~30 s later, once the sensor has converged. Taking
/// that ack for the answer cancels the measurement every time, so callers
/// must keep waiting until a frame this function actually accepts arrives.
LiveReading? parseOnDemand(List<int> rec) {
  if (rec.length < 8 || rec[1] != 1) return null;
  return LiveReading(rec[2], rec[3], rec[4], rec[5], rec[6], rec[7]);
}

/// A streamed `0x3A` frame: 3-byte header + 50 x 4-byte big-endian samples.
///
/// The width matters more than it looks — decoding this as 3-byte yields a
/// confident and entirely fictional 161 bpm, so validate the frame shape.
const ppgFrameBytes = 203;
const ppgSampleBytes = 4;
const ppgSamplesPerFrame = 50;
const ppgNominalHz = 50;

/// True when [packet] has the shape a streamed `0x3A` frame must have.
///
/// A bare read of `0x3A` returns 153 zero bytes, which is NOT this shape —
/// that is exactly the frame that misled us into a 3-byte reading.
bool isWellFormedPpgFrame(List<int> packet) =>
    packet.length == ppgFrameBytes &&
    packet.isNotEmpty &&
    replyOpcode(packet[0]) == opRawPpgStream;

/// Samples from a live 0x3A frame: 50 x 4-byte BIG-ENDIAN at ~48.4 Hz.
///
/// CORRECTION: a bare 0x3A read returns 153 bytes of zeros, which suggested
/// 50 x 3-byte samples. The frames the band actually STREAMS are **203
/// bytes** — a 3-byte header plus 50 x uint32 — arriving one per 1.033 s,
/// which is 48.4 Hz measured (50 nominal).
///
/// ⚠ This stream does NOT contain a heartbeat — see [rawPpgVerdict] and
/// PROTOCOL.md §6.2.3a. Do not derive HR or HRV from it; use the band's own
/// 0x56 HRV history and 0x28 on-demand measurement. [analysePpg] exists to
/// demonstrate the absence rigorously, not to extract beats.
///
/// Decoding this as 3-byte samples (the original, wrong reading) yields a
/// convincing and entirely fictional 161 bpm, so the width matters.
List<int> parseRawPpg(List<int> packet) {
  final out = <int>[];
  for (var i = 3; i + 3 < packet.length; i += 4) {
    out.add((packet[i] << 24) |
        (packet[i + 1] << 16) |
        (packet[i + 2] << 8) |
        packet[i + 3]);
  }
  return out;
}

/// Firmware version from a 0x27 reply.
///
/// `[1..4]` are nibble-hex: each byte holds two decimal digits as nibbles, so
/// the bytes 01 02 00 08 mean "1.2.0.8". Reading them as plain integers gives
/// 1.2.0.8 too for small values but diverges the moment a component reaches
/// 10 — 0x10 is sixteen as an integer and ten as nibble-hex.
///
/// Returns null rather than a partial string when the bytes are not valid
/// BCD, because a made-up version number is worse than a blank field.
String? parseVersion(List<int> f) {
  if (f.length < 5) return null;
  if (replyOpcode(f[0]) != opGetVersion) return null;
  final parts = f.sublist(1, 5);
  if (!parts.every(looksLikeBcd)) return null;
  if (parts.every((b) => b == 0)) return null; // band said "nothing"
  return parts.map(fromBcd).join('.');
}

/// One spot heart-rate sample from `0x55`.
///
/// 10-byte record: `[0]` opcode, `[1:3]` LE16 index, `[3:9]` BCD timestamp,
/// `[9]` bpm. Established on a 2208A; untested on a V8, which is the point of
/// carrying the parser.
class HeartRateOnce {
  final DateTime? time;
  final int? bpm;
  const HeartRateOnce(this.time, this.bpm);
}

HeartRateOnce parseHeartRateOnce(List<int> rec) {
  final t = recordTime(rec);
  if (rec.length < headerLen + 1) return HeartRateOnce(t, null);
  final v = rec[headerLen];
  // A plausible human pulse. 0 is the band's "no reading" filler.
  return HeartRateOnce(t, (v >= 30 && v <= 220) ? v : null);
}

/// The background-monitoring schedule for one sensor.
///
/// Layout, shared by 0x2A (write) and 0x2B (read):
/// ```
///   [1]     mode: 2 = sample on an interval, 0 = off
///   [2:4]   start hour, start minute  — BCD
///   [4:6]   end hour, end minute      — BCD
///   [6]     weekday mask, 0xFF = every day
///   [7:9]   interval in MINUTES, LE16
///   [9]     sensor id
/// ```
class AutoMonitor {
  final bool enabled;
  final int startHour, startMinute, endHour, endMinute;
  final int weekdayMask;
  final int intervalMinutes;
  final int sensor;

  const AutoMonitor({
    required this.enabled,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.weekdayMask,
    required this.intervalMinutes,
    required this.sensor,
  });

  /// Every day, all day, sampling every [intervalMinutes].
  factory AutoMonitor.allDay(int sensor, int intervalMinutes) => AutoMonitor(
        enabled: true,
        startHour: 0,
        startMinute: 0,
        endHour: 23,
        endMinute: 59,
        weekdayMask: 0xFF,
        intervalMinutes: intervalMinutes,
        sensor: sensor,
      );

  String get window => '${startHour.toString().padLeft(2, '0')}:'
      '${startMinute.toString().padLeft(2, '0')}-'
      '${endHour.toString().padLeft(2, '0')}:'
      '${endMinute.toString().padLeft(2, '0')}';

  /// The 8-byte payload for a 0x2A write (the frame builder pads the rest).
  List<int> toPayload() => [
        enabled ? 2 : 0,
        toBcd(startHour),
        toBcd(startMinute),
        toBcd(endHour),
        toBcd(endMinute),
        weekdayMask,
        intervalMinutes & 0xFF,
        (intervalMinutes >> 8) & 0xFF,
        sensor,
      ];
}

AutoMonitor? parseAutoMonitor(List<int> f) {
  if (f.length < 10) return null;
  if (replyOpcode(f[0]) != opGetAutoMonitor) return null;
  // The window is BCD: the band answers 0x23 0x59 for 23:59, which read as
  // plain bytes would be 35:89.
  for (final b in f.sublist(2, 6)) {
    if (!looksLikeBcd(b)) return null;
  }
  return AutoMonitor(
    enabled: f[1] == 2,
    startHour: fromBcd(f[2]),
    startMinute: fromBcd(f[3]),
    endHour: fromBcd(f[4]),
    endMinute: fromBcd(f[5]),
    weekdayMask: f[6],
    intervalMinutes: f[7] | (f[8] << 8),
    sensor: f[9],
  );
}

/// A day's activity totals, from opcode 0x51.
///
/// This is where steps live — NOT 0x26, which returns a static settings frame
/// that is byte-identical hours apart.
///
/// Layout (28-byte record), decoded on hardware 2026-08-26:
/// ```
///   [0]      opcode
///   [1]      unknown
///   [2:5]    BCD date, YY MM DD — no time; these are per-day totals
///   [5:9]    LE32 steps
///   [9:13]   LE32 active seconds
///   [13:17]  LE32 distance in DECAMETRES (x10 for metres)
///   [17:21]  LE32 calories in hundredths of a kcal
/// ```
///
/// The two scalings are inferred, but both land on the vendor app's own
/// published ratios from data it never saw: 4244 steps / 3100 m = 0.730 m per
/// step against the vendor's 0.734, and 128.2 kcal / 4244 steps = 0.0302
/// kcal per step against the vendor's 0.0313.
class DailyTotals {
  final DateTime day;
  final int steps;
  final Duration active;
  final double km;
  final double kcal;
  const DailyTotals(this.day, this.steps, this.active, this.km, this.kcal);
}

DailyTotals? parseDailyTotals(List<int> rec) {
  if (rec.length < 21 || replyOpcode(rec[0]) != opDailyTotals) return null;
  final raw = rec.sublist(2, 5);
  if (!raw.every(looksLikeBcd)) return null;
  final v = raw.map(fromBcd).toList();
  DateTime day;
  try {
    day = DateTime(2000 + v[0], v[1], v[2]);
    if (day.month != v[1] || day.day != v[2]) return null;
  } catch (_) {
    return null;
  }
  int le32(int i) =>
      rec[i] | (rec[i + 1] << 8) | (rec[i + 2] << 16) | (rec[i + 3] << 24);

  final steps = le32(5);
  // A day cannot hold more than about 100k steps; anything beyond that is a
  // misparse, not an athlete.
  if (steps < 0 || steps > 200000) return null;
  return DailyTotals(
    day,
    steps,
    Duration(seconds: le32(9)),
    le32(13) * 10 / 1000.0, // decametres -> km
    le32(17) / 100.0, // hundredths of a kcal
  );
}

/// Skin temperature from a 0x09 realtime frame.
///
/// HARDWARE-CONFIRMED on JCV8B (2026-08-26): bytes [22:24], little-endian,
/// x 0.1 = degrees C. Read 33.4 and 32.4 on two separate measurements.
///
/// This is why temperature appeared "missing": it is NOT in any history
/// opcode. `0x3B` — where the published map puts it — always answers
/// "nothing stored". Temperature only exists in the REALTIME frame, and that
/// frame is all zeros unless a measurement is running, so it has to be read
/// as: 0x28 (start) -> poll 0x09 -> 0x28 (stop).
///
/// Public research reported these same bytes holding garbage (0x5332 =
/// 2129.8 C) on 2501 firmware, which is why the range gate matters.
double? parseRealtimeTemperature(List<int> frame) {
  if (frame.length < 24) return null;
  if (replyOpcode(frame[0]) != opRealtime) return null;
  final raw = frame[22] | (frame[23] << 8);
  final c = raw / 10.0;
  return (c >= 20.0 && c <= 45.0) ? c : null;
}

/// Live daily totals carried in the same 0x09 frame.
///
/// These mirror what 0x51 stores per day, but live:
/// ```
///   [1:5]    LE32 steps
///   [5:9]    LE32 calories in hundredths of a kcal
///   [9:13]   LE32 distance in decametres
///   [13:17]  LE32 active seconds
/// ```
/// Verified against a 0x51 pull minutes earlier: 4254 vs 4244 steps,
/// 128.45 vs 128.17 kcal, 3.11 vs 3.10 km, 2369 vs 2365 active seconds.
///
/// NOTE: there is no heart rate in this frame. An earlier version read byte
/// [5] as HR and got a plausible-looking 45 — but [5] is the low byte of the
/// calorie counter, and the agreement was coincidence.
DailyTotals? parseRealtimeTotals(List<int> f) {
  if (f.length < 24 || replyOpcode(f[0]) != opRealtime) return null;
  int le32(int i) => f[i] | (f[i + 1] << 8) | (f[i + 2] << 16) | (f[i + 3] << 24);
  final steps = le32(1);
  if (steps <= 0 || steps > 200000) return null;
  return DailyTotals(
    DateTime.now(),
    steps,
    Duration(seconds: le32(13)),
    le32(9) * 10 / 1000.0,
    le32(5) / 100.0,
  );
}

/// Request payload for a live measurement.
List<int> measurePayload({required bool on}) => [0x04, on ? 1 : 0, 0x00, 0x60];

// -------------------------------------------------- discovery heuristics

/// Longest run of consecutive plausible RR intervals — a strong tell for a
/// PPI record, which should be a long unbroken series.
int rrRunLength(List<int> data, {bool littleEndian = true}) {
  var best = 0, run = 0;
  for (var i = 0; i + 1 < data.length; i += 2) {
    final v = littleEndian
        ? data[i] | (data[i + 1] << 8)
        : (data[i] << 8) | data[i + 1];
    if (v >= 300 && v <= 2000) {
      run++;
      if (run > best) best = run;
    } else {
      run = 0;
    }
  }
  return best;
}

/// One-line hint about what an unknown record might hold — used by the
/// in-app protocol lab so an unrecognised reply is still informative.
String summariseRecord(List<int> data) {
  final hints = <String>[];
  for (var i = 0; i + 1 < data.length; i++) {
    final le = (data[i] | (data[i + 1] << 8)) * 0.1;
    if (le >= 30.0 && le <= 43.0) {
      hints.add('temp?@$i LE=${le.toStringAsFixed(1)}');
      break;
    }
  }
  final rr = rrRunLength(data);
  if (rr >= 4) hints.add('RR-run=$rr');
  final hr = <int>[];
  for (var i = 0; i < data.length; i++) {
    if (data[i] >= 35 && data[i] <= 210) hr.add(i);
  }
  if (hr.length >= 5) {
    hints.add('HR-bytes@${hr.first}..${hr.last}(${hr.length})');
  }
  final t = recordTime(data);
  if (t != null) hints.add('ts=$t');
  return hints.join('; ');
}

String hex(List<int> d) =>
    d.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
