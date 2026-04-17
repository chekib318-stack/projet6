import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../core/constants.dart';
import '../services/classic_bt_service.dart';
import '../providers/ble_scanner.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Zone Detector — uses RSSI thresholds + hysteresis
// Default thresholds (recalibrated from real-world measurements):
//   Danger : P75 > -57 dBm  ≈ < 0.7m
//   Near   : P75 > -67 dBm  ≈ 0.7–1.5m
//   Medium : P75 > -77 dBm  ≈ 1.5–3m
//   Far    : P75 ≤ -77 dBm  ≈ > 3m
// ═══════════════════════════════════════════════════════════════════════════════
class _ZoneDetector {
  double _eDangerIn  = -57.0;  double _eDangerOut  = -63.0;
  double _eNearIn    = -67.0;  double _eNearOut    = -73.0;
  double _eMediumIn  = -77.0;  double _eMediumOut  = -83.0;

  final List<int> _buf = [];
  static const int _N  = 15;   // 3 seconds @ 5Hz

  _Zone _state       = _Zone.far;
  int   _changeCount = 0;      // require 2 consecutive readings before zone change

  void addSample(int rssi) {
    _buf.add(rssi);
    if (_buf.length > _N) _buf.removeAt(0);
    if (_buf.length >= 5) _evaluate();
  }

  // 75th percentile: sorts descending, takes 25th index = top 75% value
  double get p75 {
    if (_buf.isEmpty) return -90.0;
    final s = List<int>.from(_buf)..sort((a, b) => b.compareTo(a));
    final idx = (_buf.length * 0.25).round().clamp(0, _buf.length - 1);
    return s[idx].toDouble();
  }

  int get latest => _buf.isEmpty ? -90 : _buf.last;

  void _evaluate() {
    final r = p75;
    _Zone next;
    switch (_state) {
      case _Zone.far:
        next = r >= _eMediumIn ? _Zone.medium : _Zone.far;
      case _Zone.medium:
        if      (r >= _eNearIn)    next = _Zone.near;
        else if (r <  _eMediumOut) next = _Zone.far;
        else                       next = _Zone.medium;
      case _Zone.near:
        if      (r >= _eDangerIn)  next = _Zone.danger;
        else if (r <  _eNearOut)   next = _Zone.medium;
        else                       next = _Zone.near;
      case _Zone.danger:
        next = r < _eDangerOut ? _Zone.near : _Zone.danger;
    }
    if (next != _state) {
      _changeCount++;
      if (_changeCount >= 2) { _state = next; _changeCount = 0; }
    } else {
      _changeCount = 0;
    }
  }

  _Zone get zone => _state;

  // Signal strength 0-5 (from P75)
  int get signalBars {
    final r = p75;
    if (r >= _eDangerIn)  return 5;
    if (r >= _eNearIn)    return 4;
    if (r >= _eMediumIn)  return 3;
    if (r >= -82)         return 2;
    return 1;
  }

  void calibrate(double r05m, double r1m, double r2m) {
    _eDangerIn  = r05m - 3;  _eDangerOut  = r05m - 9;
    _eNearIn    = r1m  - 3;  _eNearOut    = r1m  - 9;
    _eMediumIn  = r2m  - 3;  _eMediumOut  = r2m  - 9;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
class FindDistanceScreen extends StatefulWidget {
  final NativeDevice device;
  final BleScanner   scanner;
  const FindDistanceScreen({super.key, required this.device, required this.scanner});
  @override
  State<FindDistanceScreen> createState() => _FindDistanceScreenState();
}

class _FindDistanceScreenState extends State<FindDistanceScreen>
    with TickerProviderStateMixin {

  late AnimationController _pulseCtrl;
  late AnimationController _alertCtrl;
  final _det    = _ZoneDetector();
  final _player = AudioPlayer();

  _Zone _prevZone    = _Zone.far;
  bool  _alertFired  = false;
  int   _updates     = 0;
  Timer? _timer;

  // Calibration
  bool          _calMode = false;
  int           _calStep = 0;
  List<int>     _calBuf  = [];
  List<double>  _calResults = [];

  NativeDevice get _dev =>
      widget.scanner.devices[widget.device.address.replaceAll(':', '')]
      ?? widget.device;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
    _alertCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));

