import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../core/constants.dart';
import '../services/classic_bt_service.dart';
import '../providers/ble_scanner.dart';

// ── Zone Detector — stable, no calibration needed ────────────────────────────
// Uses a large rolling buffer + strong hysteresis to avoid zone flickering.
// Thresholds based on typical indoor BT at:
//   Danger  > -60 dBm  ≈ < 0.7m
//   Near    > -70 dBm  ≈ 0.7–1.5m
//   Medium  > -80 dBm  ≈ 1.5–3m
//   Far     ≤ -80 dBm  ≈ > 3m
class _ZoneDetector {
  static const double _dIn=-60, _dOut=-67;   // 7 dBm hysteresis gap
  static const double _nIn=-70, _nOut=-77;
  static const double _mIn=-80, _mOut=-87;

  final List<int> _buf = [];
  static const _N = 20;   // 4-second window at 5 Hz
  _Zone _state = _Zone.far;
  int _voteFor = 0;  // consecutive votes for proposed new zone
  _Zone _proposed = _Zone.far;
  static const _VOTES_NEEDED = 3; // need 3 consecutive votes to change zone

  void add(int rssi) {
    _buf.add(rssi);
    if (_buf.length > _N) _buf.removeAt(0);
    if (_buf.length >= 8) _eval();
  }

  // Use median (50th percentile) — more stable than 75th
  double get median {
    if (_buf.isEmpty) return -90;
    final s = List<int>.from(_buf)..sort();
    return s[_buf.length ~/ 2].toDouble();
  }

  int get latest => _buf.isEmpty ? -90 : _buf.last;

  void _eval() {
    final r = median;
    _Zone n;
    switch (_state) {
      case _Zone.far:    n = r >= _mIn ? _Zone.medium : _Zone.far;
      case _Zone.medium: n = r >= _nIn ? _Zone.near   : r < _mOut ? _Zone.far    : _Zone.medium;
      case _Zone.near:   n = r >= _dIn ? _Zone.danger  : r < _nOut ? _Zone.medium : _Zone.near;
      case _Zone.danger: n = r < _dOut  ? _Zone.near   : _Zone.danger;
    }

    if (n == _state) {
      _voteFor = 0;
      _proposed = _state;
    } else if (n == _proposed) {
      _voteFor++;
      if (_voteFor >= _VOTES_NEEDED) {
        _state = n;
        _voteFor = 0;
      }
    } else {
      _proposed = n;
      _voteFor = 1;
    }
  }

  _Zone get zone => _state;

  int get bars {
    final r = median;
    if (r >= _dIn) return 5;
    if (r >= _nIn) return 4;
    if (r >= _mIn) return 3;
    if (r >= -87)  return 2;
    return 1;
  }
}

// ── Screen ─────────────────────────────────────────────────────────────────────
class FindDistanceScreen extends StatefulWidget {
  final NativeDevice device;
  final BleScanner   scanner;
  const FindDistanceScreen({super.key, required this.device, required this.scanner});
  @override State<FindDistanceScreen> createState() => _S();
}

class _S extends State<FindDistanceScreen> with TickerProviderStateMixin {
  // Pulse animation for danger alert text
  late AnimationController _dangerPulse;
  // Slow background pulse for the circle glow
  late AnimationController _glowPulse;

  final _det    = _ZoneDetector();
  final _player = AudioPlayer();

  _Zone _zone = _Zone.far, _prev = _Zone.far;
  int   _updates = 0;
  bool  _alerted = false;
  Timer? _timer;

  NativeDevice get _dev =>
      widget.scanner.devices[widget.device.address.replaceAll(':', '')]
      ?? widget.device;

  bool get _approaching => _zone.index > _prev.index;
  bool get _receding    => _zone.index < _prev.index;

  @override
  void initState() {
    super.initState();
    _dangerPulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..repeat(reverse: true);
    _glowPulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);

