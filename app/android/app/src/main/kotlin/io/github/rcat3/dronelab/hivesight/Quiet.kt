package io.github.rcat3.dronelab.hivesight

import android.app.NotificationManager
import android.app.NotificationManager.Policy
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import androidx.annotation.RequiresApi
import org.json.JSONObject

/**
 * Keeps other apps' notifications out of the Vessel's view: Do Not Disturb on
 * Priority, with only media (our own sound) and alarms let through, and the
 * visual interruptions (heads-up, screen on, status bar) hidden. Needs the
 * "Do Not Disturb access" the person grants in Android's settings once.
 *
 * Their own settings are saved first, kept on disk, and put back when the
 * view leaves the front (and at the next start if the app was killed with
 * them still changed). A phone already on Alarms only or Total silence is
 * left as it is.
 */
@RequiresApi(30)
object Quiet {
    private const val TAG = "HiveSightQuiet"
    private const val PREFS = "hivesight"
    private const val KEY = "quiet_prior"

    private fun nm(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun hasAccess(c: Context) = nm(c).isNotificationPolicyAccessGranted

    fun settingsIntent(): Intent =
        Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun start(c: Context) {
        try {
            val nm = nm(c)
            if (!nm.isNotificationPolicyAccessGranted) return
            restore(c) // left over from a kill, if any
            val filter = nm.currentInterruptionFilter
            if (filter == NotificationManager.INTERRUPTION_FILTER_NONE ||
                filter == NotificationManager.INTERRUPTION_FILTER_ALARMS
            ) return
            val p = nm.notificationPolicy
            prefs(c).edit().putString(
                KEY,
                JSONObject().put("filter", filter).put("cats", p.priorityCategories)
                    .put("calls", p.priorityCallSenders).put("msgs", p.priorityMessageSenders)
                    .put("conv", p.priorityConversationSenders).put("fx", p.suppressedVisualEffects).toString(),
            ).commit()
            // Calls stay as the person has them; everything else is dropped but media and alarms
            val cats = (p.priorityCategories and (Policy.PRIORITY_CATEGORY_CALLS or Policy.PRIORITY_CATEGORY_REPEAT_CALLERS)) or
                Policy.PRIORITY_CATEGORY_MEDIA or Policy.PRIORITY_CATEGORY_ALARMS
            val fx = Policy.SUPPRESSED_EFFECT_PEEK or Policy.SUPPRESSED_EFFECT_SCREEN_ON or
                Policy.SUPPRESSED_EFFECT_FULL_SCREEN_INTENT or Policy.SUPPRESSED_EFFECT_STATUS_BAR or
                Policy.SUPPRESSED_EFFECT_LIGHTS or Policy.SUPPRESSED_EFFECT_AMBIENT or Policy.SUPPRESSED_EFFECT_BADGE
            nm.notificationPolicy = Policy(cats, p.priorityCallSenders, p.priorityMessageSenders, fx, p.priorityConversationSenders)
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
        } catch (e: Exception) {
            Log.w(TAG, "start: ${e.message}")
        }
    }

    /** Their settings back, if we changed them. */
    fun restore(c: Context) {
        try {
            val saved = prefs(c).getString(KEY, null) ?: return
            val nm = nm(c)
            if (nm.isNotificationPolicyAccessGranted) {
                val j = JSONObject(saved)
                nm.notificationPolicy = Policy(
                    j.getInt("cats"), j.getInt("calls"), j.getInt("msgs"), j.getInt("fx"), j.getInt("conv"),
                )
                nm.setInterruptionFilter(j.getInt("filter"))
            }
            prefs(c).edit().remove(KEY).commit()
        } catch (e: Exception) {
            Log.w(TAG, "restore: ${e.message}")
        }
    }
}
