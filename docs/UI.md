# Veylo arayüzü ve oyun modu

0.7.1-dev, arayüzün ve bölüm yerleşimlerinin yeniden düzenlendiği geliştirme sürümüdür. Açık çalışma
alanı, koyu yan menü ve bakır vurgu; cam/blur/shader yerine okunaklı tipografi,
belirgin odak ve tutarlı kontroller kullanılır. Görsel varlıklar mevcut özgün
vektörlerdir; Segoe UI Variable/Segoe UI sistem fontları kullanılır.

## Günlük kullanım

Ana ekranın sırası: mikrofon ve çıkış bağlantısı, gerçek giriş/çıkış seviyeleri
ve kişisel kalibrasyon kısayolu. Etkin profil göstergesi Profiller'i açar.
Çıkış bulunamadığında aktarımın
kapalı olduğu açıkça yazılır. Hazır profiller tüm profil ayarlarını uygular;
ses karakteri düğmeleri yalnız EQ değiştirmez. Gürültü azaltma sayfasında
otomatik/elle kontrol öne çıkar; ayrıntılı açıklamalar “Nasıl çalışır?” altında
bulunur. Dengeleme ve dinamik işlemler ayrı gruplardır.

Beş bölüm doğrudan yan menüden seçilir: Ana Ekran, Ses İşleme, Profiller,
Kalibrasyon ve Test, Uygulama Ayarları. Ses İşleme içinde Gürültü ve İletim,
Seviye, Ton ve EQ sekmeleri vardır. Gürültü/duyarlılık ve tuşla iletim ilk
sekmededir; kompresörün ayrıntıları Seviye'de gelişmiş açıklık altında kalır.
Hazır profillerin tek seçicisi Profiller'dedir; ton ayarlarında yinelenmez.
Kalibrasyon ve karşılaştırma bir aradadır; eski ortam/seviye kalibrasyonu
mikrofon ayarının gelişmiş seçeneğidir.

Sustur ve Orijinal ses kontrolleri her sayfada alt alanda kalır. Başlangıç,
oyun modu ve genel kısayollar Uygulama Ayarları'ndadır. İletim ayarlarını
uygulamak yalnız konuşma modu/hold tuşunu, genel kısayolları uygulamak yalnız
sustur/orijinal ses/profil tuşlarını kaydeder. Birbirlerinin bekleyen
değişikliklerini uygulamazlar. Sürücü araçları ana ekranda ses bağlantısının
gelişmiş açıklığı altındadır; VB-CABLE için
kendi sürücümüzü kurmak gerekmez. Başlangıç, kısayollar, profil içe/dışa
aktarma, kayıt/dinleme, kalibrasyon uygulama ve geri alma davranışları korunur.
Pencereyi kapatmak bildirim alanına gizler; çıkış bildirim alanından yapılır.

1160×840 başlangıç boyutu çalışma alanına sığdırılır. 940 pikselin altında
yan menü simgelere dönüşür; erişilebilir isimler ve ipuçları kalır. Dar
pencerede cihaz seçiciler, ana ekran kartları ve alt kontroller alt alta
yerleşir. 640×480 minimum boyutta sayfa içeriği dikey kaydırılabilir.

## Görsel politika ve erişilebilirlik

Theme.xaml ortak renkleri, yüzeyleri ve kontrol stillerini yönetir.
ThemePalette, yüksek kontrast açıkken bütün tema fırçalarını Windows sistem
renklerine geçirir ve kapandığında normal paleti geri getirir. Klavye odağı
buton, seçici, slider, anahtar ve menüde görünürdür. Ana renk/zemin çiftleri
metin kontrastı için kontrol edilmiştir. Bu, fiziksel Narrator kabulü değildir.

Motion.Enabled kalıtılan WPF özelliğidir. Hover 140 ms, sayfa geçişi 180 ms;
sonsuz dekoratif storyboard yoktur. Oyun modu, manuel animasyon kapatma,
Windows azaltılmış hareket ve gizlenen pencere çalışan animasyonları iptal
eder. Sistem ayarları uygulama tarafından değiştirilmez. VoiceScope yalnız
gerçek ölçülmüş çıkış RMS geçmişini çizer; ses kaydı/FFT veya uydurma dalga
üretmez. İlk ölçümden önce dalga çizilmez.

GameDetector ön plandaki pencere boyutu ve süreç adlarını 5 saniyede bir
worker'da okur. Bilinen oyunlar veya kullanıcı listesi arka planda da
eşleştirilir. Diğer uygulamalar tam ekran geometrisiyle değerlendirilir;
tarayıcılar/başlatıcılar hariçtir. Yanlış pozitif/negatif mümkündür; özel süreç
listesi ve otomatik mod seçimi kullanıcıdadır. Hiçbir süreç kapatılmaz,
oyunun belleğine erişilmez, Windows oyun/öncelik ayarı değiştirilmez.

Oyun algılanınca vurgu dekoru, hover/press/anahtar/sayfa hareketi ve RMS
görseli durur; ölçerler 10 Hz'den 5 Hz'e iner. RNNoise, AGC, kalibrasyon,
preset, mute/bypass/limiter ve native callback değişmez. Algılanan süreç
yoksa 15 saniye bekleme ile görsel tercih geri döner. Bilinen oyun Alt+Tab'da
açık kaldığı sürece sade görünüm sürer. FPS kazancı garanti edilmez.

## Doğrulama sınırları

`--smoke`, gerçek mikrofon yerine açıkça adlandırılmış sentetik cihaz ve
sentetik ses örnekleri kullanır. VB-CABLE, fiziksel mikrofon ve kernel aktarımı
açılmaz; normal kullanıcı ayarları yazılmaz. Kalibrasyon uygulama/geri alma,
profil geçişleri, yönlendirme seçimi, animasyon iptali ve gizlenme sınanır.

Tasarım kontrolü iki dilde beş sayfayı ve Ses İşleme'nin üç sekmesini
1160×840, 780×650 ve 640×480 boyutlarında render eder: toplam 42 düzen.
Menü/sekmeler, profil-kalibrasyon-oyun kısayolları ve ayrı ayar uygulama
kapsamları da sınanır. Yatay taşma, kırpılan menü simgeleri, cihaz
seçici genişlikleri, kalıcı kontroller ve menü erişilebilir isimleri denetlenir.
96/144/192 DPI bitmapleri raster ölçekleme kontrolüdür; fiziksel monitör DPI
değişimi veya ekran okuyucuyla kullanıcı testi değildir. Sistem paleti
eşlemesi uygulama kaynaklarında sınanır; Windows yüksek kontrast ayarı
değiştirilmez. `design-result.json` bu sınırları açıkça kaydeder.

Oyun modunda çevrimdışı DSP'nin işlemeyi sürdürmesi gerçek zamanlı akış kabulü
değildir; raporlar `realtimeAudioValidated=false` ve
`liveTransportValidated=false` içerir. Gerçek cihaz testleri ayrıca açıkça
seçilen `--validate-live` modudur. Genel kabul sınırları VALIDATION.md'dedir.

Kompozisyon ve gezinme için incelenen birincil kaynaklar:
[Windows gezinme ilkeleri](https://learn.microsoft.com/en-us/windows/apps/design/basics/navigation-basics)
ve [Audio Hijack ürün sayfası](https://rogueamoeba.com/audiohijack/).
Bu kaynakların görsel/kod varlıkları ürüne kopyalanmadı.
