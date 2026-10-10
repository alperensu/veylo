# VB-CABLE ile ses kalitesi ve profil karşılaştırması

VB-CABLE, Veylo'nun işlediği sesi başka uygulamalara taşır. Ton, EQ, ses
dengeleme, de-esser, kompresör ve gürültü azaltma için Veylo'nun kendi sanal
mikrofon sürücüsünü beklemek gerekmez.

## Doğru sinyal yolu

1. Veylo'nun **Mikrofon** alanında fiziksel mikrofonunu seç.
2. Veylo'nun çıkışında **CABLE Input (VB-Audio Virtual Cable)** seçili olsun.
3. Sesi alan uygulamanın mikrofonu **CABLE Output (VB-Audio Virtual Cable)** olsun.
4. Veylo'daki **Orijinal ses** kapalı olsun. Açıkken EQ ve diğer profil
   işlemleri canlı çıkışta atlanır; susturma ve güvenlik limiter'i korunur.

Yalnız “VB-Audio Virtual Cable” adı, bağlantının iki ucunu ayırt etmez.
Uygulamada hangi girişin seçildiğini **CABLE Output** adıyla kontrol et.
Windows'un veya diğer uygulamaların varsayılan cihazları Veylo tarafından
değiştirilmez.

## Ses karakterini seçmek

| Profil | Amaçlanan karakter |
| --- | --- |
| Doğal | Düz EQ; mikrofonun kendi karakterini korur. |
| Net Konuşma | Alt tonları azaltır; konuşma ayrıntısını öne çıkarır. |
| Sıcak Ses | Dolgun alt tonlar; daha yumuşak üst tonlar. |
| Yayın | Dolgunluk, parlak üst tonlar ve daha sıkı dinamikler. |
| Podcast — Tok ve Net | Dolgunluk, azaltılmış boğukluk ve Yayın'a göre yumuşak üst tonlar; güçlü temizleme. |

Tok ve net ses için Podcast iyi bir başlangıç denemesidir. Güçlü temizlemenin
konuşma ayrıntısını etkileyip etkilemediğini kendi mikrofonunla dinle. Gürültü
azaltma miktarı ile ton karakteri ayrı ayarlardır; güçlü temizleme düğmesi
mevcut EQ'yu korur. Hazır profili seçmek veya yeniden uygulamak ise profilin
gürültü ve seviye ayarlarını da yükler.

Kalibrasyonun hızlı ölçümü mevcut tonu koruyarak ortam ve seviyeyi uyarlar.
Kişisel ayarlarını kaydet; hazır profil güncellemesi veya yeniden uygulama
sana ait kaydedilmiş profilleri değiştirmez.

## Profiller aynı duyuluyorsa

- **Orijinal ses uyarısını** kontrol et. Bu durumda “İşlenmiş sese dön”
  canlı çıkışta profil işlemlerini tekrar etkinleştirir; susturmayı kaldırmaz.
- Profil adının yanında **Değiştirilmiş profil** görünüyorsa etkin ayarlar seçili
  profilin kayıtlı değerlerinden farklıdır. “Seçili profili yeniden uygula”
  aynı profil zaten seçili olsa bile onun ayarlarını yükler.
- **Kalibrasyon ve Test** bölümünde kısa bir konuşma örneği al. **Profiller**
  bölümünden Doğal, Net Konuşma ve Sıcak Ses'i aynı örnekte karşılaştır.
  Orijinal/işlenmiş karşılaştırması ses seviyesini eşler; sürekli hoparlör
  dinlemesi başlatılmaz. Kulaklık kullan.
- Karşılaştırma sırasında alıcı uygulamanın ek gürültü azaltmasını, otomatik
  kazancını ve ses efektlerini geçici olarak kapatıp yeniden dinle. İki ayrı
  işlem zinciri özellikle seviye ve dinamik farklarını değerlendirmeyi zorlaştırabilir.

Bir kayıt alınmadan veya alıcı uygulama kontrol edilmeden dış uygulamadaki
farksızlığın nedeni kesin olarak belirlenemez. Profiller herkeste aynı ölçüde
duyulacak veya mikrofon donanımının eksik ayrıntısını geri getirecek garantisi yoktur.

## Doğrulama kapsamı

Otomatik çevrimdışı testler dört bant EQ'nun native motora ulaşmasını, RMS
eşlenmiş profil spektrumlarının farklı olmasını ve aynı motor üzerinde
art arda profil güncellemelerinin hedef tona ulaşmasını kontrol eder.
Bypass'ın ton işlemlerini atlaması, işlemeye dönüş, susturma ve −1 dBFS
limiter sınırı da test edilir. WPF regresyonları kayıtlı ayarların
korunmasını ve profil/Orijinal ses durumlarının doğru gösterilmesini kontrol eder.

Bu testler sentetik sinyal kullanır; insan sesiyle dinleme, canlı VB-CABLE
aktarımı veya belirli bir alıcı uygulamanın ses kalitesi için başarı kanıtı değildir.
