import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../core/constants.dart';
import '../services/classic_bt_service.dart';
import '../providers/ble_scanner.dart';

// ── Zone Detector ──────────────────────────────────────────────────────────────
class _ZoneDetector {
  double _dIn=-57, _dOut=-63, _nIn=-67, _nOut=-73, _mIn=-77, _mOut=-83;
  final List<int> _buf = [];
  static const _N = 15;
  _Zone _state = _Zone.far;
  int _changes = 0;

  void add(int rssi) {
    _buf.add(rssi);
    if (_buf.length > _N) _buf.removeAt(0);
    if (_buf.length >= 5) _eval();
  }

  double get p75 {
    if (_buf.isEmpty) return -90;
    final s = List<int>.from(_buf)..sort((a,b)=>b.compareTo(a));
    return s[(_buf.length*0.25).round().clamp(0,_buf.length-1)].toDouble();
  }
  int get latest => _buf.isEmpty ? -90 : _buf.last;

  void _eval() {
    final r = p75;
    _Zone next;
    switch (_state) {
      case _Zone.far:    next = r>=_mIn ? _Zone.medium : _Zone.far;
      case _Zone.medium: next = r>=_nIn ? _Zone.near : r<_mOut ? _Zone.far   : _Zone.medium;
      case _Zone.near:   next = r>=_dIn ? _Zone.danger: r<_nOut ? _Zone.medium: _Zone.near;
      case _Zone.danger: next = r<_dOut  ? _Zone.near  : _Zone.danger;
    }
    if (next != _state) {
      if (++_changes >= 2) { _state = next; _changes = 0; }
    } else { _changes = 0; }
  }

  _Zone get zone => _state;

  // 1-5 bars based on P75
  int get bars {
    final r = p75;
    if (r >= _dIn)  return 5;
    if (r >= _nIn)  return 4;
    if (r >= _mIn)  return 3;
    if (r >= -82)   return 2;
    return 1;
  }

  void calibrate(double r05, double r1, double r2) {
    _dIn=r05-3; _dOut=r05-9;
    _nIn=r1-3;  _nOut=r1-9;
    _mIn=r2-3;  _mOut=r2-9;
  }
}

// ── Screen ─────────────────────────────────────────────────────────────────────
class FindDistanceScreen extends StatefulWidget {
  final NativeDevice device;
  final BleScanner   scanner;
  const FindDistanceScreen({super.key, required this.device, required this.scanner});
  @override State<FindDistanceScreen> createState() => _State();
}

class _State extends State<FindDistanceScreen> with TickerProviderStateMixin {
  late AnimationController _pulse;
  final _det = _ZoneDetector();
  final _player = AudioPlayer();

  _Zone _zone     = _Zone.far;
  _Zone _prevZone = _Zone.far;   // REAL previous zone (updated after trend computed)
  int   _updates  = 0;
  bool  _alerted  = false;
  Timer? _timer;

  // Calibration
  bool   _calMode = false;
  int    _calStep = 0;
  List<int>    _calBuf = [];
  List<double> _calRes = [];

