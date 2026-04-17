import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../core/constants.dart';
import '../services/classic_bt_service.dart';
import '../providers/ble_scanner.dart';

// ── Zone Detector ──────────────────────────────────────────────────────────────
class _ZoneDetector {
  double _dIn=-57,_dOut=-63,_nIn=-67,_nOut=-73,_mIn=-77,_mOut=-83;
  final List<int> _buf = [];
  static const _N = 15;
  _Zone _state = _Zone.far;
  int _ch = 0;

  void add(int rssi) {
    _buf.add(rssi); if (_buf.length > _N) _buf.removeAt(0);
    if (_buf.length >= 5) _eval();
  }

  double get p75 {
    if (_buf.isEmpty) return -90;
    final s = List<int>.from(_buf)..sort((a,b)=>b.compareTo(a));
    return s[(_buf.length*0.25).round().clamp(0,_buf.length-1)].toDouble();
  }
  int get latest => _buf.isEmpty ? -90 : _buf.last;

  void _eval() {
    final r = p75; _Zone n;
    switch (_state) {
      case _Zone.far:    n = r>=_mIn?_Zone.medium:_Zone.far;
      case _Zone.medium: n = r>=_nIn?_Zone.near:r<_mOut?_Zone.far:_Zone.medium;
      case _Zone.near:   n = r>=_dIn?_Zone.danger:r<_nOut?_Zone.medium:_Zone.near;
      case _Zone.danger: n = r<_dOut?_Zone.near:_Zone.danger;
    }
    if (n!=_state) { if(++_ch>=2){_state=n;_ch=0;} } else _ch=0;
  }

  _Zone get zone => _state;
  int get bars {
    final r=p75;
    if(r>=_dIn) return 5; if(r>=_nIn) return 4;
    if(r>=_mIn) return 3; if(r>=-82) return 2; return 1;
  }
  void calibrate(double r05,double r1,double r2) {
    _dIn=r05-3;_dOut=r05-9;_nIn=r1-3;_nOut=r1-9;_mIn=r2-3;_mOut=r2-9;
  }
}

// ── Screen ─────────────────────────────────────────────────────────────────────
class FindDistanceScreen extends StatefulWidget {
  final NativeDevice device;
  final BleScanner   scanner;
  const FindDistanceScreen({super.key,required this.device,required this.scanner});
  @override State<FindDistanceScreen> createState()=>_S();
}

class _S extends State<FindDistanceScreen> with TickerProviderStateMixin {
  late AnimationController _pulse;
  late AnimationController _textSlide;  // for animated text
  final _det=_ZoneDetector();
  final _player=AudioPlayer();

  _Zone _zone=_Zone.far, _prev=_Zone.far;
  int _updates=0;
  bool _alerted=false;
  Timer? _timer;
  bool _calMode=false; int _calStep=0;
  List<int> _calBuf=[]; List<double> _calRes=[];

  NativeDevice get _dev =>
      widget.scanner.devices[widget.device.address.replaceAll(':','')]??widget.device;

