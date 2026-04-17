package tn.gov.education.examguard

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val METHOD_CH = "tn.gov.education.examguard/service"
        const val EVENT_CH  = "tn.gov.education.examguard/classic_bt"
    }

    @Volatile private var eventSink: EventChannel.EventSink? = null

    // Queue for events that arrive before Flutter has subscribed
    private val pendingEvents = mutableListOf<Map<String, Any>>()
    private val pendingLock   = Any()

    private var scanner: UnifiedBtScanner? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── EventChannel ─────────────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CH)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    // Flush all events that arrived before Flutter subscribed
                    synchronized(pendingLock) {
                        for (ev in pendingEvents) sink?.success(ev)
                        pendingEvents.clear()
                    }
                }
                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })

        // ── MethodChannel ─────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        startBleService()
                        result.success(null)
                    }
                    "stopService" -> {
                        stopBleService()
                        result.success(null)
                    }
                    "startScan" -> {
                        scanner?.stop()
                        scanner = UnifiedBtScanner(this, ::sendToFlutter)
                        scanner?.start()
                        result.success(null)
                    }
                    "stopScan" -> {
                        scanner?.stop()
                        scanner = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Thread-safe send to Flutter.
     * If eventSink is not yet ready, stores in pending queue.
     * Flushed automatically when Flutter subscribes (onListen).
     */
    private fun sendToFlutter(data: Map<String, Any>) {
        runOnUiThread {
            val sink = eventSink
            if (sink != null) {
                sink.success(data)
            } else {
                synchronized(pendingLock) {
                    // Keep at most 200 pending events
                    if (pendingEvents.size < 200) pendingEvents.add(data)
                }
            }
        }
    }

    private fun startBleService() {
        val i = Intent(this, BleService::class.java).apply { action = BleService.ACTION_START }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
        else startService(i)
    }

    private fun stopBleService() {
        val i = Intent(this, BleService::class.java).apply { action = BleService.ACTION_STOP }
        startService(i)
    }

    override fun onDestroy() {
        scanner?.stop()
        super.onDestroy()
    }
}
