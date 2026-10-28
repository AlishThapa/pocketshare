package np.com.thapaalish.pocketshare

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

                    // Only Xiaomi/Oppo/Vivo/Huawei-style ROMs have this screen.
                    // Asking first keeps the prompt off phones it cannot help.
                    "hasAutostartSettings" ->
                        result.success(autostartIntent() != null)

                    // Hands the address to whatever the user shares with.
                    // Done natively rather than with a share plugin: one
                    // fewer third-party dependency in an app whose whole
                    // point is that nothing sits in the middle.
                    "shareText" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val subject = call.argument<String>("subject")
                        result.success(shareText(text, subject))
                    }

                    // Opens a folder in whatever file manager the phone has.
                    // There is no guaranteed intent for this, so it is a
                    // chain of attempts and an honest false at the end.
                    "openFolder" -> {
                        val path = call.argument<String>("path").orEmpty()
                        result.success(openFolder(path))
                    }

                    "openFile" -> {
                        val path = call.argument<String>("path").orEmpty()
                        result.success(openFile(path))
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
    private fun autostartIntent(): Intent? {
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
                if (packageManager.resolveActivity(intent, 0) != null) return intent
            } catch (_: Exception) {
                continue
            }
        }
        return null
    }

    private fun openAutostartSettings(): Boolean {
        val intent = autostartIntent() ?: return false
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun shareText(text: String, subject: String?): Boolean {
        if (text.isEmpty()) return false
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)
        if (!subject.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_SUBJECT, subject)
        return try {
            startActivity(Intent.createChooser(intent, null))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Opens [path] in a file manager.
     *
     * Android has never specified an intent for "show me this folder", so
     * this tries the documents-provider URI that DocumentsUI understands,
     * then a plain folder view, then the file manager's own front door.
     */
    private fun openFolder(path: String): Boolean {
        val dir = File(path)
        if (!dir.isDirectory) return false

        for (intent in folderIntents(dir)) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Every way of saying "no": no activity, a refused grant, or
                // a ROM that throws something of its own. The point of this
                // list is to try the next one, never to take the app down
                // because a file manager was fussy.
                continue
            }
        }
        return false
    }

    private fun folderIntents(dir: File): List<Intent> {
        val intents = mutableListOf<Intent>()

        documentId(dir)?.let { id ->
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                id,
            )
            intents.add(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            )
        }

        // No file:// fallback here. minSdk is 24, and handing a file URI to
        // another app throws FileUriExposedException on exactly every device
        // this app runs on — from startActivity, before anything resolves,
        // so it would crash rather than fall through.

        // Last resort: the file manager, wherever it lands.
        intents.add(
            Intent(Intent.ACTION_VIEW)
                .setType(DocumentsContract.Document.MIME_TYPE_DIR),
        )

        return intents
    }

    /**
     * `primary:Some/Folder` for shared storage, or `<uuid>:Some/Folder` for a
     * card. Null when the path is not on a volume this can name.
     */
    private fun documentId(dir: File): String? {
        for (volume in getExternalFilesDirs(null)) {
            if (volume == null) continue
            val index = volume.absolutePath.indexOf("/Android/data/")
            if (index < 0) continue
            val root = volume.absolutePath.substring(0, index)
            if (!dir.absolutePath.startsWith("$root/") && dir.absolutePath != root) {
                continue
            }

            val relative = dir.absolutePath.removePrefix(root).trimStart('/')
            val isPrimary = try {
                !Environment.isExternalStorageRemovable(volume)
            } catch (_: Exception) {
                true
            }
            val name = if (isPrimary) "primary" else root.substringAfterLast('/')
            return "$name:$relative"
        }
        return null
    }

    /**
     * Hands a single file to whatever app can display it.
     *
     * The URI comes from FileProvider rather than Uri.fromFile: a file:// URI
     * crossing an app boundary throws FileUriExposedException on Android 7+,
     * and the grant here is read-only and scoped to the one file.
     */
    private fun openFile(path: String): Boolean {
        val file = File(path)
        if (!file.isFile) return false

        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (_: IllegalArgumentException) {
            return false
        }

        val extension = file.extension.lowercase()
        val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "*/*"

        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, type)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            )
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
