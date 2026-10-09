# Sürüm notları

[← Veylo](../README.md) · [Yayımlanan sürümler](https://github.com/alperensu/veylo/releases)

Bu belge geliştirme geçmişini korur. Geçmiş ölçümler yalnız belirtildikleri sürüm
ve koşullar için geçerlidir; güncel ürün garantisi değildir. Güncel doğrulama
[VALIDATION.md](VALIDATION.md), özellik kabulü [ACCEPTANCE.md](ACCEPTANCE.md) içindedir.

## 0.7.5-dev — İzole sanal mikrofon laboratuvarı

Dosya tabanlı test imzalama, özel stdio VM yönetimi ve gerçek PCM16/PCM32
capture kabul aracı. Normal ve standart Driver Verifier koşularında 104 kernel
ve 20 ses kontrolü geçti; kaldırma/yeniden kurma sonrası da doğrulandı.
Microsoft üretim imzası, HVCI ve geniş uyumluluk kabulü eksik. Normal Setup
VB-CABLE kullanır. [Sürüm ve sınırlar](https://github.com/alperensu/veylo/releases/tag/v0.7.5-dev).

## 0.7.4-dev — Sürücü geliştirme hazırlığı

Sabit EWDK ile kernel derlemesi, INF/katalog denetimleri, paket bütünlüğü,
ABI5/protokol1 sözleşmesi ve üretim imzası gerektiren kurulum akışı.
[Sürüm](https://github.com/alperensu/veylo/releases/tag/v0.7.4-dev).

## 0.7.3-dev — Hızlı kalibrasyon ve belirgin profiller

2 saniye ortam ve 8 saniye doğal konuşmayla hızlı kişisel ölçüm; isteğe bağlı
20 saniyelik ayrıntılı ölçüm. Seçili ton korunur. Hazır tonlar ayrıştırıldı,
Profiller sayfasına aynı örnekle ham/seçili profil karşılaştırması eklendi.
[Sürüm](https://github.com/alperensu/veylo/releases/tag/v0.7.3-dev).

## 0.7.2-dev — Windows Setup

Kullanıcı hesabına kurulum, Başlat menüsü kısayolu, isteğe bağlı masaüstü
kısayolu; kaldırmada kişisel profil/kalibrasyonların korunması.
[Sürüm](https://github.com/alperensu/veylo/releases/tag/v0.7.2-dev).

## 0.7.1-dev — Daha açık bölüm yerleşimi

Beş ana bölüm, Ses İşleme içinde üç sekme; profil seçimi Profiller'de,
kalibrasyon ve karşılaştırma aynı çalışma alanında toplandı.
[Sürüm](https://github.com/alperensu/veylo/releases/tag/v0.7.1-dev).

## 0.7.0-dev — Veylo çalışma alanı

Açık çalışma yüzeyi, koyu yan menü, bakır vurgu, tutarlı kontroller ve
ölçülen RMS geçmişi. [Sürüm](https://github.com/alperensu/veylo/releases/tag/v0.7.0-dev).

## Önceki geliştirme notları

Aşağıdaki notlar önceki README'den korunmuştur. Sıralama tarihsel kayıt sırasıdır.
## 0.6.0 konuşma kontrolleri
VB-CABLE yönlendirmesi korunur. Ayarlar / Konuşma kontrolü: açık mikrofon,
basılı tutarak konuş veya basılı tutarak sustur. Varsayılan tuş Ctrl+Alt+T.
Uygula ile etkinleştir. Sustur her zaman önceliklidir. PTT kapalı başlar;
tuş çakışırsa açılmaz. Çakışmada eski çalışan kayıtlar korunur. Klavye günlüğü
ve hook yok; sadece seçili Ctrl+Alt+tuş durumu 20 ms aralıkla okunur. Gizli
pencerede çalışır. Gerçek oyun/uyku/kilit ekranı davranışı ayrıca doğrulanmalıdır.

Hazır preset kısayolları isteğe bağlı Ctrl+Alt+1…5: Doğal, Net Konuşma,
Sıcak Ses, Yayın, Podcast; kayıt/kalibrasyon sırasında devre dışıdır.
Gürültü / Giriş duyarlılığı: mevcut kapatma modu veya yeni yumuşak expander;
açılma, bekleme, kapanma, kapanma eşiği farkı, oran ve azami azaltma.
Expander insan sesi ayırma modeli değildir. Varsayılan presetler değişmedi;
eski JSON dosyaları yeni alanların koruyucu varsayılanlarıyla yüklenir.
Uygulama ve native DLL ABI5 birlikte kullanılır; eski DLL ile karıştırma.
Kernel sürücüsü protokolü 1 korunur; bu pakete sürücü eklenmez. AI ses
restorasyonu, yankı iptali, soundboard ve çok kanallı mixer dahil değildir.

## 0.6.1 — klavye için güçlü temizleme
Gürültü Azaltma / Güçlü temizlemeyi uygula, mevcut ton ve dengeleme ayarlarını
koruyarak RNNoise karışımını %100 yapar; otomatik güç kapatılır, otomatik eşikli
yumuşak expander eklenir. Orijinal ses kapanır; Sustur korunur. Kayıt/kalibrasyon
sırasında uygulanmaz. %65 karışımda ham mikrofonun %35'i çıkışa geri eklenir;
otomatik mod da ham yol bırakır. Güçlü temizleme bu geri karışımı kaldırır.
Açılışta --strong-clean aynı ayarı yükler ve normal kullanıcı ayarlarına kaydeder;
varsayılan açılış kendi başına mevcut ayarlarını değiştirmez. Eski presetler
korunur. Gürültü Azaltma kontrollerinden önceki seçenekleri tekrar seçebilirsin.
RNNoise bütün klavyeleri veya konuşurken yapılan her tuş vuruşunu silemez;
yakındaki diğer insan seslerini ayırma garantisi yoktur. Kullanılan uygulamanın girişi CABLE
Output olmalıdır. Gerçek dinleme ve sessiz kelime koruması kullanıcı ortamında
ayrıca kontrol edilmelidir.

## 0.6.3: Ani gürültü ve akış tanısı

Sabit RNNoise v0.2 modeli, resmi bb18d2f değişikliğindeki enerjiye göre kazanç
geçmişi düzeltmesiyle kullanılıyor. Bazı ani gürültülerin sızıntısını azaltabilir;
masa darbelerini tamamen kesme garantisi vermez. Ek model, GPU veya ses bloğu
gerektirmez. Ses aktarımı paket zamanlamasıyla sınanan saat farkı dengelemesi ve
bir örnek hizalama gecikmesi olan interpolasyon kullanır. Geliştirici tanısı
callback boyutlarını/aralıklarını, gerçek tampon hatalarını ve CPU/bellek
hedeflerini raporlar. Oyun algılayıcısının bellek tahsisi azaltıldı. Eski ayarlar
ve cihaz kalibrasyonları uyumludur.

Gerçek masa darbesi/konuşma dinlemesi, uçtan uca gecikme ve oyun performansı
kabulü tamamlanmadı. Ölçüm yapılan gizli koşularda150MB çalışma belleği hedefi
aşıldı; bu paket geliştirme çıktısıdır.

## 0.6.4: Otomatik yumuşak duyarlılık

Güçlü temizlemeyi uygula seçeneğiyle, konuşma algılanmayan yüksek sesler
yumuşak azaltmayı açamaz veya konuşma bekleme süresini yenileyemez.
Bu davranış gürültü azaltma + otomatik duyarlılık + expander açıkken çalışır.
Modelin konuşma sandığı masa darbeleri yine geçebilir; gerçek sessiz kelime
başlangıçlarını Önce/sonra ile dinleyerek kontrol et. Bu sürüm masa darbesi
sorununun tamamen çözüldüğü veya günlük kullanım testlerinin bittiği anlamına gelmez.

## 0.6.5: Callback boyuna göre aktarım rezervi

VB-CABLE aktarımında tampon hedefi artık çıkış callback boyunu hesaba katar;
varsayılan ayarda render sonrasında ortalama 15 ms rezerv hedeflenir. Saat
düzeltmesinin hata ölçeği 10 ms giriş paketine bağlıdır. Bu, zamanlama
oynamaları ve büyük callbacklerdeki boşalma riskini azaltır. Hesaplanan
gecikme uçtan uca ölçüm değildir; 40 ms hedefi henüz doğrulanmadı.

## 0.6.6: Oyun algılamada daha az bellek tahsisi

Oyun algılama politikası artık her arka plan işlemi için geçici bir sorgu
oluşturmuyor. Özel oyun adları ve `.exe` eşleşmesi, tam ekran istisnaları ve
15 saniyelik bekleme davranışı korunuyor. 350 işlemli kontrollü karşılaştırmada
politikanın tarama başına tahsisi yaklaşık 42 KB'den 32 bayta indi; bu ölçüm
uygulamanın toplam bellek kullanımı değildir. Ses motoru bu sürümde değişmedi.

0.6.5'in 10 dakikalık gerçek mikrofon → VB-CABLE koşusunda tampon hatası yoktu,
CPU yaklaşık %0,20 idi; en yüksek çalışma belleği 151,6 MB ile 150 MB hedefini
aştı. Gürültü temizliği, gerçek uçtan uca gecikme ve oyun kabulü henüz tamamlanmadı.

## 0.6.7: Hafif oyun taraması ve kısa çıkış periyodu

Oyun taraması artık tüm süreçler için metin ve gözlem listeleri oluşturmadan
ilk eşleşmeyi buluyor. Aynı .NET 10.0.11 üzerinde 394 süreçli karşılaştırmada
tarama ve politika tahsisi 58.912 bayttan 32 bayta indi; özel eşleşmede 144 bayt
ölçüldü. UI görev maliyeti ve toplam uygulama belleği bu ölçüme dahil değildir.
Özel oyun listesi tarama sırasında değişirse yeni listeyle tekrar kontrol edilir.

Ses motoruna istenen cihaz periyodu 5 ms oldu; 20 ms tampon rezervi korunuyor.
Bu bilgisayarda USB giriş 10 ms, VB-CABLE çıkış 5 ms periyotla çalıştı.
10 dakikalık sessiz aktarım denemesi sıfır tampon hatasıyla tamamlandı.
Desteklenen gerçek periyot cihaza bağlıdır; bu bir 40 ms gecikme garantisi değildir.

0.6.6'nın bir saatlik ölçümünde sıfır tampon hatası ve yaklaşık %0,16 CPU görüldü;
152,0 MB en yüksek çalışma belleği 150 MB hedefini aştı. Bu ölçüm tanı araçları
açıkken yapıldı. 0.6.7 için bellek, gerçek konuşma ve oyun kabulü ayrıca gereklidir.

## 0.6.8: Açılış hedefinin yenilenmesi ve bellek tanısı

Yeni Veylo açıldığında Windows ile başlatma tercihi zaten açıksa, tanınan eski
eski SES.exe veya Veylo.exe hedefi mevcut sürüme yenilenir. Kapalı tercih açılmaz; daha yeni bir
sürümün kaydı eski sürüme indirilmez. Açık olan diğer Veylo süreci kapatılmaz.

Geliştirici için düşük yüklü ölçüm modu eklendi: `--validate-live
--validate-low-overhead --validate-cable --validate-duration-seconds 600
--minimized --out <klasör>`. Bu mod kendi mikrofon katkısını başlangıçtan önce
susturur; ses kaydı yazmaz. Normal kullanıcı arayüzü ve ses işleme ayarları değişmez.
Ölçüm 1 Hz, tanı kaydı 30 saniyede bir alınır; işletim sisteminin süreç boyunca
gördüğü bellek zirvesi de korunur. Bu, normal kullanımın kesin RAM ölçümü değildir.

Önceki 0.6.7 uzun koşusu bilgisayar kapatıldığında yaklaşık 48. dakikada kesildi.
Son örnekte tampon hatası yoktu; bir saatlik test tamamlanmış sayılmaz.
