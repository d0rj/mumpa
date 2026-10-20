package app.mumpa.mumpa

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import android.provider.Settings
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : AudioServiceActivity() {
    companion object {
        init {
            // Invoke JNI_OnLoad before Dart opens the DSP runtime via FFI.
            // AudioTrack needs the JavaVM registered in this exact library.
            System.loadLibrary("mpv_audio_kit")
        }
        private var torrentProcess: Process? = null
        private var torrentPort: Int = 0
        private const val FOLDER_REQUEST = 4417
    }
    private var folderResult: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.mumpa/updates").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "install" -> {
                        val apk = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                        val updateRoot = File(filesDir, "Mumpa/updates").canonicalFile
                        require(apk.isFile && apk.extension == "apk" && apk.path.startsWith(updateRoot.path + File.separator)) {
                            "Update must be an APK in the private update directory"
                        }
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.error("PERMISSION", "Разреши установку из Mumpa, вернись и нажми «Установить обновление» снова.", null)
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("UPDATE", e.message, null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.mumpa/engine").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val port = call.argument<Int>("port")!!
                    val directory = call.argument<String>("directory")!!
                    val peerPort = call.argument<Int>("torrentPort")!!
                    Thread {
                        try {
                            synchronized(MainActivity::class.java) {
                                if (torrentProcess?.isAlive == true && torrentPort != port) {
                                    torrentProcess?.destroy()
                                    torrentProcess?.waitFor()
                                }
                                if (torrentProcess?.isAlive != true || torrentPort != port) {
                                    val binary = File(applicationInfo.nativeLibraryDir, "libtorrserver.so")
                                    require(binary.exists()) { "Packaged torrent engine is missing for this ABI" }
                                    File(directory).mkdirs()
                                    torrentProcess = ProcessBuilder(binary.absolutePath, "-p", port.toString(), "-i", "127.0.0.1", "--torrentaddr", "0.0.0.0:$peerPort", "-d", directory,
                                        "-l", File(directory,"server.log").absolutePath)
                                        .redirectErrorStream(true).redirectOutput(File(directory,"process.log")).start()
                                    torrentPort = port
                                }
                            }
                            runOnUiThread { result.success(port) }
                        } catch (e: Exception) { runOnUiThread { result.error("ENGINE",e.message,null) } }
                    }.start()
                }
                "stop" -> {
                    Thread {
                        synchronized(MainActivity::class.java) {
                            torrentProcess?.destroy()
                            torrentProcess?.waitFor()
                            torrentProcess = null
                        }
                        runOnUiThread { result.success(null) }
                    }.start()
                }
                "importFolder" -> {
                    if (folderResult != null) result.error("BUSY","Folder picker is already open",null)
                    else {
                        folderResult = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION),FOLDER_REQUEST)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    @Deprecated("Uses document tree picker result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if (requestCode != FOLDER_REQUEST) return
        val result = folderResult ?: return
        folderResult = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) { result.success(emptyList<String>()); return }
        Thread {
            try {
                val paths = mutableListOf<String>()
                val dest = File(filesDir,"music-imports").apply { mkdirs() }
                fun copyTree(documentId: String, level: Int = 0, folderName: String = "Импортированная музыка") {
                    require(level < 64) { "Folder nesting is too deep" }
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree,documentId)
                    contentResolver.query(children,arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,DocumentsContract.Document.COLUMN_MIME_TYPE),null,null,null)?.use { cursor ->
                        while(cursor.moveToNext()) {
                            val id = cursor.getString(0)
                            val name = cursor.getString(1)
                            val mime = cursor.getString(2)
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { copyTree(id,level+1,name); continue }
                            val extension = name.substringAfterLast('.',"").lowercase()
                            val isAudio = extension in setOf("mp3","flac","m4a","aac","ogg","opus","wav","aiff","aif","ape","wma","webm","alac")
                            if (!isAudio && extension !in setOf("jpg","jpeg","png")) continue
                            val uri = DocumentsContract.buildDocumentUriUsingTree(tree,id)
                            val key = MessageDigest.getInstance("SHA-256").digest((tree.toString()+documentId).toByteArray()).joinToString("") { "%02x".format(it) }
                            val parent = File(dest,key.take(24)+"/"+folderName.replace(Regex("[/\\\\]"),"_")).apply { mkdirs() }
                            val target = File(parent,name.replace(Regex("[/\\\\]"),"_"))
                            val temp = File(parent,target.name+".part")
                            contentResolver.openInputStream(uri)?.use { input -> temp.outputStream().use { input.copyTo(it) } }
                                ?: throw IllegalStateException("Cannot open $name")
                            if (!temp.renameTo(target)) { temp.copyTo(target,overwrite=true); temp.delete() }
                            if (isAudio) paths.add(target.absolutePath)
                        }
                    }
                }
                copyTree(DocumentsContract.getTreeDocumentId(tree))
                runOnUiThread { result.success(paths) }
            } catch (e: Exception) { runOnUiThread { result.error("IMPORT",e.message,null) } }
        }.start()
    }
}
