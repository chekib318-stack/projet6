import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../core/constants.dart';
import '../services/classic_bt_service.dart';
import '../providers/ble_scanner.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// ZONE DETECTOR — works directly in RSSI (dBm) space — NO path-loss formula
//
// The path-loss formula (d = 10^((Tx-RSSI)/25)) is unreliable indoors because
// reflections, walls, and human bodies cause ±10 dBm variance at fixed distance.
// Professional BT proximity systems use RSSI THRESHOLDS + HYSTERESIS instead.
//
// Thresholds (tuneable via calibration):
//   Danger  : RSSI > -60 dBm  (≈ < 0.7m)
//   Near    : RSSI > -70 dBm  (≈ 0.7 – 1.5m)
//   Medium  : RSSI > -80 dBm  (≈ 1.5 – 3m)
//   Far     : RSSI ≤ -80 dBm  (≈ > 3m)
// ═══════════════════════════════════════════════════════════════════════════════
class _ZoneDetector {
  // Hysteresis: ENTER threshold is tighter than EXIT threshold
  // This prevents zone flickering when RSSI oscillates near a boundary
  double _tDangerEnter = -60.0;  double _tDangerExit = -66.0;
  double _tNearEnter   = -70.0;  double _tNearExit   = -76.0;
  double _tMediumEnter = -80.0;  double _tMediumExit = -86.0;

  final List<int> _buf = [];   // rolling 3-second buffer
  static const int _N  = 15;  // 15 samples × 200ms = 3 seconds

  _Zone _state = _Zone.far;
  int   _stableCount = 0;      // consecutive samples in same zone

  void addSample(int rssi) {
    _buf.add(rssi);
    if (_buf.length > _N) _buf.removeAt(0);
    if (_buf.length >= 5) _updateState();
  }

  // 75th-percentile RSSI: more sensitive to close devices
  // (rejects weak-signal outliers → stable when still)
  double get rssi75 {
    if (_buf.isEmpty) return -90.0;
    final s = List<int>.from(_buf)..sort((a, b) => b.compareTo(a));
    return s[(_buf.length * 0.25).round().clamp(0, _buf.length - 1)].toDouble();
  }

  // Also expose raw RSSI for display
  int get rawRssi => _buf.isEmpty ? -90 : _buf.last;

  void _updateState() {
    final r = rssi75;
    _Zone proposed;

    switch (_state) {
      case _Zone.far:
        proposed = r >= _tMediumEnter ? _Zone.medium : _Zone.far;
      case _Zone.medium:
        if      (r >= _tNearEnter)  proposed = _Zone.near;
        else if (r <  _tMediumExit) proposed = _Zone.far;
        else                        proposed = _Zone.medium;
      case _Zone.near:
        if      (r >= _tDangerEnter) proposed = _Zone.danger;
        else if (r <  _tNearExit)    proposed = _Zone.medium;
        else                         proposed = _Zone.near;
      case _Zone.danger:
        proposed = r < _tDangerExit ? _Zone.near : _Zone.danger;
    }

    if (proposed != _state) {
      _stableCount++;
      // Require 2 consecutive "change" samples before switching zone
      // Prevents single-sample spikes from triggering zone change
      if (_stableCount >= 2) { _state = proposed; _stableCount = 0; }
    } else {
      _stableCount = 0;
    }
  }

  _Zone get zone => _state;

  // Calibration: adjust thresholds based on 3 measured points
  void calibrate(double rssiAt05m, double rssiAt1m, double rssiAt2m) {
    _tDangerEnter = rssiAt05m - 2;  _tDangerExit = rssiAt05m - 8;
    _tNearEnter   = rssiAt1m  - 2;  _tNearExit   = rssiAt1m  - 8;
    _tMediumEnter = rssiAt2m  - 2;  _tMediumExit = rssiAt2m  - 8;
  }

