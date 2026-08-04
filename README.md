# Thermal Guardian Pro v6.0

Penerus dari *Smart Thermal Guardian v3.1*, yang sendiri adalah penerus dari
*Enhanced Disable Thermal Universal PRO*. Prinsip dasarnya tetap sama dan
tidak berubah: **tidak pernah mematikan proteksi panas secara permanen.**

## Companion app opsional - deteksi foreground app resmi (AccessibilityService)

Deteksi game/per-app profile sebelumnya mengandalkan parsing teks keluaran
`dumpsys window` / `dumpsys activity activities` dari shell root. Ini
berfungsi di kebanyakan perangkat, tapi bukan API resmi - formatnya beda-beda
antar OEM/versi Android dan beberapa vendor membatasinya lebih ketat tiap
rilis.

Folder `/companion_app` berisi source project Android (Kotlin) yang
memakai `AccessibilityService` resmi
(https://developer.android.com/guide/topics/ui/accessibility/service) untuk
melaporkan paket aplikasi yang sedang di foreground secara real-time lewat
event `TYPE_WINDOW_STATE_CHANGED` - jauh lebih stabil dibanding parsing teks
dumpsys. `canRetrieveWindowContent` sengaja diset `false`: aplikasi ini
hanya pernah melihat nama paket, tidak pernah membaca isi layar/teks.

**Cara pakai (opsional):**
1. Buka folder `/companion_app` di Android Studio, build APK-nya (perlu
   Android Studio - APK tidak disertakan dalam zip modul ini).
2. Install APK ke perangkat, buka aplikasinya, tekan tombol untuk membuka
   Pengaturan Aksesibilitas, lalu aktifkan "Thermal Guardian Pro -
   Companion".
3. Selesai - `guardian.sh` otomatis memakai data ini kalau tersedia dan
   masih baru (< 10 detik), dan otomatis kembali ke metode dumpsys lama
   kalau companion app ini tidak terpasang/tidak diaktifkan/datanya basi.
   Tidak ada konfigurasi tambahan yang dibutuhkan di modul.

Status sumber deteksi (`FG_SOURCE=a11y` atau `FG_SOURCE=dumpsys`) dicatat
di `status.snapshot` untuk transparansi.


## Apa yang baru di v6

- **WebUI 3 tab** (Status / Game / Lainnya) - tab Status cuma menampilkan
  angka paling penting, sisanya dipindah ke tab Lainnya supaya tidak
  menggulung panjang.
- **Tombol refresh sekarang kasih bukti nyata**: ikon berputar + toast
  "Diperbarui"/"Gagal" setiap ditekan, bukannya diam-diam me-render ulang
  angka yang mungkin kebetulan tidak berubah.
- **Suhu governing mengabaikan zona non-SoC** (baterai/charger/RF/skin/dll)
  saat mengambil nilai maksimum - inilah penyebab laporan "kadang kebaca
  70°C tiba-tiba": sensor charging/baterai yang sedang panas ikut terhitung
  sebagai suhu chip. Zona yang dipakai ditampilkan langsung di UI supaya
  bisa diperiksa sendiri.
- **Tidak ada lagi tombol mode manual.** Mode sepenuhnya mengikuti profil
  per-aplikasi (otomatis pindah saat game dibuka/ditutup) plus detektor
  heuristik untuk app yang belum diprofilkan (lihat di bawah). Default idle
  bisa diubah lewat satu dropdown kecil di tab Lainnya, bukan grid tombol
  besar di layar utama.
- **Tab Game** dengan pemilih aplikasi terpasang (badge "GAME" untuk yang
  dikenali dari daftar bawaan modul, tapi menambah paket apa pun tetap
  bisa manual).
- **Kartu Perangkat**: versi Android/SDK, kernel, model, chipset, dan root
  solution + versi KernelSU (dicatat sekali saat instal, karena variabel
  `$KSU_VER` hanya tersedia di `customize.sh`).
- **Deteksi game otomatis (heuristik)** - opsional, default aktif. Bukan
  model AI/ML sungguhan (tidak ada runtime ML di shell POSIX), tapi dua
  sinyal sederhana yang dikombinasikan: aplikasi pihak ketiga yang sama
  bertahan di foreground beberapa siklus polling berturut-turut, DAN suhu
  device sedang naik selagi aplikasi itu di depan. Begitu terpicu, berlaku
  seperti profil manual (mode Performance) sampai aplikasinya ditutup.
- **Cakupan daemon thermal diperluas** lintas OEM (menambah nama-nama untuk
  OPPO/Realme/OnePlus, Vivo, Xiaomi terbaru, dll - berdasarkan literatur,
  belum diverifikasi di perangkat sungguhan tiap merek) plus
  **auto-discovery**: memindai proses yang mengandung "therm" di luar
  daftar bawaan dan turut menghentikan/memulihkannya, supaya cakupan lebih
  dekat ke "berlaku di HP Android mana pun" dibanding hanya mengandalkan
  daftar nama yang sudah diketahui.

## Apa yang baru di v5 — perbaikan freeze/ANR WebView

v5 adalah rombak total WebUI, dipicu laporan "setiap tombol ditekan selalu
delay dan freeze, kadang muncul peringatan WebView berhenti merespons".

**Penyebabnya** (ditemukan setelah membaca kode v4.2): ada 4 timer
`setInterval` yang berjalan sendiri-sendiri (status/3s, events/12s,
history/15s, profiles/20s) tanpa saling koordinasi. Di beberapa manager,
`ksu.exec()` bersifat sinkron — memanggilnya benar-benar membekukan thread
JS WebView sampai perintah shell selesai. Begitu ke-4 timer itu kebetulan
bertabrakan (di detik ke-60, ke-120, dst.), sampai 5 pemanggilan shell
blocking bisa antre berurutan di thread yang sama - cukup lama untuk
memicu dialog "Page Unresponsive" Android. Setiap tombol pun memanggil
`set` lalu `status` terpisah — dua round-trip blocking setiap sekali tap.

**Perbaikannya murni arsitektur, bukan sekadar kosmetik:**

- **Satu jalur polling, bukan empat.** `webui_bridge.sh poll` sekarang
  mengembalikan status + event + profil sekaligus dalam satu proses shell.
- **Satu antrean serial.** Tidak ada pemanggilan baru yang mulai selagi
  satu pemanggilan lain masih berjalan — baik dari timer maupun dari tap.
- **`apply()` satu round-trip.** Tombol mode/toggle memanggil
  `webui_bridge.sh apply KEY VAL` yang langsung set + kembalikan status
  terbaru dalam satu proses, bukan dua panggilan terpisah.

- **`setTimeout` mandiri-jadwal**, bukan `setInterval` — siklus berikutnya
  baru dijadwalkan setelah yang sebelumnya selesai, jadi tidak pernah
  menumpuk kalau satu round-trip kebetulan lambat.
- **Backoff adaptif.** Kalau round-trip lambat (>1.5 detik), interval
  berikutnya otomatis diperpanjang; kalau konsisten cepat, pelan-pelan
  kembali ke interval dasar.
- **Jeda saat halaman tidak terlihat**, dan opsi **mode Manual** (matikan
  auto-refresh sepenuhnya, refresh lewat tombol ⟳) untuk manager yang
  jembatan JS-nya sangat lambat/blocking.

Ini pengurangan *frekuensi dan jumlah* pemanggilan shell, bukan janji nol
freeze mutlak — kalau manager kamu memang hanya menyediakan jembatan
`ksu.exec` yang sinkron, itu batasan di sisi manager, bukan sesuatu yang
bisa dihilangkan total dari sisi modul. Tapi ini seharusnya jauh lebih
jarang dan jauh lebih singkat dari sebelumnya.

## Apa yang baru di v5 — desain angka saja

Sesuai permintaan: **gauge lingkaran dan grafik riwayat (canvas) dihapus
total.** Semua ditampilkan sebagai angka:

- Suhu SoC besar + kata status (Dilonggarkan / Proteksi Stok / Nonaktif)
- Baterai, Batas Aman, Batas Keras, % waktu longgar dalam 1 jam terakhir
- Terendah / Rata-rata / Tertinggi dalam 1 jam terakhir — dihitung di
  daemon background (`awk` satu-pass atas `history.csv`), bukan di WebUI,
  jadi tidak menambah beban render sama sekali

## Apa yang baru di v5 — fitur

- **Paksa Longgar / Paksa Stok** — dua tombol di kartu status untuk
  override manual seketika. "Paksa Longgar" tetap ditolak (dan dicatat di
  log) kalau suhu sudah di/atas batas keras — tidak bisa memaksa lewat
  batas aman mutlak.
- **Rollup 1 jam** (di atas) dihitung server-side, tidak perlu WebUI
  menarik 100+ titik data lagi seperti versi grafik sebelumnya.

## Apa yang baru sebelumnya (v4.x)

- **Cakupan chipset lebih luas.** Daftar daemon mencakup Qualcomm/QTI,
  MediaTek, Samsung Exynos, dan Unisoc/Spreadtrum, bukan cuma satu OEM.
  `stop`/`start` pada service yang tidak ada di perangkatmu otomatis
  diabaikan, jadi aman dicoba semua.
- **Profil per-aplikasi.** Tandai paket tertentu (misal game favorit)
  supaya otomatis pakai mode lain saat aplikasi itu berjalan, tanpa
  mengubah mode default kamu. Diatur lewat WebUI, disimpan di
  `profiles.conf`.
- **Toggle lanjutan yang ditandai jelas mana yang agresif** (GPU power
  limiter, PPM/LMh) — nonaktif secara default, beri peringatan di UI,
  dan tetap tunduk pada batas keras + pemulihan otomatis yang sama.
- **`uninstall.sh` yang benar-benar memulihkan** semua daemon + sysfs
  begitu modul dihapus, tidak menunggu reboot.

## Kenapa bukan "disable thermal" biasa

Modul-modul disable-thermal versi lama umumnya menimpa binary daemon
thermal (`mi_thermald`, `thermal-engine`, dst.) dengan file kosong secara
permanen, lalu mematikan hampir semua service thermal saat boot tanpa
memperhatikan suhu aktual. Efeknya: proteksi panas OEM hilang total dan
tidak bisa pulih sendiri selama modul aktif. Kalau perangkat benar-benar
kepanasan, tidak ada yang menariknya kembali.

Thermal Guardian Pro bekerja adaptif:

- **Tidak ada file yang ditimpa permanen.** Semua kontrol lewat daemon
  `guardian.sh` yang jalan di background dan bisa membalikkan setiap
  perubahan yang dibuatnya.
- **Membaca suhu real setiap beberapa detik** dari semua zona
  `/sys/class/thermal/thermal_zone*`, mengambil nilai tertinggi sebagai
  acuan (governing temperature) — plus **suhu baterai** dibaca terpisah
  sebagai sinyal keamanan kedua yang independen.
- **Limit hanya dilonggarkan saat suhu benar-benar aman**, sesuai mode
  yang dipilih. Begitu suhu naik ke batas, sistem otomatis mengembalikan
  proteksi bawaan — tidak perlu tindakan manual.
- **Dua batas keras yang tidak bisa diubah dari WebUI:** 58°C untuk suhu
  SoC dan 46°C untuk suhu baterai. Kalau salah satu terlampaui, proteksi
  stok dipaksa aktif, apa pun mode yang sedang dipakai.
- **Histeresis 3°C** mencegah sistem bolak-balik menyalakan/mematikan
  limit saat suhu pas di batas.
- `logd` tidak pernah disentuh — mematikan log daemon tidak ada
  hubungannya dengan manajemen thermal dan cuma menyulitkan debug.

## Apa yang baru di versi Pro

- **Cakupan chipset lebih luas.** Daftar daemon mencakup Qualcomm/QTI,
  MediaTek, Samsung Exynos, dan Unisoc/Spreadtrum, bukan cuma satu OEM.
  `stop`/`start` pada service yang tidak ada di perangkatmu otomatis
  diabaikan, jadi aman dicoba semua.
- **`service.sh` yang sebelumnya tidak ada** — di v3.1 daemon `guardian.sh`
  tidak pernah otomatis start saat boot karena file ini hilang dari
  paket. Di versi ini sudah ditambahkan.
- **Profil per-aplikasi.** Tandai paket tertentu (misal game favorit)
  supaya otomatis pakai mode lain saat aplikasi itu berjalan, tanpa
  mengubah mode default kamu. Diatur lewat WebUI, disimpan di
  `profiles.conf`.
- **Toggle lanjutan yang ditandai jelas mana yang agresif** (GPU power
  limiter, PPM/LMh) — nonaktif secara default, beri peringatan di UI,
  dan tetap tunduk pada batas keras + pemulihan otomatis yang sama.
- **`uninstall.sh` yang benar-benar memulihkan** semua daemon + sysfs
  begitu modul dihapus, tidak menunggu reboot.

## Mode

| Mode        | Limit aman | Karakter |
|-------------|-----------|----------|
| Eco         | 44°C      | Nyaris seperti bawaan pabrik |
| Balanced    | 47°C      | Default. Longgarkan saat aman, pulihkan cepat saat mendekati batas |
| Performance | 51°C      | Ruang lebih untuk performa, tetap dengan pemulihan otomatis |
| Custom      | 40–54°C   | Batas sendiri lewat slider WebUI, tetap dibatasi rentang aman |

## WebUI

Buka modul ini dari tab **Modules** di aplikasi manager (KernelSU,
KernelSU Next, APatch), lalu tekan tombol WebUI. Dashboard menampilkan:

- Suhu SoC + baterai, batas aman, batas keras, dan rollup 1 jam — semua
  angka, tanpa gauge/grafik animasi
- Tombol Paksa Longgar / Paksa Stok untuk override manual
- Selector mode + slider custom
- Toggle lanjutan (dikelompokkan, yang agresif ditandai warna merah)
- Manajer profil per-aplikasi
- Log kejadian setiap kali guardian melonggarkan/memulihkan limit
- Pilihan interval polling (6s/10s/20s/Manual) + tombol refresh manual
- Toggle tema (gelap/terang) dan bahasa (ID/EN)

Beberapa manager punya sedikit perbedaan pada API jembatan JS
(`ksu.exec`). Kalau WebUI tidak menampilkan data live, perintah di
`webui_bridge.sh` tetap bisa dipanggil manual lewat terminal root:

```
sh /data/adb/modules/thermal_guardian_pro/webui_bridge.sh status
```

## Tombol Action

Menekan tombol Action di manager menjalankan status cepat (suhu, mode,
status guardian, 3 kejadian terakhir) dan otomatis restart daemon kalau
ternyata mati. Untuk ganti mode/toggle/profil, tetap pakai WebUI.

## Data & konfigurasi

Disimpan di `/data/adb/thermal_guardian_pro/` (bukan di dalam folder
modul), supaya pengaturanmu tidak hilang saat modul diupdate:

- `config.conf` — mode aktif, semua toggle, tema & bahasa WebUI
- `profiles.conf` — daftar profil per-aplikasi
- `state` / `active_profile` — status guardian saat ini
- `history.csv` — riwayat suhu untuk grafik WebUI
- `events.log` — catatan setiap perubahan status
- `guardian.log` — output mentah daemon, untuk debugging

## Uninstall

Menghapus modul langsung menghentikan `guardian.sh` dan memulihkan
daemon + sysfs bawaan saat itu juga. File konfigurasi di atas sengaja
tidak dihapus, supaya kalau kamu install ulang, pengaturan lama masih
ada.

## Peringatan

Melonggarkan limit thermal berarti perangkat dibiarkan lebih panas dari
biasanya untuk sebagian waktu, demi performa lebih stabil. Ini
meningkatkan risiko perangkat terasa lebih panas di tangan dan bisa
mempercepat penuaan baterai dalam jangka panjang, terutama di mode
Performance/Custom atau dengan toggle agresif aktif. Batas keras di
modul ini adalah jaring pengaman terakhir, bukan jaminan tidak ada
risiko sama sekali — gunakan sesuai kebutuhan, dan turunkan mode kalau
perangkat terasa tidak nyaman digenggam atau baterai terasa boros.
