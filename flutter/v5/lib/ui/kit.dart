/// Shared widgets and the design system.
///
/// ## Rua Science
///
/// The palette, the faces and the mark are the company's, carried over from
/// ruascience.com rather than invented here. Two decisions are worth writing
/// down, because both are departures from the source and both were deliberate.
///
/// **The ground is dark; the brand's is light.** ruascience.com sits on warm
/// paper (`#F7F5F2`). A band app does not: it is read at 6am and in bed, and
/// every screen here is a chart drawn in accent colour on ground. Inverting to
/// paper would mean re-picking every series colour for contrast on white and
/// would put a torch in the reader's face at the hour they most use it. So the
/// ground is dark — but WARM dark, mixed toward the same paper rather than the
/// blue-black this app used to have (`#07090C`). Set the two side by side and
/// the old one reads as a screen, this one as ink.
///
/// **The accents are the brand's two strokes.** The mark is a cool line rising
/// into a warm one — a biphasic shift, which is precisely what this band
/// measures. Cool `#5A6A94` and warm `#A55D1C` are both too dark to sit on a
/// dark ground, so each is lifted along its own hue rather than replaced.
/// [kAccent2] stays violet on purpose: four series share these screens and
/// collapsing them onto a two-colour brand axis would make strain and
/// temperature indistinguishable at a glance, which is a worse sin than being
/// slightly off-brand in one chart.
library;

import 'package:flutter/material.dart';

import '../data/profile.dart';
import '../data/store.dart';
import 'profile_edit.dart' show formatWeightKg;

import '../analytics/metrics.dart';

/// The palette, in two versions.
///
/// These used to be top-level `const Color`s and the app was dark-only. A
/// wearable is opened outdoors in daylight, which is the one place a dark
/// screen is hardest to read — so there is a light set too, and the names
/// below resolve to whichever one is active.
///
/// Resolved through getters rather than through Theme.of(context) because 180
/// call sites read these names directly, many of them outside a build method.
/// The trade is that they are no longer compile-time constants; that is what
/// makes them able to change.
class Palette {
  final Color bg, card, cardAlt, accent, accent2, warn, bad, green, text, muted;

  /// Hairlines. The redesign draws structure with 1px rules and a shared
  /// ground rather than with elevated rounded cards, so this is a token in its
  /// own right instead of an opacity applied to the text colour.
  final Color rule;

  /// Sleep stages. Fixed to the stage, not to the accent ramp: deep, light and
  /// awake have to stay distinguishable from each other in a hypnogram, and
  /// borrowing UI accents made the chart change meaning when the accent did.
  final Color deep, lightSleep, awake;

  const Palette({
    required this.bg,
    required this.card,
    required this.cardAlt,
    required this.accent,
    required this.accent2,
    required this.warn,
    required this.bad,
    required this.green,
    required this.text,
    required this.muted,
    required this.rule,
    required this.deep,
    required this.lightSleep,
    required this.awake,
  });
}

/// Warm near-black — the brand's paper, inverted, not a blue-black screen.
/// The accents are the mark's cool and warm strokes, lifted for a dark ground.
const _darkPalette = Palette(
  bg: Color(0xFF12100E),
  card: Color(0xFF1B1815),
  cardAlt: Color(0xFF232019),
  accent: Color(0xFF7FA0DC),
  accent2: Color(0xFF9B8AD4),
  warn: Color(0xFFD98A3A),
  bad: Color(0xFFD9614F),
  green: Color(0xFF7FB49A),
  text: Color(0xFFF2EFEA),
  muted: Color(0xFF9A9289),
  rule: Color(0xFF2C2721),
  deep: Color(0xFF4E6FA8),
  lightSleep: Color(0xFF8FA6CE),
  awake: Color(0xFFD98A3A),
);

