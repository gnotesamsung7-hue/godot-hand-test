package com.markdave.handtracker

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Runs MediaPipe hand tracking on the front camera and sends the result to Godot.
 *
 * Signals:
 *   hand_landmarks(csv: String)  "frameWidth,frameHeight,x0,y0,z0,...,x20,y20,z20" (only the size when no hand is seen)
 *   status(message: String)
 * Methods: start(), stop(), isRunning()
 */
class HandTrackerPlugin(godot: Godot) : GodotPlugin(godot) {

    private var landmarker: HandLandmarker? = null
    private var provider: ProcessCameraProvider? = null
    private var executor: ExecutorService? = null
    @Volatile private var running = false
    @Volatile private var frameW = 1
    @Volatile private var frameH = 1

    override fun getPluginName() = "HandTracker"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("hand_landmarks", String::class.java),
        SignalInfo("status", String::class.java)
    )

    @UsedByGodot
    fun start() {
        val act = activity ?: return
        if (running) return
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            status("no camera permission yet")
            return
        }
        running = true
        val ex = Executors.newSingleThreadExecutor()
        executor = ex
        ex.execute {
            try {
                landmarker = createLandmarker()
                status("hand model loaded")
            } catch (e: Throwable) {
                status("model error: ${e.message}")
                running = false
                return@execute
            }
            act.runOnUiThread { bindCamera() }
        }
    }

    @UsedByGodot
    fun stop() {
        running = false
        activity?.runOnUiThread { provider?.unbindAll() }
        executor?.execute { landmarker?.close(); landmarker = null }
    }

    @UsedByGodot
    fun isRunning(): Boolean = running

    override fun onMainDestroy() {
        stop()
        super.onMainDestroy()
    }

    private fun createLandmarker(): HandLandmarker {
        val act = activity ?: throw IllegalStateException("no activity")
        // Load the model into memory ourselves so it works even if the APK compresses the asset.
        val bytes = act.assets.open("hand_landmarker.task").use { it.readBytes() }
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        buffer.put(bytes)
        buffer.rewind()
        val base = BaseOptions.builder().setModelAssetBuffer(buffer).build()
        val options = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(base)
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumHands(1)
            .setMinHandDetectionConfidence(0.5f)
            .setMinHandPresenceConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .setResultListener { result: HandLandmarkerResult, _ -> onResult(result) }
            .setErrorListener { e -> status("tracking error: ${e.message}") }
            .build()
        return HandLandmarker.createFromOptions(act, options)
    }

    private fun bindCamera() {
        val act = activity ?: return
        val owner = act as? LifecycleOwner
        if (owner == null) {
            status("camera error: activity is not a LifecycleOwner")
            return
        }
        val future = ProcessCameraProvider.getInstance(act)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                analysis.setAnalyzer(executor!!) { image -> analyze(image) }
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_FRONT_CAMERA, analysis)
                status("camera started")
            } catch (e: Throwable) {
                status("camera error: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(act))
    }

    private fun analyze(image: ImageProxy) {
        try {
            val lm = landmarker ?: return
            val bitmap = image.toBitmap()
            val rotation = image.imageInfo.rotationDegrees
            val upright = if (rotation != 0) {
                val m = Matrix()
                m.postRotate(rotation.toFloat())
                Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
            } else bitmap
            frameW = upright.width
            frameH = upright.height
            lm.detectAsync(BitmapImageBuilder(upright).build(), SystemClock.uptimeMillis())
        } catch (e: Throwable) {
            status("frame error: ${e.message}")
        } finally {
            image.close()
        }
    }

    private fun onResult(result: HandLandmarkerResult) {
        val sb = StringBuilder(64 * 12)
        sb.append(frameW).append(',').append(frameH)
        val hands = result.landmarks()
        if (hands.isNotEmpty()) {
            for (p in hands[0]) sb.append(',').append(p.x()).append(',').append(p.y()).append(',').append(p.z())
        }
        val csv = sb.toString()
        runOnRenderThread { emitSignal("hand_landmarks", csv) }
    }

    private fun status(message: String) {
        Log.i("HandTracker", message)
        runOnRenderThread { emitSignal("status", message) }
    }
}