  Map<String, double> get thresholds => {
    'dangerEnter': _tDangerEnter, 'nearEnter': _tNearEnter,
    'mediumEnter': _tMediumEnter,
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
class FindDistanceScreen extends StatefulWidget {
  final NativeDevice device;
  final BleScanner   scanner;
  const FindDistanceScreen(
      {super.key, required this.device, required this.scanner});
  @override
  State<FindDistanceScreen> createState() => _FindDistanceScreenState();
}

class _FindDistanceScreenState extends State<FindDistanceScreen>
    with TickerProviderStateMixin {

  late AnimationController _pulseCtrl;
  final _detector  = _ZoneDetector();
  final _player    = AudioPlayer();

  _Zone _prevZone      = _Zone.far;
  bool  _alerted       = false;
  int   _updates       = 0;
  int   _tick          = 0;

  // Calibration state
  bool           _calibrating = false;
  int            _calStep     = 0;   // 0=idle, 1=0.5m, 2=1m, 3=2m
  final List<double> _calRssi = [];  // collected RSSI during calibration
  double? _cal05, _cal1, _cal2;

  Timer? _timer;

  NativeDevice get _dev =>
      widget.scanner.devices[widget.device.address.replaceAll(':', '')]
      ?? widget.device;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final dev = _dev;
      if (dev.rssi == 0 || dev.rssi < -105) return;

      _detector.addSample(dev.rssi);
      _tick++;

      if (_tick % 5 == 0) { // update UI every second (5 × 200ms)
        final z = _detector.zone;
        setState(() { _updates = dev.updateCount; });

        // Danger alert
        if (z == _Zone.danger && !_alerted) {
          _alerted = true;
          _triggerAlert();
        } else if (z != _Zone.danger) {
          _alerted = false;
        }
        _prevZone = z;

        // Calibration: collect samples
        if (_calibrating && _calStep > 0) {
          _calRssi.add(dev.rssi.toDouble());
        }
      }
    });
  }

  Future<void> _triggerAlert() async {
    HapticFeedback.heavyImpact();
    try { await _player.play(AssetSource('beep_critical.mp3'), volume: 1.0); }
    catch (_) {}
    await Future.delayed(const Duration(milliseconds: 350));
    HapticFeedback.heavyImpact();
  }

  // ── Calibration flow ─────────────────────────────────────────────────────
  void _startCalibration() {
    setState(() {
      _calibrating = true;
      _calStep     = 1;
      _calRssi.clear();
      _cal05 = _cal1 = _cal2 = null;
    });
  }

  void _nextCalStep() {
    if (_calRssi.isEmpty) return;
    final avg = _calRssi.reduce((a, b) => a + b) / _calRssi.length;
    switch (_calStep) {
      case 1: _cal05 = avg;
      case 2: _cal1  = avg;
      case 3:
        _cal2 = avg;
        // Apply calibration
        _detector.calibrate(_cal05!, _cal1!, _cal2!);
        setState(() { _calibrating = false; _calStep = 0; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('تمت المعايرة بنجاح')));
        return;
    }
    setState(() {
      _calStep++;
      _calRssi.clear();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final z = _detector.zone;
    final c = z.color;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded,
              color: AppColors.textSecondary, size: 20),
          onPressed: () => Navigator.pop(ctx)),
        title: Row(children: [
          Text(_dev.typeIcon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          const Expanded(child: Text('كشف القرب',
              style: TextStyle(color: AppColors.textPrimary,
                  fontSize: 15, fontWeight: FontWeight.w600))),
          // Calibrate button
          TextButton.icon(
            onPressed: _calibrating ? null : _startCalibration,
            icon: const Icon(Icons.tune_rounded, size: 15),
            label: const Text('معايرة', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.medium,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4))),
        ]),
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(children: [

          // ── CALIBRATION WIZARD ───────────────────────────────────────
          if (_calibrating) _calWizard(),
          if (_calibrating) const SizedBox(height: 12),

          // ── DANGER BANNER ────────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: z == _Zone.danger
                ? _dangerBanner()
                : const SizedBox.shrink(),
          ),
          if (z == _Zone.danger) const SizedBox(height: 8),

          // ── BIG ZONE INDICATOR + RSSI bar ────────────────────────────
          _zoneCard(z, c),

          const SizedBox(height: 14),

          // ── Zone progress bar ─────────────────────────────────────────
          _zoneBar(z),

          const SizedBox(height: 14),

          // ── RSSI detail card ──────────────────────────────────────────
          _rssiCard(c),

          const SizedBox(height: 12),

          // ── Signal history ────────────────────────────────────────────
          _signalHistory(c),

          const SizedBox(height: 12),

          // ── Device info ───────────────────────────────────────────────
          _deviceInfo(),

          const SizedBox(height: 12),

          // ── Calibration status ────────────────────────────────────────
          _calStatus(),
        ]),
      ),
    );
  }

  // ── CALIBRATION WIZARD ────────────────────────────────────────────────────
  Widget _calWizard() {
    final steps = [
      (dist: '50 سم',   icon: '📏', msg: 'ضع الهاتف على بعد 50 سم من الجهاز'),
      (dist: '1 متر',   icon: '📐', msg: 'ابتعد 1 متر من الجهاز'),
      (dist: '2 متر',   icon: '📏', msg: 'ابتعد 2 متر من الجهاز'),
    ];
    if (_calStep == 0 || _calStep > 3) return const SizedBox.shrink();
    final s = steps[_calStep - 1];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.medium.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.medium.withOpacity(0.4), width: 1)),
      child: Column(children: [
        Row(children: [
          Text(s.icon, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('معايرة — خطوة $_calStep/3',
                style: const TextStyle(color: AppColors.medium,
                    fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 3),
            Text(s.msg, style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12)),
          ])),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text(
            'عينات: ${_calRssi.length}  RSSI: ${_dev.rssi} dBm',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11))),
          ElevatedButton(
            onPressed: _calRssi.length >= 5 ? _nextCalStep : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.medium,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9))),
            child: Text(_calStep < 3 ? 'التالي ←' : 'إنهاء ✓')),
        ]),
      ]),
    );
  }

  // ── DANGER BANNER — white on dark ─────────────────────────────────────────
  Widget _dangerBanner() => AnimatedBuilder(
    animation: _pulseCtrl,
    builder: (_, __) => Container(
      key: const ValueKey('d'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A0000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.critical.withOpacity(
              0.5 + _pulseCtrl.value * 0.5), width: 2.0)),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
              color: AppColors.critical, shape: BoxShape.circle),
          child: const Icon(Icons.warning_rounded,
              color: Colors.white, size: 22)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('⚠  احذر جهاز غش بجانبك',
              style: TextStyle(color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Row(children: [
            _pill('أقل من 50 سم', const Color(0xFFFFD600)),
            const SizedBox(width: 8),
            _pill(_dev.typeLabel, Colors.white.withOpacity(0.85)),
          ]),
        ])),
      ])),
  );

  // ── MAIN ZONE CARD ────────────────────────────────────────────────────────
  Widget _zoneCard(_Zone z, Color c) {
    final arrow = _prevZone.index > z.index ? '↗ اقتراب'
        : _prevZone.index < z.index ? '↘ ابتعاد' : '→ ثابت';
    final arrowC = _prevZone.index > z.index ? AppColors.critical
        : _prevZone.index < z.index ? AppColors.safe : AppColors.textMuted;

    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) => Container(
        height: 240,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withOpacity(0.35), width: 1.0)),
        child: Stack(alignment: Alignment.center, children: [

          // Outer pulse ring (only in danger/near)
          if (z != _Zone.far) Container(
            width: 180 + _pulseCtrl.value * 14,
            height: 180 + _pulseCtrl.value * 14,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: c.withOpacity(0.03 + _pulseCtrl.value * 0.05))),

          // Zone ring
          Container(
            width: 170, height: 170,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: c.withOpacity(0.08),
              border: Border.all(color: c.withOpacity(0.5),
                  width: z == _Zone.danger ? 2.5 : 1.2))),

          // Content
          Column(mainAxisSize: MainAxisSize.min, children: [
            // Zone icon + label
            Text(z.icon, style: const TextStyle(fontSize: 42)),
            const SizedBox(height: 8),
            Text(z.rangeLabel, style: TextStyle(color: c,
                fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: c.withOpacity(0.14),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: c.withOpacity(0.4))),
              child: Text(z.labelAr, style: TextStyle(
                  color: c, fontSize: 11, fontWeight: FontWeight.w700))),
          ]),

          // Arrow (top-right corner)
          Positioned(top: 12, right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: arrowC.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: arrowC.withOpacity(0.3))),
              child: Text(arrow, style: TextStyle(
                  color: arrowC, fontSize: 11,
                  fontWeight: FontWeight.w700)))),

          // RSSI raw (bottom-right)
          Positioned(bottom: 12, right: 12,
            child: Text('${_detector.rawRssi} dBm',
                style: TextStyle(color: c.withOpacity(0.6), fontSize: 10))),
        ]),
      ));
  }

  // ── ZONE PROGRESS BAR ────────────────────────────────────────────────────
  Widget _zoneBar(_Zone z) {
    final thresholds = _detector.thresholds;
    final rawRssi = _detector.rssi75;
    // Normalise RSSI from -90 (far) to -40 (very close) = progress 0→1
    final progress = ((rawRssi - (-90)) / ((-40) - (-90))).clamp(0.0, 1.0);

    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('بعيد', style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
        Text('RSSI: ${rawRssi.toStringAsFixed(0)} dBm',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 9)),
        const Text('قريب', style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
      ]),
      const SizedBox(height: 5),
      Stack(children: [
        Container(
          height: 16, decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: const LinearGradient(colors: [
            Color(0xFF00E676), Color(0xFFFFD600),
            Color(0xFFFF6D00), Color(0xFFFF1744),
          ]))),
        // Position indicator
        AnimatedPositioned(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          left: (progress * (MediaQuery.of(context).size.width - 64))
              .clamp(0.0, MediaQuery.of(context).size.width - 64),
          top: 0,
          child: Container(width: 4, height: 16,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(2),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]))),
      ]),
      const SizedBox(height: 4),
      // Zone labels under bar
      Row(children: [
        _Zone.far, _Zone.medium, _Zone.near, _Zone.danger,
      ].map((zone) {
        final active = z == zone;
        return Expanded(child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.only(right: 3),
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: active ? zone.color.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? zone.color.withOpacity(0.7) : Colors.transparent)),
          child: Text(zone.shortLabel, textAlign: TextAlign.center,
              style: TextStyle(
                color: active ? zone.color : zone.color.withOpacity(0.35),
                fontSize: 9, fontWeight: active ? FontWeight.w800 : FontWeight.w400))));
      }).toList()),
    ]);
  }

  // ── RSSI CARD ─────────────────────────────────────────────────────────────
  Widget _rssiCard(Color c) {
    final rssi = _detector.rawRssi;
    final bars = rssi > -50 ? 4 : rssi > -65 ? 3 : rssi > -75 ? 2 : 1;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5)),
      child: Row(children: [
        Column(mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(4, (i) => Container(
              width: 9, height: 10.0 + i * 8,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(
                color: i < bars ? c : AppColors.border,
                borderRadius: BorderRadius.circular(3))))),
          const SizedBox(height: 4),
          Text('$rssi dBm', style: const TextStyle(
              color: AppColors.textMuted, fontSize: 9)),
        ]),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          const Text('إشارة البلوتوث الخام',
              style: TextStyle(color: AppColors.textMuted, fontSize: 10)),
          const SizedBox(height: 4),
          Text('P75: ${_detector.rssi75.toStringAsFixed(0)} dBm',
              style: TextStyle(color: c, fontSize: 22,
                  fontWeight: FontWeight.w900)),
          Text('تحديثات: $_updates',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: c.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withOpacity(0.3))),
          child: Text(bars == 4 ? 'ممتاز' : bars == 3 ? 'جيد'
              : bars == 2 ? 'متوسط' : 'ضعيف',
              style: TextStyle(color: c, fontSize: 11,
                  fontWeight: FontWeight.w700))),
      ]),
    );
  }

  // ── RSSI HISTORY ──────────────────────────────────────────────────────────
  Widget _signalHistory(Color c) => Container(
    height: 70,
    padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
    decoration: BoxDecoration(color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border, width: 0.5)),
    child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('مخطط الإشارة',
            style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
        Text('P75 = ${_detector.rssi75.toStringAsFixed(0)} dBm',
            style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 4),
      Expanded(child: CustomPaint(
        painter: _RssiChartPainter(List.from(_detector._buf), c),
        size: Size.infinite)),
    ]));

  // ── DEVICE INFO ───────────────────────────────────────────────────────────
  Widget _deviceInfo() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: AppColors.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border, width: 0.5)),
    child: Row(children: [
      Text(_dev.typeIcon, style: const TextStyle(fontSize: 26)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Directionality(textDirection: TextDirection.ltr,
          child: Text(_dev.name.isNotEmpty ? _dev.name : 'جهاز غير معروف',
            style: const TextStyle(color: AppColors.textPrimary,
                fontWeight: FontWeight.w700, fontSize: 14),
            overflow: TextOverflow.ellipsis)),
        const SizedBox(height: 3),
        Row(children: [
          Text(_dev.typeLabel, style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(width: 8),
          _badge(_dev.protocolBadge, AppColors.accent),
        ]),
      ])),
    ]),
  );

  // ── CALIBRATION STATUS ────────────────────────────────────────────────────
  Widget _calStatus() {
    if (_cal05 == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.safe.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.safe.withOpacity(0.2))),
      child: Row(children: [
        const Icon(Icons.check_circle_outline, color: AppColors.safe, size: 16),
        const SizedBox(width: 8),
        Text('المعايرة مفعّلة: '
            '50سم=${_cal05!.toStringAsFixed(0)} '
            '1م=${_cal1!.toStringAsFixed(0)} '
            '2م=${_cal2!.toStringAsFixed(0)} dBm',
            style: const TextStyle(color: AppColors.safe, fontSize: 10)),
      ]));
  }

  Widget _pill(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(7),
      border: Border.all(color: c.withOpacity(0.5), width: 0.8)),
    child: Text(t, style: TextStyle(color: c, fontSize: 12,
        fontWeight: FontWeight.w700)));

  Widget _badge(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(4),
      border: Border.all(color: c.withOpacity(0.25), width: 0.4)),
    child: Text(t, style: TextStyle(color: c, fontSize: 9,
        fontWeight: FontWeight.w600)));
}