/// The brand's paper the right way up. The hues are the same family, taken
/// DOWN in lightness rather than reused: the dark set is lifted for a dark
/// ground, and those same values on white fail contrast for small text.
const _lightPalette = Palette(
  bg: Color(0xFFF7F4EE),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFEFE9DE),
  accent: Color(0xFF3E5F98),
  accent2: Color(0xFF6250A8),
  warn: Color(0xFFA55D1C),
  bad: Color(0xFFB0432F),
  green: Color(0xFF5C7A63),
  text: Color(0xFF17150F),
  muted: Color(0xFF6B6155),
  rule: Color(0xFFE5DED2),
  deep: Color(0xFF2F4A73),
  lightSleep: Color(0xFF7B93BF),
  awake: Color(0xFFC98A4B),
);

Palette _active = _darkPalette;

/// Point the names below at the palette for [b]. Called from the one Builder
/// under MaterialApp, so it follows the theme the framework resolved rather
/// than a second copy of the decision.
void applyPaletteFor(Brightness b) {
  _active = b == Brightness.dark ? _darkPalette : _lightPalette;
}

Color get kBg => _active.bg;
Color get kCard => _active.card;
Color get kCardAlt => _active.cardAlt;
Color get kAccent => _active.accent;
Color get kAccent2 => _active.accent2;
Color get kWarn => _active.warn;
Color get kBad => _active.bad;
Color get kGreen => _active.green;
Color get kText => _active.text;
Color get kMuted => _active.muted;
Color get kRule => _active.rule;
Color get kDeep => _active.deep;
Color get kLightSleep => _active.lightSleep;
Color get kAwake => _active.awake;

/// Newsreader — the brand serif. Figures and titles only.
const kSerif = 'Newsreader';

/// Archivo — the brand sans. Everything the reader reads as prose.
const kSans = 'Archivo';

/// IBM Plex Mono — the brand mono. Frames, opcodes, the activity log: text
/// where column alignment carries meaning.
const kMono = 'IBMPlexMono';

ThemeData buildTheme([Brightness brightness = Brightness.dark]) {
  final p = brightness == Brightness.dark ? _darkPalette : _lightPalette;
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  final t = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: p.accent,
      secondary: p.accent2,
      surface: p.card,
      error: p.bad,
    ),
    // Material's default pill is `secondaryContainer` — a lavender that has
    // nothing to do with this palette and read as a different app's chrome
    // sitting under the tabs. The selection is the accent, at the weight
    // everything else on the page uses.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.card,
      indicatorColor: p.accent.withValues(alpha: 0.13),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            size: 20,
            color: states.contains(WidgetState.selected) ? p.accent : p.muted,
          )),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontFamily: kMono,
            fontSize: 9.5,
            letterSpacing: 1.0,
            color: states.contains(WidgetState.selected) ? p.text : p.muted,
          )),
    ),
    dividerTheme: DividerThemeData(color: p.rule, space: 1, thickness: 1),
    // Hairline panels, not floating cards. An 18px radius and a fill that
    // differs from the ground is a card FLOATING above the page; the redesign
    // draws structure with 1px rules on a shared ground, so the corner goes
    // and the border does the work.
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(2)),
        side: BorderSide(color: p.rule),
      ),
    ),
    // Controls follow the same geometry. A stadium-shaped button next to a
    // square panel reads as two design systems in one screen.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(2))),
        textStyle: const TextStyle(fontFamily: kSans, fontSize: 13.5, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(2))),
        side: BorderSide(color: p.rule),
        foregroundColor: p.text,
        textStyle: const TextStyle(fontFamily: kSans, fontSize: 13.5, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card,
      selectedColor: p.text,
      side: BorderSide(color: p.rule),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(2))),
      labelStyle: TextStyle(fontFamily: kMono, fontSize: 10.5, color: p.text),
      secondaryLabelStyle: TextStyle(fontFamily: kMono, fontSize: 10.5, color: p.bg),
      showCheckmark: false,
    ),
    // Serif for the figures, sans for the prose. The big numerals are the
    // thing you look at on a health screen, and Newsreader gives them a
    // character a UI sans cannot — while Archivo keeps the labels and body
    // plain, which is what labels are for.
    textTheme: t.copyWith(
      displayLarge: t.displayLarge?.copyWith(fontFamily: kSerif),
      displayMedium: t.displayMedium?.copyWith(fontFamily: kSerif),
      displaySmall: t.displaySmall?.copyWith(fontFamily: kSerif),
      headlineLarge: t.headlineLarge?.copyWith(fontFamily: kSerif),
      headlineMedium: t.headlineMedium?.copyWith(fontFamily: kSerif),
      headlineSmall: t.headlineSmall?.copyWith(fontFamily: kSerif),
      titleLarge: t.titleLarge?.copyWith(fontFamily: kSerif),
      titleMedium: t.titleMedium?.copyWith(fontFamily: kSans),
      titleSmall: t.titleSmall?.copyWith(fontFamily: kSans),
      bodyLarge: t.bodyLarge?.copyWith(fontFamily: kSans),
      bodyMedium: t.bodyMedium?.copyWith(fontFamily: kSans),
      bodySmall: t.bodySmall?.copyWith(fontFamily: kSans),
      labelLarge: t.labelLarge?.copyWith(fontFamily: kSans),
      labelMedium: t.labelMedium?.copyWith(fontFamily: kSans),
      labelSmall: t.labelSmall?.copyWith(fontFamily: kSans),
    ),
  );
}