  bool get _approaching => _zone.index > _prev.index;
  bool get _receding    => _zone.index < _prev.index;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync:this,duration:const Duration(milliseconds:600))
      ..repeat(reverse:true);
    _textSlide = AnimationController(vsync:this,duration:const Duration(milliseconds:500));

    int tick=0;
    _timer=Timer.periodic(const Duration(milliseconds:200),(_) {
      if(!mounted) return;
      final dev=_dev;
      if(dev.rssi==0||dev.rssi<-110) return;
      _det.add(dev.rssi);
      if(_calMode&&_calStep>0) _calBuf.add(dev.rssi);
      if(++tick%5==0) {
        final nz=_det.zone;
        if(nz!=_zone) {
          // Trigger text animation on zone change
          _textSlide.forward(from:0).then((_)=>_textSlide.reverse());
        }
        setState((){_prev=_zone; _zone=nz; _updates=dev.updateCount;});
        if(_zone==_Zone.danger&&!_alerted) {
          _alerted=true;
          HapticFeedback.heavyImpact();
          _player.play(AssetSource('beep_critical.mp3'),volume:1.0).catchError((_){});
          Future.delayed(const Duration(milliseconds:350),()=>HapticFeedback.heavyImpact());
        } else if(_zone!=_Zone.danger) _alerted=false;
      }
    });
  }

  @override void dispose() {
    _timer?.cancel(); _pulse.dispose(); _textSlide.dispose(); _player.dispose();
    super.dispose();
  }

  void _calNext() {
    if(_calBuf.length<8) return;
    _calRes.add(_calBuf.reduce((a,b)=>a+b)/_calBuf.length);
    _calBuf.clear();
    if(_calStep==3) {
      _det.calibrate(_calRes[0],_calRes[1],_calRes[2]);
      setState((){_calMode=false;_calStep=0;});
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content:Text('تمت المعايرة ✓')));
    } else { setState(()=>_calStep++); }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _bar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16,10,16,30),
        child: Column(children:[
          if(_calMode)...[_calWidget(),const SizedBox(height:12)],
          AnimatedSwitcher(
            duration:const Duration(milliseconds:250),
            child:_zone==_Zone.danger?_dangerBanner():const SizedBox.shrink()),
          if(_zone==_Zone.danger) const SizedBox(height:10),
          _circleCard(),
          const SizedBox(height:14),
          _deviceInfo(),
          const SizedBox(height:10),
          // ── Other nearby devices counter ──────────────────────────────
          _nearbyCounter(),
        ]),
      ),
    );
  }

  PreferredSizeWidget _bar() => AppBar(
    backgroundColor:AppColors.surface,
    leading:IconButton(
      icon:const Icon(Icons.arrow_back_ios_rounded,color:AppColors.textSecondary,size:20),
      onPressed:()=>Navigator.pop(context)),
    title:Row(children:[
      Text(_dev.typeIcon,style:const TextStyle(fontSize:18)),
      const SizedBox(width:8),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('كشف القرب',
              style:TextStyle(color:AppColors.textPrimary,
                  fontSize:15,fontWeight:FontWeight.w600)),
          // Animated pulsing subtitle
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) {
              final scale = 0.85 + _pulse.value * 0.25;
              final opacity = 0.5 + _pulse.value * 0.5;
              return Transform.scale(
                scale: scale,
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: opacity,
                  child: Text(
                    _zone == _Zone.danger
                        ? '⚠ جهاز غش في نطاق الخطر!'
                        : _zone == _Zone.near
                            ? '⚡ جهاز قريب — تنبّه'
                            : '📡 المسح نشط',
                    style: TextStyle(
                        color: _zone.color,
                        fontSize: 10,
                        fontWeight: FontWeight.w700),
                  )));
            }),
        ])),
    ]),
    actions:[
      TextButton.icon(
        onPressed:()=>setState((){
          _calMode=!_calMode;_calStep=_calMode?1:0;_calBuf.clear();_calRes.clear();
        }),
        icon:Icon(Icons.tune_rounded,size:15,
            color:_calMode?AppColors.accent:AppColors.textSecondary),
        label:Text('معايرة',style:TextStyle(fontSize:11,
            color:_calMode?AppColors.accent:AppColors.textSecondary)),
        style:TextButton.styleFrom(padding:const EdgeInsets.symmetric(horizontal:8))),
    ]);

  Widget _calWidget() {
    if(_calStep==0||_calStep>3) return const SizedBox.shrink();
    const steps=['50 سم','1 متر','2 متر'];
    return Container(
      padding:const EdgeInsets.all(14),
      decoration:BoxDecoration(
        color:AppColors.medium.withOpacity(0.08),
        borderRadius:BorderRadius.circular(14),
        border:Border.all(color:AppColors.medium.withOpacity(0.45))),
      child:Column(children:[
        Row(children:[
          const Icon(Icons.straighten_rounded,color:AppColors.medium,size:20),
          const SizedBox(width:8),
          Text('معايرة $_calStep/3 — ${steps[_calStep-1]}',
              style:const TextStyle(color:AppColors.medium,fontWeight:FontWeight.w700,fontSize:13)),
          const Spacer(),
          Text('${_calBuf.length} عينة',
              style:const TextStyle(color:AppColors.textMuted,fontSize:11)),
        ]),
        const SizedBox(height:8),
        Text('ضع الهاتف على بعد ${steps[_calStep-1]} ثم اضغط التالي',
            style:const TextStyle(color:AppColors.textSecondary,fontSize:12)),
        const SizedBox(height:10),
        SizedBox(width:double.infinity,
          child:ElevatedButton(
            onPressed:_calBuf.length>=8?_calNext:null,
            style:ElevatedButton.styleFrom(
              backgroundColor:AppColors.medium,foregroundColor:Colors.white,
              shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10))),
            child:Text(_calStep<3?'التالي ←':'إنهاء ✓'))),
      ]));
  }

  Widget _dangerBanner() => AnimatedBuilder(
    animation:_pulse,
    builder:(_,__)=>Container(
      key:const ValueKey('d'),
      width:double.infinity,
      padding:const EdgeInsets.symmetric(horizontal:16,vertical:14),
      decoration:BoxDecoration(
        color:const Color(0xFF1A0000),
        borderRadius:BorderRadius.circular(14),
        border:Border.all(
            color:AppColors.critical.withOpacity(0.5+_pulse.value*0.5),width:2.0)),
      child:Row(children:[
        Container(
          padding:const EdgeInsets.all(10),
          decoration:const BoxDecoration(color:AppColors.critical,shape:BoxShape.circle),
          child:const Icon(Icons.warning_rounded,color:Colors.white,size:22)),
        const SizedBox(width:14),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('⚠  احذر جهاز غش بجانبك',
              style:TextStyle(color:Colors.white,fontSize:17,fontWeight:FontWeight.w900)),
          const SizedBox(height:6),
          Row(children:[
            _pill('أقل من 50 سم',const Color(0xFFFFD600)),
            const SizedBox(width:8),
            _pill(_dev.typeLabel,Colors.white),
          ]),
        ])),
      ])));

  // ══════════════════════════════════════════════════════════════════════════════
  // CIRCLE CARD — big circle with animated text + bars at bottom
  // ══════════════════════════════════════════════════════════════════════════════
  Widget _circleCard() {
    final c    = _zone.color;
    final bars = _det.bars;

    final arrowIcon  = _approaching ? Icons.arrow_upward_rounded
        : _receding  ? Icons.arrow_downward_rounded
        :               Icons.remove_rounded;
    final arrowColor = _approaching ? AppColors.critical
        : _receding  ? AppColors.safe
        :               AppColors.textMuted;
    final arrowLabel = _approaching ? 'اقتراب' : _receding ? 'ابتعاد' : 'ثابت';

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_,__) {
        final glow = _zone==_Zone.danger
            ? c.withOpacity(0.15+_pulse.value*0.1) : Colors.transparent;

        return Container(
          decoration:BoxDecoration(
            color:AppColors.surface,
            shape:BoxShape.circle,
            border:Border.all(color:c.withOpacity(0.6),
                width:_zone==_Zone.danger?2.5:1.2),
            boxShadow:[BoxShadow(color:glow,blurRadius:30,spreadRadius:6)]),
          child:AspectRatio(aspectRatio:1,
            child:Padding(
              padding:const EdgeInsets.all(20),
              child:Column(
                mainAxisAlignment:MainAxisAlignment.center,
                children:[

                  // ── Animated sliding zone text ───────────────────────────
                  SizedBox(height:76,
                    child:SlideTransition(
                      position: Tween<Offset>(
                        begin:const Offset(0,0.3), end:Offset.zero)
                          .animate(CurvedAnimation(
                              parent:_textSlide, curve:Curves.easeOut)),
                      child:FadeTransition(
                        opacity:Tween<double>(begin:0.4,end:1.0)
                            .animate(_textSlide),
                        child:Column(
                          mainAxisAlignment:MainAxisAlignment.center,
                          children:[
                          AnimatedSwitcher(
                            duration:const Duration(milliseconds:400),
                            transitionBuilder:(child,anim)=>SlideTransition(
                              position:Tween<Offset>(
                                begin:const Offset(0,-0.5),end:Offset.zero)
                                  .animate(CurvedAnimation(
                                      parent:anim,curve:Curves.easeOut)),
                              child:FadeTransition(opacity:anim,child:child)),
                            child:Text(_zone.rangeLabel,
                              key:ValueKey(_zone),
                              textAlign:TextAlign.center,
                              style:TextStyle(
                                color:c, fontSize:18,
                                fontWeight:FontWeight.w900, height:1.2))),
                          const SizedBox(height:6),
                          AnimatedSwitcher(
                            duration:const Duration(milliseconds:400),
                            child:Text(_zone.shortDesc,
                              key:ValueKey('d${_zone}'),
                              textAlign:TextAlign.center,
                              style:TextStyle(
                                color:c.withOpacity(0.75),fontSize:12,
                                fontWeight:FontWeight.w600))),
                        ]))),
                  ),

                  const SizedBox(height:8),

                  // ── Signal bars — LTR forced, fit inside circle ─────────
                  ClipRect(  // prevents overflow rendering
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(5, (i) {
                          final on = i < bars;
                          final bc = on ? _barColor(i) : AppColors.border;
                          final h  = 18.0 + i * 9;  // 18→54px — fits circle
                          return AnimatedContainer(
                            duration: const Duration(milliseconds:300),
                            width: 28, height: h,
                            margin: const EdgeInsets.symmetric(horizontal:4),
                            decoration: BoxDecoration(
                              color: bc,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: on ? [BoxShadow(
                                  color: bc.withOpacity(0.6), blurRadius:7)] : []));
                        })))),

                  const SizedBox(height:10),

                  // ── Zone labels — LTR matches bars order ──────────────────
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(children: [
                      _zl('بعيد',  const Color(0xFF00E676), _zone==_Zone.far),
                      _zl('متوسط', const Color(0xFFFFD600), _zone==_Zone.medium),
                      _zl('قريب',  const Color(0xFFFF6D00), _zone==_Zone.near),
                      _zl('خطر',   const Color(0xFFFF1744), _zone==_Zone.danger),
                    ])),

                  const SizedBox(height:14),

                  // ── BIG CLEAR ARROW ──────────────────────────────────────
                  Row(mainAxisAlignment:MainAxisAlignment.center,children:[
                    AnimatedContainer(
                      duration:const Duration(milliseconds:300),
                      width:64, height:64,
                      decoration:BoxDecoration(
                        shape:BoxShape.circle,
                        color:arrowColor.withOpacity(0.12),
                        border:Border.all(
                            color:arrowColor.withOpacity(0.5),width:1.5)),
                      child:Icon(arrowIcon,color:arrowColor,size:38)),
                    const SizedBox(width:12),
                    Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(arrowLabel,
                          style:TextStyle(color:arrowColor,fontSize:16,
                              fontWeight:FontWeight.w900)),
                      Text('P75: ${_det.p75.toStringAsFixed(0)} dBm',
                          style:const TextStyle(
                              color:AppColors.textMuted,fontSize:10)),
                    ]),
                  ]),

                ]),
            )));
      });
  }

  // ── Zone label pill ─────────────────────────────────────────────────────────
  Widget _zl(String t,Color c,bool active) => Expanded(
    child:AnimatedContainer(
      duration:const Duration(milliseconds:250),
      padding:const EdgeInsets.symmetric(vertical:4),
      margin:const EdgeInsets.symmetric(horizontal:2),
      decoration:BoxDecoration(
        color:active?c.withOpacity(0.15):Colors.transparent,
        borderRadius:BorderRadius.circular(6),
        border:Border.all(
            color:active?c.withOpacity(0.7):Colors.transparent,
            width:active?1.0:0)),
      child:Text(t,textAlign:TextAlign.center,
          style:TextStyle(
            color:active?c:c.withOpacity(0.25),
            fontSize:10,
            fontWeight:active?FontWeight.w800:FontWeight.w400))));

  Color _barColor(int i) => [
    const Color(0xFF00E676),const Color(0xFF8AE000),
    const Color(0xFFFFD600),const Color(0xFFFF6D00),
    const Color(0xFFFF1744),
  ][i];

  // ── Device info ─────────────────────────────────────────────────────────────
  Widget _deviceInfo() => Container(
    padding:const EdgeInsets.all(14),
    decoration:BoxDecoration(color:AppColors.card,
      borderRadius:BorderRadius.circular(14),
      border:Border.all(color:AppColors.border,width:0.5)),
    child:Row(children:[
      Container(width:46,height:46,
        decoration:BoxDecoration(
          color:AppColors.accent.withOpacity(0.08),
          borderRadius:BorderRadius.circular(12),
          border:Border.all(color:AppColors.accent.withOpacity(0.2))),
        child:Center(child:Text(_dev.typeIcon,
            style:const TextStyle(fontSize:24)))),
      const SizedBox(width:14),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Directionality(textDirection:TextDirection.ltr,
          child:Text(_dev.name.isNotEmpty?_dev.name:'جهاز غير معروف',
            style:const TextStyle(color:AppColors.textPrimary,
                fontWeight:FontWeight.w700,fontSize:14),
            overflow:TextOverflow.ellipsis)),
        const SizedBox(height:4),
        Row(children:[
          Text(_dev.typeLabel,
              style:const TextStyle(color:AppColors.textSecondary,fontSize:11)),
          const SizedBox(width:8),
          _badge(_dev.protocolBadge,AppColors.accent),
          const SizedBox(width:6),
          _badge('$_updates تحديث',AppColors.textMuted),
          const SizedBox(width:6),
          _badge('${_det.latest} dBm',AppColors.textMuted),
        ]),
      ])),
    ]));

  Widget _nearbyCounter() {
    // Count all devices in scanner that are in danger zone (< ~0.5m)
    final dangerDevices = widget.scanner.devices.values
        .where((d) => d.address.replaceAll(':','') !=
            widget.device.address.replaceAll(':',''))
        .where((d) {
          // Rough estimate: RSSI > -57 dBm ≈ < 0.5m (same threshold as _ZoneDetector)
          return d.rssi > -57;
        }).toList();
    final count = dangerDevices.length;
    if (count == 0) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal:16, vertical:14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A0A00),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.critical.withOpacity(0.4 + _pulse.value * 0.3),
              width: 1.5)),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppColors.critical.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.critical.withOpacity(0.5))),
            child: Center(child: Text('$count',
                style: const TextStyle(color: AppColors.critical,
                    fontSize: 18, fontWeight: FontWeight.w900)))),
          const SizedBox(width: 14),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              count == 1
                  ? 'جهاز غش إضافي في نطاق الخطر'
                  : '$count أجهزة غش في نطاق الخطر',
              style: const TextStyle(color: AppColors.critical,
                  fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
              dangerDevices.map((d) =>
                d.name.isNotEmpty ? d.name : d.typeLabel).join(' • '),
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis),
          ])),
          // Warning icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.critical,
              shape: BoxShape.circle),
            child: const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 18)),
        ])));
  }

  Widget _pill(String t,Color c)=>Container(
    padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),
    decoration:BoxDecoration(
      color:c.withOpacity(0.12),borderRadius:BorderRadius.circular(7),
      border:Border.all(color:c.withOpacity(0.5),width:0.8)),
    child:Text(t,style:TextStyle(color:c,fontSize:12,fontWeight:FontWeight.w700)));

  Widget _badge(String t,Color c)=>Container(
    padding:const EdgeInsets.symmetric(horizontal:6,vertical:1),
    decoration:BoxDecoration(
      color:c.withOpacity(0.1),borderRadius:BorderRadius.circular(4),
      border:Border.all(color:c.withOpacity(0.25),width:0.4)),
    child:Text(t,style:TextStyle(color:c,fontSize:9,fontWeight:FontWeight.w600)));
}

// ── Zone enum ──────────────────────────────────────────────────────────────────
enum _Zone {
  far,medium,near,danger;
  Color get color=>switch(this){
    _Zone.far=>const Color(0xFF00E676),_Zone.medium=>const Color(0xFFFFD600),
    _Zone.near=>const Color(0xFFFF6D00),_Zone.danger=>const Color(0xFFFF1744),
  };
  String get rangeLabel=>switch(this){
    _Zone.far=>'بعيد > 2م',
    _Zone.medium=>'1 – 2 متر',
    _Zone.near=>'50 سم – 1م',
    _Zone.danger=>'قوة إشارة القرب\nمن جهاز الغش',
  };
  String get shortDesc=>switch(this){
    _Zone.far=>'خارج النطاق',_Zone.medium=>'في المحيط',
    _Zone.near=>'تدقيق فوري',_Zone.danger=>'خطر مباشر',
  };
}
