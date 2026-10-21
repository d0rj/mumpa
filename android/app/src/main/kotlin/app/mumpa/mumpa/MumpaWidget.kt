package app.mumpa.mumpa

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import android.widget.RemoteViews

class MumpaWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) update(context, manager, id)
    }
    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for (id in manager.getAppWidgetIds(ComponentName(context, MumpaWidget::class.java))) update(context, manager, id)
        }
        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val preferences = context.getSharedPreferences("mumpa-widget", Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.mumpa_widget)
            views.setTextViewText(R.id.widget_title, preferences.getString("title", "Mumpa"))
            views.setTextViewText(R.id.widget_artist, preferences.getString("artist", ""))
            views.setImageViewResource(R.id.widget_play, if (preferences.getBoolean("playing", false)) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            views.setOnClickPendingIntent(R.id.widget_title, PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), flags))
            for ((view, key) in listOf(R.id.widget_previous to KeyEvent.KEYCODE_MEDIA_PREVIOUS, R.id.widget_play to KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, R.id.widget_next to KeyEvent.KEYCODE_MEDIA_NEXT)) {
                val intent = Intent(Intent.ACTION_MEDIA_BUTTON).setComponent(ComponentName(context, com.ryanheise.audioservice.MediaButtonReceiver::class.java))
                    .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, key))
                views.setOnClickPendingIntent(view, PendingIntent.getBroadcast(context, key, intent, flags))
            }
            manager.updateAppWidget(id, views)
        }
    }
}
