# Veylo — VB-CABLE ile genel kullanım

Bu sürüm VB-CABLE yönlendirmesini geri getirir. Kendi Veylo sürücümüzün imzalanmasını
beklemeden VB-CABLE ile kullanılabilir; VB-CABLE pakete dahil değildir.
Veylo Mikrofon geliştirme seçeneği hâlâ imzalı sürücü gerektirir: [DRIVER.md](DRIVER.md).

1. ZIP'in tamamını çıkar; eski Veylo örneğini bildirim alanından Veylo'dan çık ile kapat.
2. Veylo.exe aç. Kayıtlı mikrofon, preset ve kalibrasyon korunur; işleme otomatik başlar.
3. Ana ekranda Mikrofon fiziksel mikrofonun; Çıkış CABLE Input (VB-Audio Virtual Cable) olsun.
4. Kayıt, yayın, toplantı veya sesli iletişim uygulamanda mikrofon/giriş aygıtını
   **CABLE Output** seç. Uygulamanın ses çıkışı kendi kulaklığın olsun.
5. Veylo'nun etkisini karşılaştırırken kullanılan uygulamadaki ek gürültü azaltma ve
   otomatik kazanç işlemlerini varsa kapat.

Örnek: Discord'da Ses ve Görüntü → Giriş aygıtı, Valorant'ta mikrofon seçimi
**CABLE Output** olabilir. Veylo'nun kullanımı bu iki uygulamayla sınırlı değildir;
uyumluluk ve aygıt seçimi kullanılan uygulamaya göre ayrıca kontrol edilir.

