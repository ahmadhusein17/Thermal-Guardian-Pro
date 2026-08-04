# Thermal Guardian Pro

Thermal Guardian Pro adalah modul canggih yang dirancang untuk manajemen suhu (*thermal management*) adaptif pada perangkat Android. Prinsip dasar modul ini sangat tegas dan tidak berubah: **tidak pernah mematikan proteksi panas bawaan (*thermal throttling*) secara permanen.** 

Modul ini bekerja dengan memberikan ruang performa ekstra saat suhu aman, dan secara otomatis memulihkan proteksi sistem bawaan pabrik (OEM) ketika suhu mencapai ambang batas yang ditentukan.

---

## 🚀 Fitur Utama

- **Dukungan Chipset Universal & Auto-Discovery:** Mendukung cakupan *daemon* secara luas melintasi berbagai chipset (Qualcomm/QTI, MediaTek, Samsung Exynos, dan Unisoc/Spreadtrum) dan berbagai OEM (OPPO/Realme, Vivo, Xiaomi, dll.). Fitur *auto-discovery* secara aktif memindai dan mengelola proses yang berkaitan dengan termal, memberikan kompatibilitas tinggi di hampir seluruh perangkat Android.
- **Deteksi Game Otomatis (Heuristik):** Secara cerdas mengidentifikasi game atau aplikasi berat tanpa mengandalkan *machine learning* yang berat. Menggunakan kombinasi sinyal aplikasi *foreground* dan peningkatan suhu perangkat. Saat terpicu, modul akan menerapkan profil *Performance* secara otomatis.
- **Profil Per-Aplikasi Dinamis:** Memungkinkan pengguna menetapkan mode khusus untuk aplikasi tertentu (misalnya game favorit). Mode akan berubah secara otomatis saat aplikasi dibuka dan tertutup tanpa mengubah mode *default* harian Anda.
- **Antarmuka WebUI yang Responsif & Efisien:** Menggunakan arsitektur *single-path polling* dengan *backoff* adaptif yang menghilangkan *freeze* atau ANR (Application Not Responding) pada WebView. UI dirancang minimalis berbasis angka yang akurat, mencakup menu Status, Game, dan Pengaturan Lanjutan. 
- **Akurasi Sensor Suhu (*Governing Temperature*):** Secara cerdas mengabaikan zona non-SoC (seperti sensor baterai/IC *charger* yang ikut memanas saat pengisian daya) dalam menentukan batas maksimal, sehingga mencegah *throttling* yang keliru.
- **Kalkulasi Data di Latar Belakang:** Analisis statistik (Suhu Terendah, Rata-rata, Tertinggi) selama 1 jam terakhir dieksekusi langsung oleh *daemon* di latar belakang melalui skrip *shell*, sehingga WebUI berjalan sangat ringan tanpa beban *rendering* grafis.

---

## ⚙️ Mekanisme Kerja: Mengapa Berbeda dari Modul "Disable Thermal"?

Modul *disable thermal* konvensional umumnya menimpa *binary daemon* bawaan pabrik dengan file kosong dan mematikan sistem proteksi secara permanen. Hal ini sangat berisiko karena jika perangkat mengalami *overheating*, sistem tidak dapat melakukan intervensi.

Thermal Guardian Pro bekerja dengan pendekatan yang jauh lebih cerdas dan aman:

1. **Tanpa Modifikasi Permanen:** Semua kontrol ditangani oleh `guardian.sh` yang berjalan di latar belakang dan dapat mengembalikan semua perubahan secara instan.
2. **Monitoring Real-Time Multizona:** Membaca suhu setiap beberapa detik dari seluruh zona `/sys/class/thermal/thermal_zone*` untuk menentukan tindakan yang tepat. Suhu baterai juga dipantau secara independen sebagai lapisan keamanan ekstra.
3. **Pelonggaran Dinamis & Pemulihan Otomatis:** Limit performa hanya dilonggarkan saat suhu berada di ambang aman. Begitu suhu mendekati batas, sistem secara otomatis mengembalikan aturan proteksi bawaan pabrik.
4. **Batas Keras (*Hard Limits*) Keamanan Mutlak:** Terdapat batas absolut yang tidak dapat diubah (58°C untuk SoC dan 46°C untuk baterai). Jika salah satu tercapai, proteksi maksimal pabrik (OEM) akan dipaksa aktif terlepas dari mode apa pun yang sedang digunakan.
5. **Histeresis 3°C:** Mencegah sistem kebingungan (bolak-balik menyalakan/mematikan limit) saat suhu berada persis di ambang batas transisi.

---

## 📱 Companion App Opsional (Deteksi Foreground Resmi)

Sebelumnya, deteksi profil per-aplikasi mengandalkan *parsing* teks dari *shell root* (`dumpsys`), yang sering kali dibatasi secara ketat oleh sistem Android terbaru. 

