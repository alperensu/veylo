# Veylo cam arayüz ve oyun modu

Görsel yön: koyu gece yüzeyleri, mint vurgu, hafif saydam plakalar ve ince cam
kenarları. Apple'ın [Liquid Glass yaklaşımı](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
işlevsel referanstır; Apple asset/font/kodu kullanılmadı. Segoe UI Variable/
Segoe UI ve mevcut vektör simgeler korunur. Bu görünüm Apple'ın gerçek zamanlı
kırılma/arka plan blur motoru değildir; pahalı shader veya masaüstü blur'u yoktur.

Theme.xaml ortak renk, cam kenarı, anahtar, slider, select ve yüzey stilini yönetir.
Animasyonlar180ms hover/press/anahtar,220–300ms sayfa reveal; sonsuz decorative
storyboard yok. VoiceScope yalnızca gerçek çıkış RMS geçmişini gösterir; FFT,
ses kaydı veya yapay konuşma görseli üretmez. Gizli pencerede motion durur.

Motion.Enabled kalıtılan WPF özelliğidir. Oyun modu/manuel efekt kapatma ve
Windows azaltılmış hareket değişimleri devam eden animation clock'larını söker.
Sürücü penceresi de ana pencerenin motion politikasına bağlanır. Windows hareket
tercihi cam tasarımını kaldırmaz; yüksek kontrast cam/animasyonu kapatır.
[Windows erişilebilirlik ayarları](https://support.microsoft.com/en-us/accessibility/windows/make-it-easier-to-focus-on-tasks)
uygulama tarafından değiştirilmez.

GameDetector foreground pencere boyutu ve süreç adlarını5s'de bir worker'da okur.
GameModePolicy bilinen oyunları veya kullanıcı listesini arka planda da eşleştirir.
Diğer uygulamalar tam ekran geometrisiyle değerlendirilir; tarayıcılar/başlatıcılar
hariçtir. Bu bir tahmindir: bilinmeyen tam ekran medya uygulaması yanlış pozitif,
listedeki olmayan borderless-windowed oyun yanlış negatif olabilir. Kullanıcı
özel süreç adı veya otomatik kapatma seçimiyle kontrol eder. Hiçbir süreç
kapatılmaz, oyunun belleğine erişilmez, Windows oyun/öncelik ayarı değiştirilmez.

Oyun algılanınca cam yüzeyler düzleşir, ambient arka plan kapanır, hover/press/
anahtar/sayfa motion ve RMS görseli durur; ölçerler10Hz'den5Hz'e iner. RNNoise,
AGC, kalibrasyon, preset, mute/bypass/limiter ve native callback değişmez.
Algılanan süreç yoksa15s bekleme ile görsel tercih geri döner. Bilinen oyun
Alt+Tab'da açık kaldığı sürece sade görünüm sürer. FPS kazancı garanti edilmez.

Uygulama1120×820 başlangıç düzenini çalışma alanına sığdırır. Dar pencerede
78px simge navigasyonu; kısa pencerede ses dekoru kaldırılıp ölçerler öne alınır.
Scroll ve klavye erişimi korunur; custom pencere düğmelerinde erişilebilir isimler,
maximize/restore ve bildirim alanına gizleme bulunur. Fiziksel çoklu DPI kabulü
henüz yapılmadı; doğrulama kapsamı VALIDATION.md içindedir.
