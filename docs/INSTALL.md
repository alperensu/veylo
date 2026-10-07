# Kurulum

ZIP'i kalıcı klasöre tamamen çıkar, SES.exe aç. .NET ayrıca gerekmez.
Windows10/11x64 hedefleniyor; doğrulanmış cihazlar/sürümler VALIDATION.md'de.
Fiziksel mikrofonunu seç. T732 bu bilgisayarda `Mikrofon (3- USB PnP Audio
Device)` olarak görünüyor; ayarlar modele özel değildir.

**Kalibrasyon:** ilk5sn konuşma, sonraki10sn normal sesle konuş. Günlük fan/oda
ortamını kullan. Clipping varsa mikrofon kazancını/Windows seviyesini elle azalt.
SES bunu değiştirmez. Yetersiz konuşma varsa kalibrasyon uygulanmaz.
**Örnek kaydet:** en fazla20sn RAM'e alır, tekrar basınca erken biter. Kulaklıkla
ham/işlenmiş karşılaştır; yüksekliği eşitlenir. Örnek kapanınca silinir.
**WAV dışa aktar** açıkça dosya oluşturur.

## Discord ve Valorant

VB-CABLE pakete dahil değildir. [Resmi indirme sayfasından](https://vb-audio.com/Cable/)
indirip üreticinin kurulum talimatını uygula; üretici yeniden başlatmayı ister.

```text
Fiziksel mikrofon → SES → CABLE Input (çalma cihazı)
Discord / Valorant mikrofon seçimi → CABLE Output (kayıt cihazı)
```

SES'te yenile, çıkış CABLE Input seç, işlemeyi başlat. Discord giriş CABLE Output,
çıkış kulaklık; karşılaştırmada Krisp/gürültü azaltma ve otomatik kazancı kapat.
Giriş duyarlılığının sessiz kelimeleri kesmediğini kontrol et. Valorant sesli
sohbet girişi CABLE Output, çıkışı kulaklık. İkisi aynı işlenmiş girdiyi kullanır;
canlı eşzamanlı oyun testi henüz yapılmadı. Windows CABLE Gelişmiş özelliklerinde
48kHz seç; gerekirse özel modu kapat.

Sürücü yokken Yalnızca yerel test aktarım yapmaz; ana ekran bunu gösterir.
Hoparlörü SES çıkışı olarak kullanmak geri besleme yaratabilir; aktarım için
CABLE Input seç.

## Günlük kullanım

* Doğal düz EQ/hafif işleme; Net Konuşma açıklık; Sıcak Ses alt tonlar; Yayın
  sıkıştırma/en fazla3dB de-esser. Ayrıntılar Gelişmiş bölümünde düzenlenir.
* Gürültü azaltma/dengeleme bağımsızdır. Sessizlikte kazanç büyümez; sert gate
  yoktur. Bypass sırasında susturma ve güvenlik limiter'i korunur.
* Kapat/minimize tray'e gizler; işleme sürer. Çift tıkla aç, tray Çıkış ile bitir.
* Ctrl+Alt+M sustur / Ctrl+Alt+B bypass. Çakışmada farklı iki harf seçip uygula.
* Windows başlangıcı isteğe bağlı ve kullanıcı bazındadır; gizli açılır,
  mikrofonu kendiliğinden başlatmaz.
* Cihaz çıkarılınca sessizlik; aynı cihaz geri gelince bağlanır, başka mikrofon
  seçmez. Eski cihaz yoksa yeni cihazı açıkça seç.
* Yerel ayarlar `%LOCALAPPDATA%\SES\state.json`; cihaz bazlı kalibrasyon.
  Paylaşılan JSON sadece ayardır;64KB/sürüm/derinlik/sonlu parametre sınırları
  ve dört EQ bandı doğrulanır. Profil değişimi kalibrasyonu silmez.

Mikrofon dalgalanmasının donanımsal nedeni doğrulanmadı. Giriş/çıkış/kazanç
ölçerlerini karşılaştır. Clipping veya eksik ses yazılımla geri getirilemez.
Gecikme alanı tampon hesabıdır; fiziksel uçtan uca ölçüm ayrı test gerektirir.
