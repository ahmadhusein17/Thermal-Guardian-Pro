package pro.thermalguardian.companion

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import java.io.File

/**
 * Reports which app is currently in the foreground, using the official
 * AccessibilityService API (see
 * https://developer.android.com/guide/topics/ui/accessibility/service).
 *
 * This exists because Thermal Guardian Pro's per-app profile / game
 * auto-detection previously relied only on parsing `dumpsys window` /
 * `dumpsys activity activities` text output from a root shell. That works
 * on most devices today, but it is an unofficial, unstable interface:
 * output format varies by OEM/Android version and some vendors restrict
 * it further each release. TYPE_WINDOW_STATE_CHANGED is the API Android
 * itself documents for "what app is the user looking at right now" -
 * more reliable and updates in real time instead of on a polling interval.
 *
 * Privacy: canRetrieveWindowContent is false in
 * accessibility_service_config.xml, so this service only ever sees the
 * package name of the event source - never screen text, view hierarchy,
 * or any other content.
 *
 * The service writes "<unix_epoch> <package_name>" to a file in this
 * app's private internal storage. Thermal Guardian Pro's guardian.sh runs
 * as root and can read any app's private files directly, so no shared
 * storage permission or broadcast plumbing is needed. If this app isn't
 * installed, or the accessibility permission isn't granted, or the file
 * goes stale, guardian.sh silently falls back to the old dumpsys-based
 * detection - installing this app is optional, not required.
 */
class ForegroundBridgeService : AccessibilityService() {

    private lateinit var outFile: File
    private lateinit var tmpFile: File
    private var lastPkg: String? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        outFile = File(filesDir, "foreground.state")
        tmpFile = File(filesDir, "foreground.state.tmp")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString()
        if (pkg.isNullOrEmpty()) return
        // Skip redundant writes - most useful when the same app fires
        // several TYPE_WINDOW_STATE_CHANGED events in a row (dialogs,
        // fragment swaps, etc).
        if (pkg == lastPkg) return
        lastPkg = pkg
        writeState(pkg)
    }

    private fun writeState(pkg: String) {
        try {
            val ts = System.currentTimeMillis() / 1000
            tmpFile.writeText("$ts $pkg\n")
            // Atomic on the same filesystem, so guardian.sh never reads a
            // half-written line.
            tmpFile.renameTo(outFile)
        } catch (_: Exception) {
            // Best-effort only - guardian.sh falls back to dumpsys if this
            // file is missing, unreadable, or stale.
        }
    }

    override fun onInterrupt() {
        // No feedback loop to interrupt - nothing to do.
    }
}
