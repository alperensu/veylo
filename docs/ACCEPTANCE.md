# Veylo kabul durumu — 2026-10-10

Bu tablo ürünün tamamlandığı iddiası değildir. **Passed** yalnızca belirtilen
kontrolün geçtiğini; **Partial** uygulama ve bazı testler bulunmasına rağmen
kabulün eksik olduğunu; **Not run** ilgili gerçek koşulun denenmediğini belirtir.
Güncel geliştirme paketi: **0.7.5-dev**. Ayrıntılı geçmiş: [VALIDATION.md](VALIDATION.md).

**Güncel kullanıcı geri bildirimi:** 8 Ekim 2026'da kullanıcı, seslerin şu an
temizlendiğini ve sorun olmadığını bildirdi. Kendi mevcut kurulumu için gürültü
temizliği kullanıcı tarafından doğrulandı; kullanılan build/preset veya ayrı
sessiz konuşma/masa darbesi protokolü belirtilmedi. Bu yüzden tüm cihazlara
genellenmiş bir test sonucu olarak kullanılmaz.

**Ürün kapsamı:** Veylo genel bir mikrofon/ses iyileştirme aracıdır. Kayıt, yayın,
toplantı, iletişim ve oyun kullanımları aynı temel ses yolunun farklı tüketicileridir.
Discord ve Valorant yalnızca uyumluluk örnekleridir; bu iki uygulamanın denemesi
çekirdek gürültü temizleme kabulünün zorunlu kapısı değildir. Ekran paylaşımı ve
oyun modu gibi özel özellikler kendi koşullarında ayrıca değerlendirilir.

