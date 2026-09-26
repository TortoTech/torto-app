package com.example.torto

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.ActivityManager
import android.os.Build
import java.util.concurrent.Executors
import java.io.File

class MainActivity : FlutterActivity() {
    private val diagnosticsExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torto/diagnostics")
            .setMethodCallHandler { call, result ->
                if (call.method != "exitInfo") {
                    result.notImplemented()
                } else {
                    diagnosticsExecutor.execute {
                        try {
                            val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                            val entries = if (Build.VERSION.SDK_INT >= 30) {
                                manager.getHistoricalProcessExitReasons(packageName, 0, 8).map {
                                    try {
                                        val directory = File(filesDir, "diagnostics").apply { mkdirs() }
                                        val trace = File(directory, "anr-${it.timestamp}.txt")
                                        if (!trace.exists()) {
                                            it.traceInputStream?.use { input ->
                                                trace.outputStream().use { output ->
                                                    val buffer = ByteArray(8192)
                                                    var remaining = 128 * 1024
                                                    while (remaining > 0) {
                                                        val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                                                        if (count < 0) break
                                                        output.write(buffer, 0, count)
                                                        remaining -= count
                                                    }
                                                }
                                            }
                                        }
                                        directory.listFiles { file -> file.name.matches(Regex("anr-[0-9]+\\.txt")) }
                                            ?.sortedByDescending { file -> file.name }
                                            ?.drop(3)?.forEach { file -> file.delete() }
                                    } catch (_: Exception) { /* Trace access is best effort. */ }
                                    mapOf("timestamp" to it.timestamp, "reason" to it.reason,
                                        "status" to it.status, "pss_kb" to it.pss,
                                        "rss_kb" to it.rss, "importance" to it.importance)
                                }
                            } else emptyList()
                            runOnUiThread { result.success(entries) }
                        } catch (_: Exception) {
                            runOnUiThread { result.success(emptyList<Any>()) }
                        }
                    }
                }
            }
    }

    override fun onDestroy() {
        diagnosticsExecutor.shutdown()
        super.onDestroy()
    }
}