// ── Zone enum ─────────────────────────────────────────────────────────────────
enum _Zone {
  far, medium, near, danger;

  Color get color => switch (this) {
    _Zone.far    => const Color(0xFF00E676),
    _Zone.medium => const Color(0xFFFFD600),
    _Zone.near   => const Color(0xFFFF6D00),
    _Zone.danger => const Color(0xFFFF1744),
  };

  String get icon => switch (this) {
    _Zone.far    => '🟢',
    _Zone.medium => '🟡',
    _Zone.near   => '🟠',
    _Zone.danger => '🔴',
  };

  // Range label (honest — no fake precision)
  String get rangeLabel => switch (this) {
    _Zone.far    => '> 2 متر',
    _Zone.medium => '1 – 2 متر',
    _Zone.near   => '50سم – 1م',
    _Zone.danger => 'أقل من 50سم',
  };

  String get labelAr => switch (this) {
    _Zone.far    => 'بعيد — خارج النطاق الحرج',
    _Zone.medium => 'متوسط — في محيط القاعة',
    _Zone.near   => 'قريب — يستوجب التدقيق',
    _Zone.danger => 'خطر مباشر — جهاز غش محتمل',
  };

  String get shortLabel => switch (this) {
    _Zone.far    => 'بعيد', _Zone.medium => 'متوسط',
    _Zone.near   => 'قريب', _Zone.danger => 'خطر',
  };
}