/// The Rua Science mark: a cool stroke rising into a warm one.
///
/// Drawn rather than shipped as an SVG so it needs no asset, no decoder and no
/// package — it is six line segments. The path data is the site's verbatim, on
/// its 30x16 viewBox, scaled to whatever [size] asks for.
class RuaMark extends StatelessWidget {
  final double size;
  const RuaMark({super.key, this.size = 30});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size * 16 / 30), painter: _RuaMarkPainter());
}

class _RuaMarkPainter extends CustomPainter {
  static const _cool = [Offset(1, 11.2), Offset(5.4, 10.4), Offset(9.6, 11.8), Offset(13, 12.6)];
  static const _warm = [Offset(13, 12.6), Offset(16.2, 5.2), Offset(20.6, 4.2), Offset(25, 5), Offset(29, 4.4)];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 30;
    void stroke(List<Offset> pts, Color c) {
      final path = Path()..moveTo(pts.first.dx * k, pts.first.dy * k);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx * k, p.dy * k);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.7 * k
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    }

    stroke(_cool, kAccent);
    stroke(_warm, kWarn);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The mark beside the name, as the site sets it.
class RuaWordmark extends StatelessWidget {
  final double markSize;
  const RuaWordmark({super.key, this.markSize = 26});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RuaMark(size: markSize),
          const SizedBox(width: 8),
          Text('Rua Science',
              style: TextStyle(
                fontFamily: kSerif,
                fontSize: markSize * 0.62,
                fontWeight: FontWeight.w600,
                color: kText,
                letterSpacing: 0.2,
              )),
        ],
      );
}

/// Card with a title row and optional trailing chevron/action.
class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? tint;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      color: tint ?? kCard,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: t.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!,
                              style: t.textTheme.bodySmall
                                  ?.copyWith(color: kMuted)),
                        ),
                    ],
                  ),
                ),
                ?trailing,
                if (trailing == null && onTap != null)
                  Icon(Icons.chevron_right, color: kMuted),
              ]),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Big number + unit + label.
class BigStat extends StatelessWidget {
  final String value;
  final String unit;
  final String label;
  final Color? color;
  const BigStat(this.value, this.unit, this.label, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // One node reading "battery, 84 percent" instead of three fragments —
    // "84", "%", "battery" — arriving in the order they happen to be laid out.
    return Semantics(
      label: '$label, $value${unit.isEmpty ? '' : ' $unit'}',
      excludeSemantics: true,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: t.textTheme.headlineMedium?.copyWith(
                    color: color ?? kText, fontWeight: FontWeight.w600)),
            if (unit.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(unit,
                    style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
              ),
          ],
        ),
        Text(label, style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
      ],
      ),
    );
  }
}

