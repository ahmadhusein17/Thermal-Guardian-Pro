package pro.thermalguardian.companion

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Single-screen onboarding. Per Android's accessibility security model,
 * an app can never enable its own AccessibilityService - the user must do
 * it explicitly in system Settings. This activity only deep-links there.
 */
class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
        }

        val info = TextView(this).apply {
            text = getString(R.string.main_instructions)
            textSize = 16f
        }

        val openSettingsBtn = Button(this).apply {
            text = getString(R.string.open_accessibility_settings)
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        }

        layout.addView(info)
        layout.addView(openSettingsBtn)
        setContentView(layout)
    }
}