// ── RSSI Chart ────────────────────────────────────────────────────────────────
class _RssiChartPainter extends CustomPainter {
  final List<int> data;
  final Color     color;
  _RssiChartPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size sz) {
    if (data.length < 2) return;
    final minV = data.reduce(min).toDouble() - 5;
    final maxV = data.reduce(max).toDouble() + 5;
    final range = (maxV - minV).abs().clamp(1.0, 50.0);

    final linePaint = Paint()..color = color.withOpacity(0.7)
        ..strokeWidth = 2..style = PaintingStyle.stroke;
    final fillPaint = Paint()..color = color.withOpacity(0.1)
        ..style = PaintingStyle.fill;
    final path = Path(); final fp = Path();

    for (int i = 0; i < data.length; i++) {
      final x = i / (data.length - 1) * sz.width;
      final y = (1 - (data[i] - minV) / range) * sz.height;
      if (i == 0) { path.moveTo(x, y); fp.moveTo(x, sz.height); fp.lineTo(x, y); }
      else { path.lineTo(x, y); fp.lineTo(x, y); }
    }
    fp.lineTo(sz.width, sz.height); fp.close();
    canvas.drawPath(fp, fillPaint);
    canvas.drawPath(path, linePaint);
    final lx = sz.width;
    final ly = (1 - (data.last - minV) / range) * sz.height;
    canvas.drawCircle(Offset(lx, ly), 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RssiChartPainter o) => o.data != data;
}