/// Shows an Estimate, or an honest placeholder when it could not be computed.
class EstimateTile extends StatelessWidget {
  final String label;
  final Estimate? estimate;
  final String emptyHint;
  final Color? color;
  const EstimateTile({
    super.key,
    required this.label,
    required this.estimate,
    required this.emptyHint,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (estimate == null) {
      return Semantics(
        label: 'Not available — $emptyHint',
        excludeSemantics: true,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('—',
              style: t.textTheme.headlineMedium?.copyWith(color: kMuted)),
          Text(label, style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
          const SizedBox(height: 2),
          SizedBox(
            width: 130,
            child: Text(emptyHint,
                style: t.textTheme.labelSmall
                    ?.copyWith(color: kMuted.withValues(alpha: 0.7))),
          ),
        ],
        ),
      );
    }
    final e = estimate!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        BigStat(e.display, e.unit, label, color: color),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle,
              size: 7,
              color: e.confidence >= 0.75
                  ? kAccent
                  : (e.confidence >= 0.45 ? kWarn : kBad)),
          const SizedBox(width: 4),
          Text(e.confidenceLabel,
              style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
        ]),
      ],
    );
  }
}

/// Concentric activity rings, as on the vendor's Health tab.
class ActivityRings extends StatelessWidget {
  final double steps, stepGoal;
  final double kcal, kcalGoal;
  final double km, kmGoal;
  final double size;
  const ActivityRings({
    super.key,
    required this.steps,
    required this.stepGoal,
    required this.kcal,
    required this.kcalGoal,
    required this.km,
    required this.kmGoal,
    this.size = 130,
  });

  /// Percentages rather than raw numbers: the figures are already spelled out
  /// in the legend beside these, and repeating them would read the same values
  /// twice. What the rings add is the PROPORTION, which is exactly what a
  /// painted arc cannot say on its own.
  String get _spoken {
    String pct(double v, double goal) =>
        '${((goal == 0 ? 0 : v / goal) * 100).round()} percent of goal';
    return 'Activity rings. Steps ${pct(steps, stepGoal)}. '
        'Calories ${pct(kcal, kcalGoal)}. Distance ${pct(km, kmGoal)}.';
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: _spoken,
        excludeSemantics: true,
        child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter([
            // Same three colours as the legend beside them. These were left
            // on the old neon quartet when the legend was rebranded, so the
            // ring and its own label disagreed — the dot said one blue, the
            // arc drew another.
            (steps / (stepGoal == 0 ? 1 : stepGoal), kAccent),
            (kcal / (kcalGoal == 0 ? 1 : kcalGoal), kGreen),
            (km / (kmGoal == 0 ? 1 : kmGoal), kWarn),
          ]),
        ),
        ),
      );
}

class _RingPainter extends CustomPainter {
  final List<(double, Color)> rings;
  _RingPainter(this.rings);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final stroke = size.width * 0.10;
    for (var i = 0; i < rings.length; i++) {
      final r = size.width / 2 - stroke / 2 - i * (stroke + 4);
      if (r <= 0) continue;
      final (frac, colour) = rings[i];
      final bg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = colour.withValues(alpha: 0.16)
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(c, r, bg);
      final fg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = colour
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -1.5708,
          6.2832 * frac.clamp(0.0, 1.0), false, fg);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.rings != rings;
}

