package app.secretplay

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Minimal native surface for SecretPlay.
 *
 * Deliberately small: lifecycle signals that Flutter's own lifecycle can miss on
 * some OEM builds, FLAG_SECURE for the private area, a microphone permission
 * request, and the foreground service used during calls.
 *
 * Nothing here reads, logs or stores message content.
 */
class MainActivity : FlutterActivity() {

    private var methodChannel: MethodChannel? = null
    private var lifecycleSink: EventChannel.EventSink? = null
    private var lockSink: EventChannel.EventSink? = null
    private var pendingMicResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        methodChannel = MethodChannel(messenger, "app.secretplay/native").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecureFlag" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        applySecureFlag(enabled)
                        result.success(null)
                    }
                    "requestMicrophonePermission" -> requestMicrophone(result)
                    "startCallService" -> {
                        val label = call.argument<String>("peerLabel") ?: "SecretPlay call"
                        startCallService(label)
                        result.success(null)
                    }
                    "stopCallService" -> {
                        stopService(Intent(this, CallService::class.java))
                        result.success(null)
                    }
                    "androidVersion" -> result.success(Build.VERSION.RELEASE)
                    else -> result.notImplemented()
                }
            }
        }

        EventChannel(messenger, "app.secretplay/lifecycle").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    lifecycleSink = events
                }

                override fun onCancel(arguments: Any?) {
                    lifecycleSink = null
                }
            }
        )

        EventChannel(messenger, "app.secretplay/lock").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    lockSink = events
                }

                override fun onCancel(arguments: Any?) {
                    lockSink = null
                }
            }
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Keep screenshots out of the recents thumbnail from the very first frame.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun onStart() {
        super.onStart()
        lifecycleSink?.success("foreground")
    }

    /**
     * `onStop` fires when the activity is no longer visible: home, recents, task
     * switch, screen off. It does not fire for dialogs or the biometric prompt,
     * which is exactly the distinction the Dart lock controller needs.
     */
    override fun onStop() {
        lifecycleSink?.success("background")
        lockSink?.success(if (isFinishing) "app_detached" else "backgrounded")
        super.onStop()
    }

    override fun onDestroy() {
        stopService(Intent(this, CallService::class.java))
        methodChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }

    private fun applySecureFlag(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun requestMicrophone(result: MethodChannel.Result) {
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingMicResult != null) {
            result.success(false)
            return
        }
        pendingMicResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (requestCode == MIC_REQUEST) {
            pendingMicResult?.success(granted)
            pendingMicResult = null
        } else if (requestCode == NOTIFICATION_REQUEST) {
            pendingNotificationResult?.success(granted)
            pendingNotificationResult = null
        }
    }

    private fun startCallService(label: String) {
        val intent = Intent(this, CallService::class.java).putExtra(CallService.EXTRA_LABEL, label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    companion object {
        private const val MIC_REQUEST = 4101
        private const val NOTIFICATION_REQUEST = 4102
    }
}