| Alan | Durum | Doğrulanan kapsam ve kalan kontrol |
| --- | --- | --- |
| Kendi sürücü: güncel 0.5.4.0 | Findings — uzun kabul açık | Sınırlı capture paket kuyruğu, değişmeyen first-sample zamanları ve üretici oturum izolasyonu eklendi. WDK/INF/katalog, sekiz Release ve sekiz ASan grubu, 269 gerçek kernel kontrolü ve iki bağımsız inceleme geçti. 60 saniyelik normal ürün aktarımında 36 kontrol geçti; iki ortak WASAPI istemcisinde paket/zaman hatası ve normal akış underrun sıfırdı. Ardından istenen bir saatlik koşu 33,415 saniyede bir normal akış underrun ile başarısız oldu; tamamlanan saat sayılmaz. Güncel sürümün son yaşam döngüsü, etkin HVCI, fiziksel mikrofon/ayrı alıcı uygulamalar ve Microsoft üretim imzası açık. Kullanıcı Hardware Dev Center/Partner Center hesabı ve EV sertifikası bulunmadığını doğruladı. [Son sürüm kapıları](DRIVER-RELEASE.md), [güncel kanıt](VALIDATION.md). |
| Otomatik başlama, gizlenme, çıkış | Partial | Önceki canlı kontroller ve kapanış regresyonları mevcut. 0.6.11'de gerçek Quit metodu, bekleyen sentetik çevrimdışı render sırasında pencereyi, native handle'ı ve Application'ı kapattı. Gerçek bildirim alanı tıklaması, uyku/uyanma ve etkin cihaz kapatma kabulü bu testin kapsamı dışındadır. |
| VB-CABLE yönlendirmesi | Partial | CABLE Input seçimi, kayıtlı cihazı koruma ve güvenli yerel çalışma politikası testli; 0.6.8'de susturulmuş gerçek cihaz akışı ölçüldü. Farklı kayıt/toplantı/yayın/iletişim uygulamalarıyla uyumluluk kapsamı henüz tamamlanmadı. |
| Cihaz kaybı ve geri dönüş | Partial | Kimlik/seçim politikalarının regresyonları mevcut. Fiziksel çıkarma/yeniden bağlama, 44,1 kHz cihaz ve ikinci bilgisayar denemeleri Not run. |
| RNNoise, dengeleme, EQ ve dinamik işlemler | Partial | Sayısal güvenlik, limiter, sessizlikte kazanç ve ayar sınırları için sentetik kontroller mevcut. Sessiz Türkçe konuşma, cümle başlangıçları, fan/klavye/masa darbesi dinleme kabulü bekliyor. |
| Otomatik gürültü, duyarlılık ve güçlü temizleme | Partial — kullanıcı doğrulaması var | Kontroller ve sınır testleri mevcut. Kullanıcı mevcut kurulumunda seslerin temizlendiğini ve sorun olmadığını bildirdi. Farklı mikrofonlar ve ayrı sessiz konuşma/masa darbesi senaryoları genel kabul için ayrıca doğrulanmalı; belirli bir uygulamanın testi bu kullanıcı sonucunun ön koşulu değildir. |
| Beş hazır preset ve kişisel kalibrasyon | Partial | 0.7.3-dev: hızlı 10 saniye / isteğe bağlı ayrıntılı 20 saniye, seçili tonu koruma, native DSP ile RMS eşlenmiş profil ayrımı, clipping/sessizlik reddi ve geri alma testli. Gerçek sesle önerilerin kalitesi ve tok/net Podcast profilinin dinleme kabulü bekliyor. |
| Profil kaydetme/içe aktarma | Passed | İzole WPF regresyonunda yazma/atomik değiştirme hataları başarı olarak gösterilmiyor; yeniden yükleme, tekrar deneme ve kopya oluşturmama doğrulandı. Gerçek kullanıcı ayarı değiştirilmedi. |
| A/B karşılaştırma ve WAV dışa aktarma | Partial | Çevrimdışı render, ses eşleme, WAV kodlama ve çıkış sonrası sonuç yayımlamama testli. Fiziksel oynatma ve dosya seçim penceresi kabulü Not run. |
| Sustur, orijinal ses ve konuşma modları | Partial | Durum/parametre ve limiter regresyonları mevcut. Kullanılan alıcı uygulamada fiziksel tuş basma ve konuşma davranışı kabulü bekliyor; oyun olası kullanım örneklerinden biridir. |
| Genel kısayollar | Partial | Önceki Windows smoke testinde gerçek RegisterHotKey kayıt/çakışma/geri alma kontrolü geçti; enjekte edilen kayıtçı testleri de mevcut. Fiziksel tuş, kilit ekranı ve oyun kabulü Not run. |
| Oyun modu | Partial | Oyun/tam ekran algılama politikası ve kontrollü görsel iş azaltma testleri mevcut. Gerçek oyun yükünde FPS, yüzde 1 düşük FPS ve frametime ölçümü Not run. |
| Ekran paylaşımında çift mikrofon sesi | Not run | Tüm ekran ve sistem sesi paylaşımıyla gerçek Discord denemesi yapılmadı. VB-CABLE'a yönlendirme tek başına Discord paylaşımının mikrofonu ikinci kez almadığını kanıtlamaz. Açık karşılaştırma oynatımı veya Windows mikrofon dinleme özelliği ayrıca duyulabilir. |
| Türkçe/İngilizce erişilebilirlik | Partial | 0.6.11'de gerçek WPF automation peer nesneleriyle ölçer, ilerleme ve EQ adları iki dilde doğrulandı. Görsel XAML düzeni değişmedi. Gerçek Narrator ve yüzde 150/200 ekran geçişleri Not run. |
| CPU ve bellek | Partial | 0.6.8'in 3.600,688 saniyelik düşük ölçüm yüklü, susturulmuş koşusu tamamlandı: CPU yüzde 0,174048; OS ömür boyu tepe çalışma kümesi 148.312.064 bayt; tampon hatası sıfır, çıkış kodu 0. Bu normal ürün başlangıcı ölçümü değildir; önceki 150 MB sınırı aşan koşular geçersiz sayılmaz. Ayrı normal 0.6.10 gözleminde 119 örnek yalnızca görünür pencereyi kapsadı; gizli kullanım hedefi değerlendirilmedi. |
| Ek gecikme en fazla 40 ms | Not run | Fiziksel uçtan uca/diferansiyel ölçüm yok. Tampon hesapları ve sentetik saat testleri fiziksel gecikme kabulü yerine geçmez. |
| Paket, lisans ve güvenlik | Partial | Kaynak/paket bütünlüğü, bağımlılık sabitleme ve değişiklik bazında bağımsız kod/güvenlik incelemeleri mevcut. Bunlar kernel/laboratuvar veya tam ürün güvenlik garantisi değildir. dailyUseReady=false. |
| Kendi Veylo Mikrofon sürücüsü | Partial — kernel, capture, S4 ve sürüm geçişi geçti | 0.5.1 sürücüsü sabitlenmiş EWDK ile derlendi; InfVerif/Inf2Cat, test imzası ve 104 IOCTL kontrolü doğrulandı. Etkin Driver Verifier + Kod Bütünlüğü ile BIOS ve UEFI ortamlarındaki 60 saniyelik güncel capture koşuları 33 kontrolü geçti; aynı süreçte iki WASAPI istemcisi, yeniden bağlantı ve taze sessizlik doğrulandı. Gerçek S4 hazırda bekletme/uyanma aynı boot ve oturumla eşleşti; dönüşte PCM16/PCM32 capture 22 kontrolü geçti. HVCI açılışı hem BIOS hem UEFI guest Windows içinde 0xc0000189 sistem yeteneği hatasıyla engellendi; başarısız diskler korundu ve sağlam test yedekleri geri yüklendi. Bu, sürücüye özgü bir bugcheck kanıtı değildir. Aynı VM ve özgün koşuda 0.5.0 → 0.5.1 → gerçek DiRollbackDriver ile 0.5.0 → 0.5.1 geçişi Passed olarak tamamlandı; dört ayrı capture aşamasının her biri PCM16/PCM32 ile 20 kontrolü, sıfır hatayla geçti. Native kimlik ve INF/SYS hash'leri doğrulandı; WMI bilgisinin eski kaldığı tarihsel deneme korundu. NO_UI geri alma çağrısı exit 0 verdi; son güncel sürüm kurulumunun istediği yeniden başlatmadan sonra açık Resume ve yeni capture ile güncel sürümün geri yüklendiği doğrulandı. Önceki başarısız denemelerin kayıtları korundu. Önceki tanı kayıtlı bir saatlik deneme 503,706 saniyede bir normal akış tampon boşalması ve 173 sessiz frame ile başarısız oldu; önceki 632,893 saniyelik başarısızlık da korundu. Hata öncesi kayıtta son yazmadan beri geçen 21,331 ms mevcut ses rezervini aşmıştı; zamanlama gecikmesinin nedeni ve tam ürün yolu henüz doğrulanmadı. Microsoft üretim imzası, etkin HVCI, bir saatlik kabul, ayrı alıcı uygulamalar ve tam fiziksel mikrofon yolu tamamlanmadı. [Genişletilmiş kabul araçları](DRIVER-ACCEPTANCE.md). Günlük makinenin güvenlik ayarları değiştirilmedi; VB-CABLE bu sürücüyü gerektirmez. |