/// Compact sparkline for a metric's recent trend.
/// One decimal at most: a spoken "seventy-two point four one three" is worse
/// than useless.
String _n(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color? color;
  final double height;

  /// `color` is nullable and resolved at build time rather than defaulted
  /// here: the palette is no longer a compile-time constant, which is the
  /// price of it being able to follow the theme.
  const Sparkline(this.values,
      {super.key, this.color, this.height = 46});

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('not enough data yet',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: kMuted)),
        ),
      );
    }
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final direction = values.last > values.first
        ? 'rising'
        : values.last < values.first
            ? 'falling'
            : 'level';
    return Semantics(
      // The shape of a line is the whole content of this widget, and a
      // CustomPaint publishes nothing. Range and direction are what someone
      // reads off it at a glance.
      label: 'Trend, $direction. '
          '${values.length} readings from ${_n(lo)} to ${_n(hi)}, '
          'latest ${_n(values.last)}.',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _SparkPainter(values, color ?? kAccent)),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> v;
  final Color color;
  _SparkPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final lo = v.reduce((a, b) => a < b ? a : b);
    final hi = v.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = size.width * i / (v.length - 1);
      final y = size.height - (v[i] - lo) / span * size.height * 0.86 -
          size.height * 0.07;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.v != v;
}

/// Standard empty state, so no screen ever shows a bare blank.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      required this.hint,
      this.action});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 24),
      child: Column(children: [
        Icon(icon, size: 38, color: kMuted),
        const SizedBox(height: 12),
        Text(title, style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(hint,
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

// ---------------------------------------------------------------- units

/// Display formatting for the two unit systems.
///
/// Conversion happens HERE, at the edge, and never on the way into storage.
/// Every stored value stays metric — the band reports metric, the server
/// stores metric, and a column holding both would be the same class of bug as
/// the `metric` field that once meant two different things.
class Units {
  final UnitSystem system;
  const Units(this.system);

  factory Units.of(Profile p) => Units(p.units);

  bool get imperial => system == UnitSystem.imperial;

  String distance(double km) => imperial
      ? '${(km * 0.621371).toStringAsFixed(2)} mi'
      : '${km.toStringAsFixed(2)} km';

  String distanceValue(double km) => imperial
      ? (km * 0.621371).toStringAsFixed(2)
      : km.toStringAsFixed(2);

  String get distanceUnit => imperial ? 'mi' : 'km';

  String weight(double kg) => imperial
      ? '${(kg * 2.20462).round()} lb'
      : '${formatWeightKg(kg)} kg';

  /// Feet and inches, because 5'9" is how the height of a person is said in
  /// the places that use it — "69 in" is a conversion, not a unit anyone uses.
  String height(int cm) {
    if (!imperial) return '$cm cm';
    final totalInches = (cm / 2.54).round();
    return "${totalInches ~/ 12}'${totalInches % 12}\"";
  }

  String temperature(double celsius) => imperial
      ? '${(celsius * 9 / 5 + 32).toStringAsFixed(1)} °F'
      : '${celsius.toStringAsFixed(1)} °C';

  String get temperatureUnit => imperial ? '°F' : '°C';

  double temperatureValue(double celsius) =>
      imperial ? celsius * 9 / 5 + 32 : celsius;
}

// ------------------------------------------------- the redesign's vocabulary

/// A monospaced, letter-spaced caption. The label style of the whole app.
class Lab extends StatelessWidget {
  final String text;
  final Color? color;
  const Lab(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: kMono,
          fontSize: 9.5,
          letterSpacing: 1.05,
          height: 1.35,
          color: color ?? kMuted,
        ),
      );
}

/// The sentence a derived figure carries about where it came from.
///
/// The app already computed these — "lowest sustained 25 s during
/// 00:00–06:00", "overnight HRV vs your own 12-night baseline" — and buried
/// them in a tooltip or dropped them. Printing them under the figure is the
/// design: a number on a health screen is worth what its provenance is worth.
class Basis extends StatelessWidget {
  final String text;
  const Basis(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontFamily: kMono,
          fontSize: 9,
          height: 1.45,
          color: kMuted.withValues(alpha: 0.85),
        ),
      );
}

/// A figure, in the brand serif, with its unit tucked in at label size.
class Figure extends StatelessWidget {
  final String value;
  final String unit;
  final double size;
  final Color? color;
  const Figure(this.value, {super.key, this.unit = '', this.size = 34, this.color});

  @override
  Widget build(BuildContext context) => RichText(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: kSerif,
            fontWeight: FontWeight.w500,
            fontSize: size,
            height: 1.05,
            letterSpacing: -0.5,
            color: color ?? kText,
          ),
          children: unit.isEmpty
              ? null
              : [
                  TextSpan(
                    text: unit,
                    style: TextStyle(
                      fontFamily: kSans,
                      fontWeight: FontWeight.w400,
                      fontSize: size * 0.34,
                      color: kMuted,
                    ),
                  ),
                ],
        ),
      );
}