Untuk stabilitas jangka panjang, kami menyediakan **Companion App** (berbasis Kotlin) yang menggunakan API `AccessibilityService` resmi dari Android. Aplikasi ini memantau perubahan status *window* secara *real-time*. *(Catatan privasi: Aplikasi tidak memiliki izin `canRetrieveWindowContent`, sehingga hanya dapat membaca nama paket aplikasi, bukan isi layar Anda).*

**Cara Penggunaan (Opsional):**
1. Buka folder `/companion_app` di Android Studio, *build*, dan hasilkan file APK. *(APK tidak disertakan dalam modul .zip bawaan).*
2. Instal APK di perangkat Anda, buka aplikasinya, dan arahkan ke **Pengaturan Aksesibilitas**.
3. Aktifkan **"Thermal Guardian Pro - Companion"**.
4. Selesai! `guardian.sh` akan otomatis menggunakan data ini. Jika aplikasi dihapus atau tidak merespons, modul akan otomatis kembali menggunakan metode *dumpsys* lama tanpa memerlukan konfigurasi ulang.

---

## 🎛️ Pilihan Mode

| Mode | Limit Aman | Karakteristik |
| :--- | :--- | :--- |
| **Eco** | 44°C | Sangat efisien, profil performa menyerupai bawaan pabrik (*stock*). |
| **Balanced** | 47°C | *(Default)* Melonggarkan performa saat aman, memulihkan perlindungan dengan cepat saat mendekati batas. |
| **Performance** | 51°C | Memberikan ruang lebih besar untuk performa maksimal, namun tetap diawasi oleh batas keamanan modul. |
| **Custom** | 40–54°C | Tentukan batas suhu Anda sendiri melalui *slider* di WebUI (tetap dibatasi dalam rentang yang wajar). |

---

## 💻 Penggunaan WebUI & Action Button

Buka modul ini dari tab **Modules** di aplikasi *manager* root Anda (KernelSU, KernelSU Next, APatch, atau Magisk), lalu buka **WebUI**. Di dalam *dashboard*, Anda dapat mengatur mode, fitur lanjutan, hingga melihat log aktivitas *daemon*.

**Action Button:** Menekan tombol *Action* di dalam aplikasi *manager* root akan mengeksekusi pemeriksaan status instan (menampilkan suhu saat ini, mode aktif, dan riwayat terakhir), serta me-*restart daemon* secara otomatis jika terdeteksi berhenti.

*(Catatan: Jika aplikasi root manager Anda mengalami kendala kompatibilitas dengan WebUI, Anda tetap dapat menjalankan perintah pengecekan manual via terminal emulator dengan perintah: `sh /data/adb/modules/thermal_guardian_pro/webui_bridge.sh status`)*

---

## 📁 Struktur Data & Konfigurasi

Untuk memastikan preferensi Anda tidak hilang saat melakukan pembaruan modul, semua file konfigurasi disimpan di luar folder modul, tepatnya di `/data/adb/thermal_guardian_pro/`:
- `config.conf` — Menyimpan mode aktif, preferensi UI, dan konfigurasi lanjutan.
- `profiles.conf` — Daftar profil deteksi per-aplikasi.
- `history.csv` — Riwayat pencatatan suhu berkala.
- `events.log` & `guardian.log` — Catatan pergantian mode dan *output debugging* mentah.

---

## 🗑️ Proses Uninstall

Proses pencabutan (hapus/Uninstall) modul dirancang sebersih mungkin. Menghapus modul dari aplikasi *manager* akan langsung menghentikan `guardian.sh` dan memulihkan seluruh sistem *thermal* bawaan ke kondisi semula tanpa perlu menunggu *reboot*. File konfigurasi di folder data akan tetap dipertahankan jika Anda ingin menginstalnya kembali di masa mendatang.

---

## ⚠️ Peringatan Risiko (Disclaimer)

Melonggarkan limit *thermal* berarti mengizinkan perangkat beroperasi pada suhu yang lebih tinggi dari standar pabrik untuk durasi tertentu demi stabilitas performa. Hal ini **meningkatkan risiko perangkat terasa panas di tangan** dan dalam jangka panjang dapat **mempercepat degradasi kesehatan baterai**, terutama jika Anda terus-menerus menggunakan mode *Performance/Custom* dan mengaktifkan pengaturan lanjutan yang agresif.

Batas keras (*Hard Limits*) pada modul ini berfungsi sebagai jaring pengaman terakhir, bukan jaminan mutlak perangkat terbebas dari risiko keausan *hardware*. **Gunakan dengan bijak**, dan turunkan mode apabila perangkat mulai terasa tidak nyaman saat digenggam.

*Do With Your Own Risk (DWYOR).*
