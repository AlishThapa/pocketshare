package np.com.thapaalish.pocketshare

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "pocketshare/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Where the packaged cloudflared actually lands on disk.
                    // This is the one directory an app may exec from, which is
                    // why cloudflared ships as libcloudflared.so.
                    "nativeLibraryDir" ->
                        result.success(applicationInfo.nativeLibraryDir)

                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())

                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }

                    "storageVolumes" -> result.success(storageVolumes())

                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())

                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }

                    // MIUI hides autostart behind a vendor settings screen that
                    // cannot be toggled programmatically; the best we can do is
                    // take the user there.
                    "openAutostartSettings" -> {
                        result.success(openAutostartSettings())
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) return
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
        } catch (_: Exception) {
            // Some ROMs omit this activity; fall back to the settings page.
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    /**
     * Real storage roots on this device: internal shared storage, plus an SD
     * card when one is present.
     *
     * Derived from getExternalFilesDirs by trimming the per-app suffix, which
     * works on every API level and needs no reflection. Writing outside the
     * app's own folder still requires all-files access.
     */
    private fun storageVolumes(): List<Map<String, Any?>> {
        val marker = "/Android/data/"
        val volumes = mutableListOf<Map<String, Any?>>()

        for (dir in getExternalFilesDirs(null)) {
            if (dir == null) continue

            val index = dir.absolutePath.indexOf(marker)
            if (index < 0) continue
            val root = dir.absolutePath.substring(0, index)

            val removable = try {
                Environment.isExternalStorageRemovable(dir)
            } catch (_: Exception) {
                false
            }

            val stats = try {
                StatFs(root)
            } catch (_: Exception) {
                null
            }

            volumes.add(
                mapOf(
                    "path" to root,
                    "removable" to removable,
                    "totalBytes" to (stats?.totalBytes ?: 0L),
                    "freeBytes" to (stats?.availableBytes ?: 0L),
                ),
            )
        }
        return volumes
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    .setData(Uri.parse("package:$packageName"))
            )
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    /** Known vendor autostart screens, tried in order. */
    private fun openAutostartSettings(): Boolean {
        val candidates = listOf(
            "com.miui.securitycenter" to
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            "com.letv.android.letvsafe" to
                "com.letv.android.letvsafe.AutobootManageActivity",
            "com.huawei.systemmanager" to
                "com.huawei.systemmanager.optimize.process.ProtectActivity",
            "com.coloros.safecenter" to
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.oppo.safe" to
                "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.vivo.permissionmanager" to
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
        )

        for ((pkg, cls) in candidates) {
            try {
                val intent = Intent().setClassName(pkg, cls)
                if (packageManager.resolveActivity(intent, 0) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) {
                continue
            }
        }
        return false
    }
}