/// A day of one signal, drawn against a fixed 24-hour axis.
///
/// The anchor of the redesign. A day is a continuous thing and the band
/// records it continuously; drawing it as one trace — with the hours asleep
/// shaded and the latest reading marked — says more about the day than any
/// arrangement of tiles can, and it makes two days comparable at a glance
/// because the axis never moves.
class DayRibbon extends StatelessWidget {
  /// The samples for THIS day only.
  ///
  /// The axis is a fixed 24 hours, so anything outside the day is drawn at
  /// one edge or the other — a fortnight of readings all pile up on 00:00
  /// and the trace becomes a vertical smear that still looks like a day.
  final List<Sample> samples;
  final DateTime day;
  final Color colour;

  /// Spans actually recorded as sleep, shaded behind the trace.
  ///
  /// Measured, not assumed: this was a fixed 00:00-07:00 band, which the
  /// caption then described as "asleep". Somebody who slept from 01:30 to
  /// 09:00 got a shaded band that was wrong at both ends and asserted as
  /// fact. Empty shades nothing, which is the honest answer when the band
  /// recorded no sleep.
  final List<DateTimeRange> asleep;

  const DayRibbon({
    super.key,
    required this.samples,
    required this.day,
    required this.colour,
    this.asleep = const [],
  });

  @override
  Widget build(BuildContext context) {
    final start = DateTime(day.year, day.month, day.day);
    return Semantics(
      label: _spoken(start),
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(color: kCard, border: Border.all(color: kRule)),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
        child: Column(children: [
          SizedBox(
            height: 120,
            width: double.infinity,
            child: CustomPaint(
              painter: _RibbonPainter(
                samples: samples,
                start: start,
                colour: colour,
                rule: kRule.withValues(alpha: 0.65),
                night: kCardAlt,
                asleep: asleep,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [Lab('00'), Lab('06'), Lab('12'), Lab('18'), Lab('24')],
          ),
        ]),
      ),
    );
  }

  String _spoken(DateTime start) {
    if (samples.isEmpty) return 'No readings for this day.';
    final vals = samples.map((s) => s.value).toList();
    final lo = vals.reduce((a, b) => a < b ? a : b);
    final hi = vals.reduce((a, b) => a > b ? a : b);
    return 'Day trace. ${samples.length} readings from '
        '${lo.round()} to ${hi.round()}, latest ${vals.last.round()}.';
  }
}

class _RibbonPainter extends CustomPainter {
  final List<Sample> samples;
  final DateTime start;
  final Color colour, rule, night;
  final List<DateTimeRange> asleep;

  _RibbonPainter({
    required this.samples,
    required this.start,
    required this.colour,
    required this.rule,
    required this.night,
    required this.asleep,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The night bands first, so the trace sits on top of them. Each span is
    // clipped to the day: a night that began yesterday evening shows only the
    // part of itself that belongs on this axis.
    final shade = Paint()..color = night;
    final end = start.add(const Duration(days: 1));
    for (final r in asleep) {
      final from = r.start.isBefore(start) ? start : r.start;
      final to = r.end.isAfter(end) ? end : r.end;
      if (!to.isAfter(from)) continue;
      final x0 = size.width * (from.difference(start).inSeconds / 86400.0);
      final x1 = size.width * (to.difference(start).inSeconds / 86400.0);
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, size.height), shade);
    }