VB-CABLE yoksa [resmî indirme sayfasından](https://vb-audio.com/Cable/) kur,
gerekirse Windows'u yeniden başlat; Veylo'da Cihazları yenile seç. Eksik kabloda
aktarım kapalı olarak gösterilir ve yerel işleme devam eder. Kayıtlı mikrofon veya
kablo kaybolduğunda başka cihaza otomatik geçilmez. Hoparlör çıkışı seçilemez.
Çıkış listesindeki Yalnızca yerel işleme kalibrasyon içindir; uygulamalara aktarmaz.
Veylo Mikrofon seçeneği yalnızca kendi sürücümüz kurulu/uyumlu olduğunda aktarır.
Windows ve kullanılan uygulamaların varsayılan cihazları Veylo tarafından değiştirilmez.

Alt alanda durum, Sustur ve Orijinal ses bulunur; Başlat/Durdur yoktur.
Orijinal ses bypass yapar; susturma ve −1 dBFS güvenlik limiter'i korunur.
Ctrl+Alt+M susturma, Ctrl+Alt+B bypass; çakışırsa Tercihler'den değiştir.
X düğmesi bildirim alanına gizler; işleme sürer. Tam kapatmak için Veylo'dan çık kullan.
Windows ile başlatma isteğe bağlıdır; gizli açılışta da işleme başlar.

## Görsel efektler ve oyun modu

Üstteki Oyun modu düğmesi Ayarlar bölümünü açar. Otomatik mod varsayılan açık.
Bilinen oyunlar, diğer tam ekran uygulamalar ve kaydettiğin süreç adları5s'de
bir kontrol edilir. Oyun algılanınca geçiş, hover/press, anahtar animasyonları,
cam görünümü ve canlı ses görseli durur; seviye ölçerler5Hz olur. Ses işleme,
susturma ve kısayollar sürer. Oyundan çıkınca efektler yaklaşık15–20s'de döner.

Animasyonlar ve cam efektleri anahtarı tüm görsel efektleri elle kapatır.
Windows animasyonları kapalıysa uygulama da animasyon yapmaz; cam tasarımı
korur. Windows11: Ayarlar → Erişilebilirlik → Görsel efektler → Animasyon
efektleri. Veylo bu Windows ayarını kendiliğinden değiştirmez.

Algılanmayan oyun için Görev Yöneticisi → Ayrıntılar'daki .exe adını Ek oyun
süreçleri alanına gir, Listeyi kaydet. Virgülle en fazla20 ad eklenebilir;
örneğin MyGame.exe, javaw.exe. javaw tüm Java uygulamalarını eşleştirebilir.
Tarayıcılar/başlatıcılar tam ekran algılamada hariç tutulur. Bilinmeyen tam ekran
uygulama oyun sayılabilir; otomatik modu kapatarak veya listeyi düzenleyerek
kontrol et. Uygulama oyunlara müdahale/injection yapmaz ve FPS artışı vaat etmez.

## Sesine ayarlama

Dinle ve Kalibre Et → Sesime göre otomatik ayarla: 5 saniye sessizlik,
7 saniye normal, 4 saniye hafif, 4 saniye yüksek konuşma. Mesafeyi sabit tut.
Clipping, yetersiz konuşma veya kirli ortam örneğinde öneri reddedilir.
Önerilen temizleme, dengeleme, EQ ve kompresörü önce dinle, sonra uygula.
Kalibrasyon/karşılaştırma bittiğinde günlük işleme kapanmaz. Kişisel ayarlar
mikrofon bazında saklanır; Cihaz ayarını yükle ve son öneriyi Geri al bulunur.
Preset kalibrasyonu silmez. Windows mikrofon seviyesi değiştirilmez.

Doğal, Net Konuşma, Sıcak Ses, Yayın ve Podcast — Tok ve Net hazırdır.
Podcast dolgun/net ton, güçlü temizleme ve otomatik duyarlılık uygular.
Hafif kelimeleri kulaklıkla kontrol et; tüm dış seslerin yok olması veya
herkeste aynı ton garanti edilmez. Donanımsal dalgalanmanın nedeni doğrulanmadı.

Gürültü Azaltma: manuel/otomatik güç. Giriş duyarlılığı ayrı isteğe bağlı
manuel eşik/otomatik ortam kontrolüdür. Ses Dengeleme hedefi/kazanç sınırları;
Ses Kalitesi dört bant EQ, de-esser ve kompresör içerir.

## Karşılaştırma ve gizlilik

En fazla 20 saniyelik örnek RAM'de tutulur. Önce/sonra gecikmeye göre hizalanır
ve aynı ses yüksekliğine getirilir. Yalnızca WAV dışa aktarımı ses dosyası yazar.
Paylaşılan JSON profilleri cihaz kimliği veya ses içermez. Eski profiller ve
%LOCALAPPDATA%\SES\state.json korunur.

VB-CABLE yolunda sürekli işlenmiş ses yalnızca CABLE Input sanal oynatma cihazına
verilir; fiziksel hoparlöre yönlendirilmez. Windows varsayılan çıkışını CABLE Input
yapma; CABLE Output için Bu aygıtı dinle kapalı olsun. Açıkça oynattığın
karşılaştırma veya Windows'ta Bu aygıtı dinle özelliği açıkken duyulan ses,
ekran + sistem sesi paylaşımında ikinci kez gidebilir. Dinlemeyi kapat,
karşılaştırmayı bitir. Kullanılan uygulamanın çıkışı kendi kulaklığın olmalı.
Karşılaştırmada bu uygulamalardaki ek gürültü azaltma/otomatik kazancı kapat.

## Hata durumları

* Mikrofon yok/bağlantı kesildi: aynı cihazı bağla veya yeni cihazı açıkça seç.
* İzin hatası: Veylo sürücüsü bölümünden Windows mikrofon izinlerini aç; masaüstü
  uygulamalarına izin ver. Başka uygulamalarda özel mikrofon kullanımını kontrol et.
* Sürücü yok/uyumsuz/erişim reddi/meşgul: Veylo sürücüsü bölümündeki rehberi aç.
  Bu uyarı Veylo Mikrofon seçeneğine aittir; VB-CABLE için Çıkış listesinden CABLE Input seç.
* Yardımcı gerekirse yönetici izni ve yeniden başlatma gereğini gösterir;
  kendi başına yeniden başlatmaz. Günlük Veylo yönetici istemez.

Gecikme alanı hesaplanan tampon gecikmesidir; uçtan uca ölçüm değildir.
Doğrulanan kapsam: [VALIDATION.md](VALIDATION.md).

## Konuşma modları ve kısayollar
Ayarlar / Konuşma kontrolü altında modu ve Ctrl+Alt+harf tuşunu seç, Uygula.
Basılı tutarak konuş sesini sadece tuş birleşimi basılıyken iletir; Sustur
bütün modlardan önceliklidir. Orijinal ses konuşma kontrolünü atlamaz.
Preset kısayollarını ayrıca etkinleştir: Ctrl+Alt+1…5. Tuş çakışması varsa
önceki ayarlar korunur; farklı bir harf seç. İlk açılışta PTT tuşu kayıt edilemezse
mikrofon kapalı kalır. Modlar paylaşılabilir preset dosyasına eklenmez.
