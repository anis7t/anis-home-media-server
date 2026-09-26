package `in`.anisparvez.media_server_client

import android.content.Intent
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