    int tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final dev = _dev;
      if (dev.rssi == 0 || dev.rssi < -110) return;
      _det.addSample(dev.rssi);
      if (_calMode && _calStep > 0) _calBuf.add(dev.rssi);
      tick++;
      if (tick % 5 == 0) {
        final z = _det.zone;
        setState(() { _updates = dev.updateCount; _prevZone = z; });
        if (z == _Zone.danger && !_alertFired) {
          _alertFired = true;
          _alertCtrl.forward(from: 0);
          HapticFeedback.heavyImpact();
          _player.play(AssetSource('beep_critical.mp3'), volume: 1.0)
              .catchError((_) {});
          Future.delayed(const Duration(milliseconds: 350),
              () => HapticFeedback.heavyImpact());
        } else if (z != _Zone.danger) {
          _alertFired = false;
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    _alertCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  void _calNext() {
    if (_calBuf.length < 8) return;
    final avg = _calBuf.reduce((a, b) => a + b) / _calBuf.length;
    _calResults.add(avg);
    _calBuf.clear();
    if (_calStep == 3) {
      _det.calibrate(_calResults[0], _calResults[1], _calResults[2]);
      setState(() { _calMode = false; _calStep = 0; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت المعايرة ✓')));
    } else {
      setState(() => _calStep++);
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final z = _det.zone;
    final c = z.color;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _appBar(z),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        child: Column(children: [

          // Calibration wizard
          if (_calMode) ...[_calWidget(), const SizedBox(height: 12)],

          // Danger banner
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: z == _Zone.danger
                ? _dangerBanner()
                : const SizedBox.shrink()),
          if (z == _Zone.danger) const SizedBox(height: 10),

          // Main zone card
          _mainCard(z, c),
          const SizedBox(height: 14),

          // Signal strength meter (horizontal bars)
          _signalMeter(c),
          const SizedBox(height: 14),

          // Device info
          _deviceInfo(),
        ]),
      ),
    );
  }

  // ── App Bar ────────────────────────────────────────────────────────────────
  PreferredSizeWidget _appBar(_Zone z) => AppBar(
    backgroundColor: AppColors.surface,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded,
          color: AppColors.textSecondary, size: 20),
      onPressed: () => Navigator.pop(context)),
    title: Row(children: [
      Text(_dev.typeIcon, style: const TextStyle(fontSize: 18)),
      const SizedBox(width: 8),
      const Expanded(child: Text('كشف القرب',
          style: TextStyle(color: AppColors.textPrimary,
              fontSize: 15, fontWeight: FontWeight.w600))),
    ]),
    actions: [
      TextButton.icon(
        onPressed: () => setState(() {
          _calMode = !_calMode;
          _calStep = _calMode ? 1 : 0;
          _calBuf.clear();
          _calResults.clear();
        }),
        icon: Icon(Icons.tune_rounded,
            size: 15,
            color: _calMode ? AppColors.accent : AppColors.textSecondary),
        label: Text('معايرة',
            style: TextStyle(fontSize: 11,
                color: _calMode ? AppColors.accent : AppColors.textSecondary)),
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8))),
    ],
  );

  // ── Calibration widget ─────────────────────────────────────────────────────
  Widget _calWidget() {
    final steps = ['50 سم', '1 متر', '2 متر'];
    if (_calStep == 0 || _calStep > 3) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.medium.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.medium.withOpacity(0.45), width: 1)),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.straighten_rounded, color: AppColors.medium, size: 20),
          const SizedBox(width: 8),
          Text('معايرة ${_calStep}/3 — المسافة: ${steps[_calStep-1]}',
              style: const TextStyle(color: AppColors.medium,
                  fontWeight: FontWeight.w700, fontSize: 13)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surface, borderRadius: BorderRadius.circular(6)),
            child: Text('${_calBuf.length} عينة',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11))),
        ]),
        const SizedBox(height: 6),
        Text('ضع الهاتف على بعد ${steps[_calStep-1]} من الجهاز وانتظر',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity,
          child: ElevatedButton(
            onPressed: _calBuf.length >= 8 ? _calNext : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.medium, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
            child: Text(_calStep < 3 ? 'التالي ←' : 'إنهاء المعايرة ✓'))),
      ]));
  }

  // ── Danger banner ──────────────────────────────────────────────────────────
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
            color: AppColors.critical.withOpacity(0.5 + _pulseCtrl.value * 0.5),
            width: 2.0)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
              color: AppColors.critical, shape: BoxShape.circle),
          child: const Icon(Icons.warning_rounded,
              color: Colors.white, size: 22)),
        const SizedBox(width: 14),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          const Text('⚠  احذر جهاز غش بجانبك',
              style: TextStyle(color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Row(children: [
            _pill('أقل من 50 سم', const Color(0xFFFFD600)),
            const SizedBox(width: 8),
            _pill(_dev.typeLabel, Colors.white),
          ]),
        ])),
      ])));

  // ── Main zone card ─────────────────────────────────────────────────────────
  Widget _mainCard(_Zone z, Color c) {
    final trend = _prevZone.index < z.index ? '↗ اقتراب'
        : _prevZone.index > z.index ? '↘ ابتعاد'
        : '→ ثابت';
    final trendC = _prevZone.index < z.index ? AppColors.critical
        : _prevZone.index > z.index ? AppColors.safe
        : AppColors.textMuted;

    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) {
        final glow = z == _Zone.danger
            ? c.withOpacity(0.15 + _pulseCtrl.value * 0.10) : Colors.transparent;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.withOpacity(0.5),
                width: z == _Zone.danger ? 2.0 : 1.0),
            boxShadow: [BoxShadow(color: glow, blurRadius: 25, spreadRadius: 4)]),
          child: Column(children: [

            // Zone text — BIG and clear
            Text(z.rangeLabel,
                style: TextStyle(color: c, fontSize: 34,
                    fontWeight: FontWeight.w900),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),

            // Sub-label
            Text(z.labelAr,
                style: TextStyle(
                    color: c.withOpacity(0.8), fontSize: 14,
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),

            // Pulsing indicator circle
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 72 + (z == _Zone.danger ? _pulseCtrl.value * 10 : 0),
              height: 72 + (z == _Zone.danger ? _pulseCtrl.value * 10 : 0),
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: c,
                boxShadow: [BoxShadow(
                    color: c.withOpacity(0.5), blurRadius: 18)]),
              child: Icon(z.icon,
                  color: Colors.white, size: 36)),
            const SizedBox(height: 16),

            // Trend + P75 RSSI
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(trend, style: TextStyle(color: trendC,
                  fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(width: 16),
              Text('P75: ${_det.p75.toStringAsFixed(0)} dBm',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ]),
          ]),
        );
      });
  }

  // ── Signal strength meter — 5 vertical bars ────────────────────────────────
  Widget _signalMeter(Color c) {
    final bars  = _det.signalBars;
    final p75   = _det.p75;
    final z     = _det.zone;

    // Zone labels with their colors
    final zones = [
      (label: 'بعيد',    c: const Color(0xFF00E676)),
      (label: 'متوسط',   c: const Color(0xFFFFD600)),
      (label: 'قريب',    c: const Color(0xFFFF6D00)),
      (label: 'خطر',     c: const Color(0xFFFF1744)),
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 0.5)),
      child: Column(children: [

        // Title row
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('قوة الإشارة',
              style: TextStyle(color: AppColors.textMuted,
                  fontSize: 11, letterSpacing: 0.5)),
          Text('${_det.latest} dBm',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
        ]),
        const SizedBox(height: 16),

        // Big signal bars — 5 bars, left=weak, right=strong
        Row(mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(5, (i) {
            final active  = i < bars;
            final barC    = active ? _barColor(i) : AppColors.border;
            final height  = 16.0 + i * 10;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 28, height: height,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: barC,
                borderRadius: BorderRadius.circular(5),
                boxShadow: active ? [BoxShadow(
                    color: barC.withOpacity(0.5), blurRadius: 8)] : []),
            );
          })),
        const SizedBox(height: 12),

        // Zone indicator row — 4 colored boxes
        Row(children: zones.asMap().entries.map((e) {
          final i = e.key;
          final zone = e.value;
          final active = _zoneIndex(z) == i;
          return Expanded(child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? zone.c.withOpacity(0.2) : zone.c.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? zone.c.withOpacity(0.8) : zone.c.withOpacity(0.15),
                width: active ? 1.5 : 0.5)),
            child: Text(zone.label, textAlign: TextAlign.center,
                style: TextStyle(
                  color: active ? zone.c : zone.c.withOpacity(0.3),
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w400))));
        }).toList()),
      ]));
  }

  int _zoneIndex(_Zone z) => switch (z) {
    _Zone.far    => 0,
    _Zone.medium => 1,
    _Zone.near   => 2,
    _Zone.danger => 3,
  };

  Color _barColor(int i) => switch (i) {
    0 => const Color(0xFF00E676),
    1 => const Color(0xFF8AE000),
    2 => const Color(0xFFFFD600),
    3 => const Color(0xFFFF6D00),
    _ => const Color(0xFFFF1744),
  };

  // ── Device info ────────────────────────────────────────────────────────────
  Widget _deviceInfo() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5)),
    child: Row(children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: AppColors.accent.withOpacity(0.2), width: 0.5)),
        child: Center(child: Text(_dev.typeIcon,
            style: const TextStyle(fontSize: 24)))),
      const SizedBox(width: 14),
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Directionality(textDirection: TextDirection.ltr,
          child: Text(
            _dev.name.isNotEmpty ? _dev.name : 'جهاز غير معروف',
            style: const TextStyle(color: AppColors.textPrimary,
                fontWeight: FontWeight.w700, fontSize: 14),
            overflow: TextOverflow.ellipsis)),
        const SizedBox(height: 4),
        Row(children: [
          Text(_dev.typeLabel, style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(width: 8),
          _badge(_dev.protocolBadge, AppColors.accent),
          const SizedBox(width: 8),
          _badge('$_updates تحديث', AppColors.textMuted),
        ]),
      ])),
    ]));

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

  IconData get icon => switch (this) {
    _Zone.far    => Icons.bluetooth_searching,
    _Zone.medium => Icons.bluetooth,
    _Zone.near   => Icons.warning_amber_rounded,
    _Zone.danger => Icons.warning_rounded,
  };

  String get rangeLabel => switch (this) {
    _Zone.far    => 'بعيد  >  2 متر',
    _Zone.medium => '1 م  ─  2 متر',
    _Zone.near   => '50 سم  ─  1 متر',
    _Zone.danger => 'أقل من  50 سم',
  };

  String get labelAr => switch (this) {
    _Zone.far    => 'خارج النطاق الحرج',
    _Zone.medium => 'في محيط القاعة — تنبّه',
    _Zone.near   => 'قريب جداً — تدقيق فوري',
    _Zone.danger => 'خطر مباشر — جهاز غش محتمل',
  };
}