    final grid = Paint()
      ..color = rule
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (samples.length < 2) return;

    final vals = samples.map((s) => s.value).toList();
    var lo = vals.reduce((a, b) => a < b ? a : b);
    var hi = vals.reduce((a, b) => a > b ? a : b);
    // A flat day would divide by zero and, worse, draw a line through the
    // middle as though it were the mean of a range it never had.
    if (hi - lo < 1) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;

    double xFor(DateTime t) =>
        size.width * (t.difference(start).inSeconds / 86400.0).clamp(0.0, 1.0);
    double yFor(double v) =>
        size.height - ((v - lo) / (hi - lo)) * size.height;

    final path = Path()..moveTo(xFor(samples.first.at), yFor(samples.first.value));
    for (final s in samples.skip(1)) {
      path.lineTo(xFor(s.at), yFor(s.value));
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = colour);

    // The latest reading, marked where it happened rather than at the edge.
    final last = samples.last;
    final lx = xFor(last.at), ly = yFor(last.value);
    canvas.drawCircle(Offset(lx, ly), 3, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_RibbonPainter old) =>
      old.samples != samples || old.colour != colour || old.asleep != asleep;
}

/// One measure against the goal set for it.
class GoalBar extends StatelessWidget {
  final String label, value, goal;
  final double fraction;
  final Color colour;
  const GoalBar({
    super.key,
    required this.label,
    required this.value,
    required this.goal,
    required this.fraction,
    required this.colour,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label, $value of $goal',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label, style: TextStyle(fontSize: 13, color: kText)),
            RichText(
              text: TextSpan(
                text: value,
                style: TextStyle(fontFamily: kMono, fontSize: 12, color: kText),
                children: [
                  TextSpan(
                      text: '  $goal',
                      style: TextStyle(fontFamily: kMono, fontSize: 12, color: kMuted)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 4),
          // A 3px rule, not a rounded pill: the same hairline vocabulary as
          // everything else on the screen.
          SizedBox(
            height: 3,
            child: LayoutBuilder(
              builder: (context, c) => Stack(children: [
                Container(width: c.maxWidth, height: 3, color: kRule),
                Container(
                    width: c.maxWidth * fraction.clamp(0.0, 1.0),
                    height: 3,
                    color: colour),
              ]),
            ),
          ),
        ]),
      );
}

/// Cells divided by hairlines, sharing the page's ground.
///
/// Rows size to their tallest cell. This was a `GridView.count` with a fixed
/// `childAspectRatio`, which gave every cell the same height whatever it held
/// — and the cells hold a figure plus the sentence saying where the figure
/// came from ("lowest sustained 25 s during 00:00-06:00"). That sentence is
/// the difference between a reading and a claim, and a fixed cell height cut
/// it off mid-line. The basis is not the part to truncate.
class RuleGrid extends StatelessWidget {
  final List<Widget> children;
  final int columns;
  const RuleGrid({super.key, required this.children, this.columns = 3});

  @override
  Widget build(BuildContext context) {
    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += columns) {
      final end = i + columns;
      rows.add(children.sublist(i, end > children.length ? children.length : end));
    }
    return Container(
      decoration: BoxDecoration(
        color: kRule,
        border: Border.symmetric(horizontal: BorderSide(color: kRule)),
      ),
      child: Column(children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) Container(height: 1, color: kRule),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) Container(width: 1, color: kRule),
                  Expanded(
                    child: Container(
                      color: kBg,
                      padding: const EdgeInsets.all(12),
                      // A short last row keeps its empty cells so the columns
                      // stay the same width as the rows above.
                      child: c < rows[r].length
                          ? rows[r][c]
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ]),
    );
  }
}
