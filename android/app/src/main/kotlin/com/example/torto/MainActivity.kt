package com.example.torto

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val pdfExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "torto/pdf-cover")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "PDF path is missing", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "inspect" -> pdfExecutor.execute {
                        try {
                            val pageCount = inspectPdf(path)
                            runOnUiThread {
                                result.success(mapOf("pageCount" to pageCount))
                            }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("pdf_inspect_failed", error.message, null)
                            }
                        }
                    }

                    "renderPage" -> {
                        val pageIndex = call.argument<Int>("pageIndex") ?: 0
                        val maxDimension = call.argument<Int>("maxDimension") ?: 384
                        if (pageIndex < 0) {
                            result.error("invalid_page", "PDF page index is invalid", null)
                            return@setMethodCallHandler
                        }
                        pdfExecutor.execute {
                            try {
                                val bytes = renderPage(
                                    path,
                                    pageIndex,
                                    maxDimension.coerceIn(64, 2048),
                                )
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("pdf_render_failed", error.message, null)
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        pdfExecutor.shutdown()
        super.onDestroy()
    }

    private fun renderPage(path: String, pageIndex: Int, maxDimension: Int): ByteArray? {
        ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                if (pageIndex >= renderer.pageCount) return null
                renderer.openPage(pageIndex).use { page ->
                    val scale = maxDimension.toDouble() / max(page.width, page.height).toDouble()
                    val width = (page.width * scale).roundToInt().coerceAtLeast(1)
                    val height = (page.height * scale).roundToInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        return ByteArrayOutputStream().use { output ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                            output.toByteArray()
                        }
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
        }
    }

    private fun inspectPdf(path: String): Int {
        ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                return renderer.pageCount
            }
        }
    }
}
