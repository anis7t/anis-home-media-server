package `in`.anisparvez.media_server_client

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val UPDATER_CHANNEL = "in.anisparvez.media_server_client/app_updater"
    private val BRIGHTNESS_CHANNEL = "in.anisparvez.media_server_client/screen_brightness"
    private val VOLUME_CHANNEL = "in.anisparvez.media_server_client/media_volume"
    private val DEVICE_MODE_CHANNEL = "in.anisparvez.media_server_client/device_mode"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_MODE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceCapabilities" -> {
                    try {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                        val isTelevision = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        val hasLeanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                                          packageManager.hasSystemFeature("android.hardware.type.television")
                        val isFireTv = Build.MODEL.startsWith("AFT", ignoreCase = true) || 
                                       Build.MANUFACTURER.contains("Amazon", ignoreCase = true)
                        val hasTouch = packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)

                        val isTv = isTelevision || hasLeanback || isFireTv

                        result.success(mapOf(
                            "isTv" to isTv,
                            "isFireTv" to isFireTv,
                            "hasLeanback" to hasLeanback,
                            "hasTouchscreen" to hasTouch,
                            "model" to Build.MODEL,
                            "manufacturer" to Build.MANUFACTURER
                        ))
                    } catch (e: Exception) {
                        result.error("DEVICE_CAPABILITIES_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppInfo" -> {
                    try {
                        val pInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        val vCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            pInfo.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            pInfo.versionCode.toLong()
                        }
                        result.success(mapOf(
                            "packageName" to packageName,
                            "versionName" to (pInfo.versionName ?: "1.0.0"),
                            "versionCode" to vCode
                        ))
                    } catch (e: Exception) {
                        result.error("APP_INFO_ERROR", e.message, null)
                    }
                }
                "canInstallUnknownPackages" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        result.success(packageManager.canRequestPackageInstalls())
                    } else {
                        result.success(true)
                    }
                }
                "openInstallPermissionSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null)
                    }
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrBlank()) {
                        result.error("INVALID_PATH", "filePath argument is required", null)
                        return@setMethodCallHandler
                    }
                    val file = File(filePath)
                    if (!file.exists() || file.length() <= 0) {
                        result.error("FILE_NOT_FOUND", "APK file does not exist or is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val contentUri = FileProvider.getUriForFile(
                            this,
                            "$packageName.updateProvider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(contentUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Player brightness: WindowManager.LayoutParams.screenBrightness overrides
        // the system level while this window is focused (no permission needed).
        // A negative value hands control back to the system.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BRIGHTNESS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBrightness" -> {
                    val value = (call.argument<Double>("value") ?: -1.0).toFloat()
                    runOnUiThread {
                        try {
                            val attrs = window.attributes
                            attrs.screenBrightness =
                                if (value < 0f) -1f else value.coerceIn(0.01f, 1f)
                            window.attributes = attrs
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BRIGHTNESS_ERROR", e.message, null)
                        }
                    }
                }
                "getBrightness" -> {
                    val current = window.attributes.screenBrightness
                    result.success(if (current < 0f) null else current.toDouble())
                }
                else -> result.notImplemented()
            }
        }

        // System media volume: the level the user actually hears, so the right-half
        // swipe matches the phone volume keys (AudioManager.STREAM_MUSIC).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL).setMethodCallHandler { call, result ->
            val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audio == null) {
                result.success(if (call.method == "getVolume") 0 else false)
                return@setMethodCallHandler
            }
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            when (call.method) {
                "getVolume" -> {
                    val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    result.success(if (max > 0) current * 100 / max else 0)
                }
                "setVolume" -> {
                    val percent = call.argument<Int>("percent") ?: -1
                    if (percent < 0 || max <= 0) {
                        result.success(false)
                    } else {
                        runOnUiThread {
                            try {
                                audio.setStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    percent.coerceIn(0, 100) * max / 100,
                                    0,
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("VOLUME_ERROR", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun getInitialRoute(): String? {
        val route = intent.getStringExtra("route")
        if (!route.isNullOrBlank()) {
            return if (route.startsWith("/")) route else "/$route"
        }
        return super.getInitialRoute()
    }

    override fun getDartEntrypointArgs(): List<String> {
        val args = ArrayList(super.getDartEntrypointArgs() ?: emptyList())
        val route = intent.getStringExtra("route")
        if (!route.isNullOrBlank()) {
            args.add("--route=$route")
            if (route.contains("player")) {
                args.add("--player")
            }
        }
        if (intent.getBooleanExtra("player", false)) {
            args.add("--player")
        }
        val server = intent.getStringExtra("server")
        if (!server.isNullOrBlank()) {
            args.add("--server=$server")
        }
        val mediaUrl = intent.getStringExtra("mediaUrl")
        if (!mediaUrl.isNullOrBlank()) {
            args.add("--media-url=$mediaUrl")
        }
        return args
    }
}
