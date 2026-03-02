package com.example.dive_computer

import android.content.Context
import android.util.Log
import java.util.concurrent.locks.ReentrantLock

/**
 * Manages the dive download process using libdivecomputer's
 * dc_device_foreach and dc_parser APIs via JNI.
 *
 * Design (matching iOS/Subsurface):
 * - All BLE and parsing work happens on a background thread
 * - Progress is written to shared properties (no main-thread dispatches)
 * - The UI polls progress via MethodChannel timer
 * - Full dive data is stored in memory and retrieved after download completes
 * - This eliminates all main-thread work during BLE communication
 */
class DiveDownloader(
    private val context: Context,
    private val devicePtr: Long,    // dc_device_t*
    private val forceDownload: Boolean
) {

    companion object {
        private const val TAG = "DiveDownloader"

        // dc_status_t values
        private const val DC_STATUS_SUCCESS = 0
        private const val DC_STATUS_DONE = 1
    }

    // ── JNI native methods ──────────────────────────────────────────────────

    private external fun nativeStartDownload(devicePtr: Long): Int
    private external fun nativeSetFingerprint(devicePtr: Long, fingerprint: ByteArray): Int
    external fun nativeParseDive(devicePtr: Long, diveData: ByteArray): HashMap<String, Any>?

    // ── Shared state (written from background, read from main) ──────────────

    private val stateLock = ReentrantLock()

    @Volatile private var progressFraction: Double = 0.0
    @Volatile private var diveCount: Int = 0
    @Volatile private var estimatedTotalDives: Int? = null
    @Volatile private var serial: Int? = null
    @Volatile private var firmware: Int? = null
    @Volatile private var isActive: Boolean = true
    @Volatile private var status: String? = null

    /** Full parsed dive data, accumulated during download. */
    private val downloadedDives = mutableListOf<Map<String, Any?>>()

    @Volatile private var _isCancelled = false

    /** Progress tracking for dive count estimation */
    @Volatile private var lastProgressCurrent: Int = 0
    @Volatile private var lastProgressMaximum: Int = 0

    /** Whether we've received devinfo and set fingerprint */
    @Volatile private var devInfoReceived = false

    // ── Public API ──────────────────────────────────────────────────────────

    fun start() {
        Thread(Runnable {
            Log.i(TAG, "Download thread started")
            runDownload()
        }, "DiveDownloader").start()
    }

    fun cancel() {
        _isCancelled = true
    }

    /**
     * Returns the current progress snapshot (called from main thread via polling).
     */
    fun getProgress(): Map<String, Any?> {
        stateLock.lock()
        try {
            return mapOf(
                "isActive" to isActive,
                "progressFraction" to progressFraction,
                "diveCount" to diveCount,
                "estimatedTotalDives" to estimatedTotalDives,
                "serial" to serial,
                "firmware" to firmware,
                "status" to status
            )
        } finally {
            stateLock.unlock()
        }
    }

    /**
     * Returns all downloaded dives (called after download completes).
     */
    fun getDownloadedDives(): List<Map<String, Any?>> {
        stateLock.lock()
        try {
            return downloadedDives.toList()
        } finally {
            stateLock.unlock()
        }
    }

    // ── Download execution (background thread) ──────────────────────────────

    private fun runDownload() {
        // nativeStartDownload blocks until all dives are enumerated.
        // The JNI bridge calls our callback methods during execution.
        val statusCode = nativeStartDownload(devicePtr)

        val statusName = when (statusCode) {
            DC_STATUS_SUCCESS -> "success"
            DC_STATUS_DONE    -> "done"
            else              -> "error($statusCode)"
        }

        Log.i(TAG, "Download complete: $statusName, $diveCount dives")

        stateLock.lock()
        try {
            isActive = false
            status = statusName
        } finally {
            stateLock.unlock()
        }
    }

    // ── JNI callbacks (called from background thread via jni_bridge.cpp) ────

    /**
     * Called by JNI when dc_device_foreach reports progress.
     */
    @Suppress("unused") // Called from JNI
    fun onNativeProgress(current: Int, maximum: Int) {
        lastProgressCurrent = current
        lastProgressMaximum = maximum

        if (maximum > 0) {
            stateLock.lock()
            try {
                progressFraction = current.toDouble() / maximum.toDouble()
            } finally {
                stateLock.unlock()
            }
        }
    }

    /**
     * Called by JNI when dc_device_foreach reports device info.
     */
    @Suppress("unused") // Called from JNI
    fun onNativeDevInfo(model: Int, fw: Int, ser: Int) {
        Log.i(TAG, "DevInfo: model=$model fw=$fw serial=$ser")

        devInfoReceived = true

        stateLock.lock()
        try {
            serial = ser
            firmware = fw
        } finally {
            stateLock.unlock()
        }

        // Load and set fingerprint (skip if force download)
        loadAndSetFingerprint(ser)
    }

    /**
     * Called by JNI for each dive found during enumeration.
     * Returns true to continue, false to stop.
     */
    @Suppress("unused") // Called from JNI
    fun onNativeDive(diveData: ByteArray, fingerprint: ByteArray?): Boolean {
        if (_isCancelled) return false

        stateLock.lock()
        val currentDiveNumber: Int
        try {
            diveCount++
            currentDiveNumber = diveCount
        } finally {
            stateLock.unlock()
        }

        // Estimate total dives when the first dive arrives
        if (currentDiveNumber == 1 && lastProgressMaximum > 0) {
            val totalSteps = lastProgressMaximum / 10000
            if (totalSteps > 0) {
                stateLock.lock()
                try {
                    estimatedTotalDives = totalSteps
                } finally {
                    stateLock.unlock()
                }
                Log.i(TAG, "Estimated total dives: ~$totalSteps (from progress max=$lastProgressMaximum)")
            }
        }

        // Save fingerprint from the first (newest) dive
        if (currentDiveNumber == 1 && fingerprint != null && fingerprint.isNotEmpty()) {
            val ser = serial
            if (ser != null) {
                FingerprintStore.save(context, ser.toLong(), fingerprint)
                Log.i(TAG, "Saved fingerprint for serial $ser")
            }
        }

        // Parse the dive data via JNI (uses dc_parser on the current background thread)
        val parsedDive = nativeParseDive(devicePtr, diveData)
        if (parsedDive != null) {
            // Add fingerprint hex string
            if (fingerprint != null && fingerprint.isNotEmpty()) {
                parsedDive["fingerprint"] = fingerprint.joinToString("") {
                    String.format("%02x", it)
                }
            }

            Log.i(TAG, "Dive #$currentDiveNumber: " +
                "depth=${parsedDive["maxDepth"]}m, " +
                "time=${parsedDive["diveTime"]}s, " +
                "samples=${parsedDive["sampleCount"]}")

            stateLock.lock()
            try {
                downloadedDives.add(parsedDive)
            } finally {
                stateLock.unlock()
            }
        } else {
            Log.w(TAG, "Failed to parse dive #$currentDiveNumber")
        }

        return true // Continue downloading
    }

    /**
     * Called by JNI to check if the download should be cancelled.
     */
    @Suppress("unused") // Called from JNI
    fun isCancelled(): Boolean = _isCancelled

    // ── Fingerprint persistence ─────────────────────────────────────────────

    private fun loadAndSetFingerprint(serial: Int) {
        if (forceDownload) {
            Log.i(TAG, "Force download — skipping saved fingerprint")
            return
        }

        val fpData = FingerprintStore.load(context, serial.toLong())
        if (fpData == null) {
            Log.i(TAG, "No saved fingerprint for serial $serial")
            return
        }

        val status = nativeSetFingerprint(devicePtr, fpData)
        if (status == DC_STATUS_SUCCESS) {
            Log.i(TAG, "Loaded fingerprint for serial $serial: ${fpData.joinToString("") { 
                String.format("%02x", it) 
            }}")
        } else {
            Log.w(TAG, "Failed to set fingerprint: $status")
        }
    }
}