    int tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final dev = _dev;
      if (dev.rssi == 0 || dev.rssi < -110) return;
      _det.add(dev.rssi);
      if (++tick % 5 == 0) {
        final nz = _det.zone;
        setState(() { _prev = _zone; _zone = nz; _updates = dev.updateCount; });
        if (_zone == _Zone.danger && !_alerted) {
          _alerted = true;
          HapticFeedback.heavyImpact();
          _player.play(AssetSource('beep_critical.mp3'), volume: 1.0)
              .catchError((_) {});
          Future.delayed(
              const Duration(milliseconds: 350), HapticFeedback.heavyImpact);
        } else if (_zone != _Zone.danger) {
          _alerted = false;
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dangerPulse.dispose();
    _glowPulse.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final c = _zone.color;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _appBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        child: Column(children: [

          // ── ANIMATED DANGER BANNER ──────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _zone == _Zone.danger
                ? _dangerBanner()
                : const SizedBox.shrink()),
          if (_zone == _Zone.danger) const SizedBox(height: 10),

          // ── MAIN CIRCLE CARD ─────────────────────────────────────────
          _circleCard(c),

          const SizedBox(height: 14),
          _deviceInfo(),
          const SizedBox(height: 10),
          _nearbyCounter(),
        ]),
      ),
    );
  }

  // ── App bar — NO calibration button ───────────────────────────────────────
  PreferredSizeWidget _appBar() => AppBar(
    backgroundColor: AppColors.surface,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded,
          color: AppColors.textSecondary, size: 20),
      onPressed: () => Navigator.pop(context)),
    title: Row(children: [
      Text(_dev.typeIcon, style: const TextStyle(fontSize: 18)),
      const SizedBox(width: 8),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('كشف القرب',
              style: TextStyle(color: AppColors.textPrimary,
                  fontSize: 15, fontWeight: FontWeight.w600)),

          // Pulsing status text
          AnimatedBuilder(
            animation: _dangerPulse,
            builder: (_, __) {
              final scale   = 0.88 + _dangerPulse.value * 0.22;
              final opacity = 0.5  + _dangerPulse.value * 0.5;
              final txt = _zone == _Zone.danger ? '⚠ جهاز غش في نطاق الخطر!'
                  : _zone == _Zone.near   ? '⚡ جهاز قريب — تنبّه'
                  : _zone == _Zone.medium ? '📶 جهاز في المحيط'
                  : '📡 المسح نشط';
              return Transform.scale(
                scale: scale,
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: opacity,
                  child: Text(txt,
                      style: TextStyle(color: _zone.color,
                          fontSize: 10, fontWeight: FontWeight.w700))));
            }),
        ])),
    ]),
  );

  // ── DANGER BANNER — animated pulsing ─────────────────────────────────────
  Widget _dangerBanner() => AnimatedBuilder(
    animation: _dangerPulse,
    builder: (_, __) {
      // Scale pulsing: 1.0 → 1.03 → 1.0
      final scale = 1.0 + _dangerPulse.value * 0.03;
      return Transform.scale(
        scale: scale,
        child: Container(
          key: const ValueKey('danger'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1A0000),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: AppColors.critical.withOpacity(0.5 + _dangerPulse.value * 0.5),
                width: 2.0)),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.critical.withOpacity(0.8 + _dangerPulse.value * 0.2)),
              child: const Icon(Icons.warning_rounded, color: Colors.white, size: 24)),
            const SizedBox(width: 14),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              // THE PULSING WARNING TEXT
              Text('احذر جهاز غش بجانبك',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16 + _dangerPulse.value * 2, // grows 16→18
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Row(children: [
                _pill('أقل من 50 سم', const Color(0xFFFFD600)),
                const SizedBox(width: 8),
                _pill(_dev.typeLabel, Colors.white),
              ]),
            ])),
          ]));
    });

  // ── CIRCLE CARD ───────────────────────────────────────────────────────────
  Widget _circleCard(Color c) {
    final bars = _det.bars;
    final arrowIcon  = _approaching ? Icons.arrow_upward_rounded
        : _receding  ? Icons.arrow_downward_rounded
        :               Icons.remove_rounded;
    final arrowColor = _approaching ? AppColors.critical
        : _receding  ? AppColors.safe
        :               AppColors.textMuted;
    final arrowLabel = _approaching ? 'اقتراب'
        : _receding  ? 'ابتعاد'
        :               'ثابت';

    return AnimatedBuilder(
      animation: _glowPulse,
      builder: (_, __) {
        final glow = _zone == _Zone.danger
            ? c.withOpacity(0.12 + _glowPulse.value * 0.10)
            : Colors.transparent;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            border: Border.all(
                color: c.withOpacity(0.6 + _glowPulse.value * 0.3),
                width: _zone == _Zone.danger ? 2.5 : 1.2),
            boxShadow: [BoxShadow(
                color: glow, blurRadius: 30, spreadRadius: 6)]),
          child: AspectRatio(aspectRatio: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [

                  // ── Zone title (animated switch) ─────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, anim) => SlideTransition(
                      position: Tween<Offset>(
                          begin: const Offset(0, -0.4),
                          end: Offset.zero)
                          .animate(CurvedAnimation(
                              parent: anim, curve: Curves.easeOut)),
                      child: FadeTransition(opacity: anim, child: child)),
                    child: Text(_zone.rangeLabel,
                        key: ValueKey(_zone),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: c,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            height: 1.2))),

                  // ── Short description ────────────────────────────────
                  Text(_zone.shortDesc,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: c.withOpacity(0.7),
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),

                  // ── BIG SIGNAL BARS (LTR forced) ──────────────────────
                  ClipRect(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(5, (i) {
                          final on = i < bars;
                          final bc = on ? _barColor(i) : AppColors.border;
                          final h  = 20.0 + i * 9; // 20→56px
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            width: 28, height: h,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: bc,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: on
                                  ? [BoxShadow(color: bc.withOpacity(0.5), blurRadius: 8)]
                                  : []));
                        }))),
                  ),

                  // ── Zone labels (LTR forced) ──────────────────────────
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(children: [
                      _zl('بعيد',  const Color(0xFF00E676), _zone == _Zone.far),
                      _zl('متوسط', const Color(0xFFFFD600), _zone == _Zone.medium),
                      _zl('قريب',  const Color(0xFFFF6D00), _zone == _Zone.near),
                      _zl('خطر',   const Color(0xFFFF1744), _zone == _Zone.danger),
                    ])),

                  // ── Arrow + P75 ───────────────────────────────────────
                  Row(mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 58, height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: arrowColor.withOpacity(0.12),
                        border: Border.all(
                            color: arrowColor.withOpacity(0.5), width: 1.5)),
                      child: Icon(arrowIcon, color: arrowColor, size: 34)),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min, children: [
                      Text(arrowLabel,
                          style: TextStyle(color: arrowColor,
                              fontSize: 15, fontWeight: FontWeight.w900)),
                      Text('${_det.median.toStringAsFixed(0)} dBm',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 10)),
                    ]),
                  ]),
                ]),
            )));
      });
  }

  Widget _zl(String t, Color c, bool active) => Expanded(
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(vertical: 4),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: active ? c.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: active ? c.withOpacity(0.7) : Colors.transparent)),
      child: Text(t, textAlign: TextAlign.center,
          style: TextStyle(
              color: active ? c : c.withOpacity(0.2),
              fontSize: 10,
              fontWeight: active ? FontWeight.w800 : FontWeight.w400))));

  Color _barColor(int i) => const [
    Color(0xFF00E676), Color(0xFF8AE000),
    Color(0xFFFFD600), Color(0xFFFF6D00),
    Color(0xFFFF1744),
  ][i];

  // ── Device info ───────────────────────────────────────────────────────────
  Widget _deviceInfo() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5)),
    child: Row(children: [
      Container(width: 46, height: 46,
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withOpacity(0.2))),
        child: Center(child: Text(_dev.typeIcon,
            style: const TextStyle(fontSize: 24)))),
      const SizedBox(width: 14),
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Directionality(textDirection: TextDirection.ltr,
          child: Text(_dev.name.isNotEmpty ? _dev.name : 'جهاز غير معروف',
            style: const TextStyle(color: AppColors.textPrimary,
                fontWeight: FontWeight.w700, fontSize: 14),
            overflow: TextOverflow.ellipsis)),
        const SizedBox(height: 4),
        Row(children: [
          Text(_dev.typeLabel, style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(width: 6),
          _badge(_dev.protocolBadge, AppColors.accent),
          const SizedBox(width: 6),
          _badge('$_updates تحديث', AppColors.textMuted),
          const SizedBox(width: 6),
          _badge('${_det.latest} dBm', AppColors.textMuted),
        ]),
      ])),
    ]));

  // ── Other nearby devices (< 0.5m threshold) ──────────────────────────────
  Widget _nearbyCounter() {
    final others = widget.scanner.devices.values.where((d) =>
        d.address.replaceAll(':', '') !=
            widget.device.address.replaceAll(':', '') &&
        d.rssi > -60).toList();
    if (others.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _glowPulse,
      builder: (_, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A0A00),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.critical.withOpacity(
                  0.4 + _glowPulse.value * 0.3), width: 1.5)),
        child: Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppColors.critical.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.critical.withOpacity(0.5))),
            child: Center(child: Text('${others.length}',
                style: const TextStyle(color: AppColors.critical,
                    fontSize: 18, fontWeight: FontWeight.w900)))),
          const SizedBox(width: 14),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              others.length == 1
                  ? 'جهاز غش إضافي في نطاق الخطر'
                  : '${others.length} أجهزة غش في نطاق الخطر',
              style: const TextStyle(color: AppColors.critical,
                  fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
              others.map((d) => d.name.isNotEmpty ? d.name : d.typeLabel).join(' • '),
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis),
          ])),
          const Icon(Icons.warning_amber_rounded,
              color: AppColors.critical, size: 22),
        ])));
  }

  Widget _pill(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(7),
      border: Border.all(color: c.withOpacity(0.5), width: 0.8)),
    child: Text(t, style: TextStyle(color: c,
        fontSize: 12, fontWeight: FontWeight.w700)));

  Widget _badge(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(4),
      border: Border.all(color: c.withOpacity(0.25), width: 0.4)),
    child: Text(t, style: TextStyle(color: c,
        fontSize: 9, fontWeight: FontWeight.w600)));
}

// ── Zone enum ──────────────────────────────────────────────────────────────────
enum _Zone {
  far, medium, near, danger;
  Color get color => switch (this) {
    _Zone.far    => const Color(0xFF00E676),
    _Zone.medium => const Color(0xFFFFD600),
    _Zone.near   => const Color(0xFFFF6D00),
    _Zone.danger => const Color(0xFFFF1744),
  };
  String get rangeLabel => switch (this) {
    _Zone.far    => 'بعيد > 2م',
    _Zone.medium => '1 – 2 متر',
    _Zone.near   => '50سم – 1م',
    _Zone.danger => 'قوة إشارة القرب\nمن جهاز الغش',
  };
  String get shortDesc => switch (this) {
    _Zone.far    => 'خارج النطاق الحرج',
    _Zone.medium => 'في محيط القاعة',
    _Zone.near   => 'تدقيق فوري',
    _Zone.danger => 'خطر مباشر',
  };
}