  NativeDevice get _dev =>
      widget.scanner.devices[widget.device.address.replaceAll(':','')] ?? widget.device;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync:this, duration:const Duration(milliseconds:600))
      ..repeat(reverse:true);

    int tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds:200), (_) {
      if (!mounted) return;
      final dev = _dev;
      if (dev.rssi == 0 || dev.rssi < -110) return;
      _det.add(dev.rssi);
      if (_calMode && _calStep > 0) _calBuf.add(dev.rssi);
      if (++tick % 5 == 0) {
        final newZone = _det.zone;
        setState(() {
          _prevZone = _zone;   // save BEFORE updating
          _zone     = newZone;
          _updates  = dev.updateCount;
        });
        if (_zone == _Zone.danger && !_alerted) {
          _alerted = true;
          HapticFeedback.heavyImpact();
          _player.play(AssetSource('beep_critical.mp3'), volume:1.0).catchError((_){});
          Future.delayed(const Duration(milliseconds:350), () => HapticFeedback.heavyImpact());
        } else if (_zone != _Zone.danger) {
          _alerted = false;
        }
      }
    });
  }

  @override void dispose() { _timer?.cancel(); _pulse.dispose(); _player.dispose(); super.dispose(); }

  void _calNext() {
    if (_calBuf.length < 8) return;
    _calRes.add(_calBuf.reduce((a,b)=>a+b) / _calBuf.length);
    _calBuf.clear();
    if (_calStep == 3) {
      _det.calibrate(_calRes[0], _calRes[1], _calRes[2]);
      setState(() { _calMode=false; _calStep=0; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تمت المعايرة ✓')));
    } else {
      setState(() => _calStep++);
    }
  }

  // ── Arrow direction ─────────────────────────────────────────────────────────
  // true approach = zone index increased (far→danger)
  bool get _approaching => _zone.index > _prevZone.index;
  bool get _receding    => _zone.index < _prevZone.index;

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _appBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        child: Column(children: [

          if (_calMode) ...[_calWidget(), const SizedBox(height:12)],

          // DANGER BANNER
          AnimatedSwitcher(
            duration: const Duration(milliseconds:250),
            child: _zone == _Zone.danger ? _dangerBanner() : const SizedBox.shrink()),
          if (_zone == _Zone.danger) const SizedBox(height:10),

          // ── MAIN UNIFIED CARD ──────────────────────────────────────────────
          _mainUnifiedCard(),

          const SizedBox(height: 14),
          _deviceInfo(),
        ]),
      ),
    );
  }

  // ── App bar ────────────────────────────────────────────────────────────────
  PreferredSizeWidget _appBar() => AppBar(
    backgroundColor: AppColors.surface,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded, color:AppColors.textSecondary, size:20),
      onPressed: () => Navigator.pop(context)),
    title: Row(children: [
      Text(_dev.typeIcon, style:const TextStyle(fontSize:18)),
      const SizedBox(width:8),
      const Expanded(child: Text('كشف القرب',
          style:TextStyle(color:AppColors.textPrimary, fontSize:15, fontWeight:FontWeight.w600))),
    ]),
    actions: [
      TextButton.icon(
        onPressed: () => setState(() {
          _calMode=!_calMode; _calStep=_calMode?1:0; _calBuf.clear(); _calRes.clear();
        }),
        icon: Icon(Icons.tune_rounded, size:15,
            color: _calMode ? AppColors.accent : AppColors.textSecondary),
        label: Text('معايرة', style:TextStyle(fontSize:11,
            color: _calMode ? AppColors.accent : AppColors.textSecondary)),
        style: TextButton.styleFrom(padding:const EdgeInsets.symmetric(horizontal:8))),
    ],
  );

  // ── Calibration wizard ──────────────────────────────────────────────────────
  Widget _calWidget() {
    if (_calStep==0 || _calStep>3) return const SizedBox.shrink();
    const steps = ['50 سم', '1 متر', '2 متر'];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.medium.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color:AppColors.medium.withOpacity(0.45))),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.straighten_rounded, color:AppColors.medium, size:20),
          const SizedBox(width:8),
          Text('معايرة ${_calStep}/3 — ${steps[_calStep-1]}',
              style:const TextStyle(color:AppColors.medium, fontWeight:FontWeight.w700, fontSize:13)),
          const Spacer(),
          Text('${_calBuf.length} عينة',
              style:const TextStyle(color:AppColors.textMuted, fontSize:11)),
        ]),
        const SizedBox(height:8),
        Text('ضع الهاتف على بعد ${steps[_calStep-1]} ثم اضغط التالي',
            style:const TextStyle(color:AppColors.textSecondary, fontSize:12)),
        const SizedBox(height:10),
        SizedBox(width:double.infinity,
          child: ElevatedButton(
            onPressed: _calBuf.length>=8 ? _calNext : null,
            style: ElevatedButton.styleFrom(
              backgroundColor:AppColors.medium, foregroundColor:Colors.white,
              shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10))),
            child: Text(_calStep<3 ? 'التالي ←' : 'إنهاء ✓'))),
      ]));
  }

  // ── Danger banner ───────────────────────────────────────────────────────────
  Widget _dangerBanner() => AnimatedBuilder(
    animation: _pulse,
    builder: (_, __) => Container(
      key: const ValueKey('d'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal:16, vertical:14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A0000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.critical.withOpacity(0.5 + _pulse.value*0.5), width:2.0)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(color:AppColors.critical, shape:BoxShape.circle),
          child: const Icon(Icons.warning_rounded, color:Colors.white, size:22)),
        const SizedBox(width:14),
        Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
          const Text('⚠  احذر جهاز غش بجانبك',
              style:TextStyle(color:Colors.white, fontSize:17, fontWeight:FontWeight.w900)),
          const SizedBox(height:6),
          Row(children: [
            _pill('أقل من 50 سم', const Color(0xFFFFD600)),
            const SizedBox(width:8),
            _pill(_dev.typeLabel, Colors.white),
          ]),
        ])),
      ])));

  // ══════════════════════════════════════════════════════════════════════════════
  // MAIN UNIFIED CARD — bars LEFT, text + arrow RIGHT — all update together
  // ══════════════════════════════════════════════════════════════════════════════
  Widget _mainUnifiedCard() {
    final c    = _zone.color;
    final bars = _det.bars;

    // Arrow
    final arrow = _approaching ? Icons.arrow_upward_rounded
        : _receding          ? Icons.arrow_downward_rounded
        :                      Icons.radio_button_unchecked;
    final arrowC = _approaching ? AppColors.critical
        : _receding          ? AppColors.safe
        :                      AppColors.textMuted;
    final arrowLabel = _approaching ? 'اقتراب'
        : _receding          ? 'ابتعاد'
        :                      'ثابت';

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final glow = _zone == _Zone.danger
            ? c.withOpacity(0.12 + _pulse.value*0.08) : Colors.transparent;
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.withOpacity(0.5),
                width: _zone==_Zone.danger ? 2.0 : 1.0),
            boxShadow: [BoxShadow(color:glow, blurRadius:22, spreadRadius:3)]),
          child: Column(children: [

            // ── ROW 1: 5 signal bars (left) + zone text + arrow (right) ────────
            Row(crossAxisAlignment:CrossAxisAlignment.end, children: [

              // ── 5 bars with zone labels underneath ──────────────────────────
              Expanded(
                flex: 5,
                child: Column(children: [
                  // Bars
                  Row(crossAxisAlignment:CrossAxisAlignment.end,
                    mainAxisAlignment:MainAxisAlignment.start,
                    children: List.generate(5, (i) {
                      final active = i < bars;
                      final bc     = active ? _barColor(i) : AppColors.border;
                      final h      = 22.0 + i * 11;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds:300),
                        width: 34, height: h,
                        margin: const EdgeInsets.only(right:5),
                        decoration: BoxDecoration(
                          color: bc,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: active
                              ? [BoxShadow(color:bc.withOpacity(0.5), blurRadius:8)]
                              : []));
                    })),
                  const SizedBox(height:8),
                  // Zone labels under bars (4 zones mapped to 5 bars)
                  Row(children: [
                    _zoneLabel('بعيد',   const Color(0xFF00E676), _zone==_Zone.far),
                    _zoneLabel('متوسط',  const Color(0xFFFFD600), _zone==_Zone.medium),
                    _zoneLabel('قريب',   const Color(0xFFFF6D00), _zone==_Zone.near),
                    _zoneLabel('خطر',    const Color(0xFFFF1744), _zone==_Zone.danger),
                  ]),
                ])),

              const SizedBox(width: 16),

              // ── Zone text (right side) — floats alongside bars ───────────────
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                  // Big zone text — updates with bars
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds:300),
                    child: Text(_zone.rangeLabel,
                        key: ValueKey(_zone),
                        textAlign: TextAlign.center,
                        style: TextStyle(color:c, fontSize:20,
                            fontWeight:FontWeight.w900))),
                  const SizedBox(height:6),
                  Text(_zone.shortDesc,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: c.withOpacity(0.75), fontSize:11,
                          fontWeight:FontWeight.w600)),
                  const SizedBox(height:14),
                  // BIG ARROW — always visible
                  AnimatedContainer(
                    duration: const Duration(milliseconds:300),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: arrowC.withOpacity(0.1),
                      border: Border.all(
                          color: arrowC.withOpacity(0.4), width:1.2)),
                    child: Icon(arrow, color:arrowC, size:36)),
                  const SizedBox(height:6),
                  Text(arrowLabel,
                      style: TextStyle(color:arrowC, fontSize:12,
                          fontWeight:FontWeight.w700)),
                ])),
            ]),

            const SizedBox(height:14),
            const Divider(color: Color(0xFF1E3050), height:1),
            const SizedBox(height:10),

            // ── ROW 2: RSSI values ───────────────────────────────────────────
            Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly, children: [
              _stat('RSSI', '${_det.latest} dBm', AppColors.textSecondary),
              _stat('P75',  '${_det.p75.toStringAsFixed(0)} dBm', c),
              _stat('تحديثات', '$_updates', AppColors.textMuted),
            ]),
          ]),
        );
      });
  }

  Widget _zoneLabel(String t, Color c, bool active) => Expanded(
    child: AnimatedContainer(
      duration: const Duration(milliseconds:250),
      padding: const EdgeInsets.symmetric(vertical:4),
      margin: const EdgeInsets.only(right:3),
      decoration: BoxDecoration(
        color: active ? c.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: active ? c.withOpacity(0.7) : Colors.transparent,
            width: active ? 1.0 : 0)),
      child: Text(t, textAlign:TextAlign.center,
          style: TextStyle(
            color: active ? c : c.withOpacity(0.3),
            fontSize: 9,
            fontWeight: active ? FontWeight.w800 : FontWeight.w400))));

  Widget _stat(String label, String value, Color c) => Column(children: [
    Text(label, style: const TextStyle(color:AppColors.textMuted, fontSize:9)),
    const SizedBox(height:3),
    Text(value, style: TextStyle(color:c, fontSize:13, fontWeight:FontWeight.w700)),
  ]);

  Color _barColor(int i) => [
    const Color(0xFF00E676), const Color(0xFF8AE000),
    const Color(0xFFFFD600), const Color(0xFFFF6D00),
    const Color(0xFFFF1744),
  ][i];

  // ── Device info ─────────────────────────────────────────────────────────────
  Widget _deviceInfo() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color:AppColors.card,
      borderRadius:BorderRadius.circular(14),
      border: Border.all(color:AppColors.border, width:0.5)),
    child: Row(children: [
      Container(width:46, height:46,
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color:AppColors.accent.withOpacity(0.2))),
        child: Center(child: Text(_dev.typeIcon,
            style:const TextStyle(fontSize:24)))),
      const SizedBox(width:14),
      Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start,
        children: [
        Directionality(textDirection:TextDirection.ltr,
          child: Text(_dev.name.isNotEmpty ? _dev.name : 'جهاز غير معروف',
            style:const TextStyle(color:AppColors.textPrimary,
                fontWeight:FontWeight.w700, fontSize:14),
            overflow:TextOverflow.ellipsis)),
        const SizedBox(height:4),
        Row(children: [
          Text(_dev.typeLabel,
              style:const TextStyle(color:AppColors.textSecondary, fontSize:11)),
          const SizedBox(width:8),
          _badge(_dev.protocolBadge, AppColors.accent),
        ]),
      ])),
    ]));

  Widget _pill(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal:10, vertical:4),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12), borderRadius:BorderRadius.circular(7),
      border:Border.all(color:c.withOpacity(0.5), width:0.8)),
    child: Text(t, style:TextStyle(color:c, fontSize:12, fontWeight:FontWeight.w700)));

  Widget _badge(String t, Color c) => Container(
    padding:const EdgeInsets.symmetric(horizontal:6, vertical:1),
    decoration:BoxDecoration(
      color:c.withOpacity(0.1), borderRadius:BorderRadius.circular(4),
      border:Border.all(color:c.withOpacity(0.25), width:0.4)),
    child:Text(t, style:TextStyle(color:c, fontSize:9, fontWeight:FontWeight.w600)));
}

// ── Zone enum ──────────────────────────────────────────────────────────────────
enum _Zone {
  far, medium, near, danger;

  Color get color => switch(this) {
    _Zone.far    => const Color(0xFF00E676),
    _Zone.medium => const Color(0xFFFFD600),
    _Zone.near   => const Color(0xFFFF6D00),
    _Zone.danger => const Color(0xFFFF1744),
  };

  String get rangeLabel => switch(this) {
    _Zone.far    => 'بعيد\n> 2 متر',
    _Zone.medium => '1 – 2 متر',
    _Zone.near   => '50سم – 1م',
    _Zone.danger => 'أقل من\n50 سم',
  };

  String get shortDesc => switch(this) {
    _Zone.far    => 'خارج النطاق',
    _Zone.medium => 'في المحيط',
    _Zone.near   => 'تدقيق فوري',
    _Zone.danger => 'خطر مباشر',
  };
}