Sürücü 0.5.2 tarihsel geliştirme durumu: WDK/INF/katalog kontrolleri, Release/ASan testleri
ve bağımsız kod/güvenlik incelemeleri geçti. Gerçek ürün bridge'iyle, etkin Kod
Bütünlüğü Verifier altında hem 60 saniyelik normal koşu (36 kontrol) hem ayrı
kernel tanılı koşu (37 kontrol) sıfır tampon boşalmasıyla geçti. Önceki aralıklı
hataların kök nedeni çözülmüş sayılmaz; bir saatlik kabul hâlâ açık.
Son 0.5.2 saatlik istek 197,207 saniyede, tampon boşalması olmadan bir adet
10 ms ses paketi atlamasıyla başarısız oldu. 0.5.3'te ayrı bir zaman damgası
sözleşme hatası düzeltildi; WDK/INF/katalog, Release/ASan ve iki bağımsız
inceleme geçti. Bu düzeltme paket atlamasının çözümü sayılmıyor.
0.5.3 gerçek kernel testinde 269 kontrol ve normal ürün yolu üzerinden
60,010 saniyelik capture koşusunda 36 kontrol geçti; paket atlaması,
normal akış tampon boşalması ve kuyruk kaybı sıfırdı. Bu kısa ve sentetik
test, bir saatlik veya fiziksel mikrofon kabulünün yerine geçmez.
[Güncel kanıt ve sınırlar](VALIDATION.md).

Mevcut ölçüm bilgisayarı: Windows 11 Home, 10.0.26300; Ryzen 5 7600,
6 çekirdek/12 mantıksal işlemci. Bu bilgi Windows 10, farklı mikrofonlar veya
daha düşük güçlü ikinci sistem uyumluluğu iddiası değildir. Ses kaydı bu rapora
ve paylaşılan presetlere eklenmez. Genel cihaz/performans kabulü tamamlanmadan
"tüm özellikler sorunsuz" veya "günlük kullanıma hazır" sonucu verilmez.
