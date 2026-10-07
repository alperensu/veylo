# SES 0.1.0 doğrulama — 2026-10-07

Bu dosya ölçülen sonuçları ve bekleyen testleri ayırır. Performans hedefi,
gerçek uçtan uca gecikme veya oyun FPS sonucu olarak gösterilmez.

| Ortam/cihaz | Durum |
|---|---|
| Windows11 Home x64,10.0.26300, Ryzen5 7600,32GB RAM | Yerel build/UI/capture doğrulandı |
| USB PnP Audio Device (kullanıcının Fifine T732'si) | WASAPI48kHz mono canlı capture/2sn RAM örneği doğrulandı |
| G435 / Iriun / Realtek / ekran çıkışları | Listeleniyor; işleme/dinleme test edilmedi |
| Windows10 x64 | Hedef; cihaz/işletim sistemi üzerinde çalıştırılmadı |
| VB-CABLE | Bu bilgisayarda yok; fiziksel sanal yönlendirme test edilmedi |
| Daha düşük güçlü ikinci bilgisayar | Test edilmedi |

.NET10 desteği Windows sürümü/lifecycle'a bağlıdır; Microsoft'un
[uyumluluk tablosu](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md)
ayrıca geçerlidir. SES'in tablosu yalnızca kendi doğrulamasını gösterir.

## Otomatik testler

Native54 kontrol: mute/bypass limiter, clipping/NaN/sonsuzluk, sessizlikte AGC,
kompresör/HPF, RNNoise durağan gürültü, chirp ile960 örnek hizalama,
gürültü/gain geçişlerinde süreklilik,300 adversarial yasal filtre yapılandırması.
miniaudio ayrı test:44.1kHz stereo→48kHz mono ve48kHz mono→44.1kHz stereo.
Managed24 test: bağımsız4preset, güvenli JSON paylaşımı/import boyut/sürüm/NaN/
null/tekrarlanan alanlar, WAV/RMS eşitleme, kalibrasyon başarısı/clipping/yetersiz
konuşma, yerel durum kurtarma, gerçek C ABI/cihaz listeleme,960sample A/B
hizalama, geçersiz düzenlenen ayarları güvenli reddetme ve kayıp cihazda
başka mikrofona geçmeme.

Bir saatlik **sanal** saat farkı testi±600ppm'de360000 blok boyunca tampon
sınırlarını doğrular. Fiziksel cihazlarla bir saat canlı bağlantı testi değildir.
Türkçe sessiz kelimeler, fan/klavye/mouse altında dinleme ve preset ses kalitesi
otomatik tone/noise testiyle onaylanamaz; kullanıcının dinleme testi bekleniyor.

WPF smoke: gerçek render, TR/EN,4preset seçimi, mute/bypass, gelişmiş kontrol ve
1080×840/780×650/640×480 pencere görüntüleri. Per-monitor DPI manifest'i ve
ekran okuyucu etiketleri mevcut.100/150/200% gerçek ekran ölçekleri ve Narrator
ile kapsamlı test ayrıca bekliyor.

## Performans

İlk30.7sn gizli WPF+gerçek mikrofon capture testi: toplam CPU ortalaması%0.27,
tepe çalışma belleği152.7MiB, sıfır tampon hatası (capture-only), son480örnek DSP
blok süresi0.16ms. Çıktı: artifacts/ui/live-result.json. CPU tüm12 mantıksal
işlemciye göre normalize edilir. Sanal çıkış bağlı değildir; oyun eşzamanlılığı
ölçülmemiştir. Bellek ilk ölçümde150MB hedefinin biraz üstündedir.
60sn çevrimdışı tone~875ms'de işlenir; bir çekirdekte gerçek zaman oranı%1.46.
Bu toplam uygulama/oyun benchmark'ı değildir.

Son self-contained paket testi:30.6sn gizli UI+USB mikrofon, toplam CPU%0.219,
tepe çalışma belleği128.79MiB (yaklaşık135.0MB),1554720 işlenmiş örnek,
2sn/96000 RAM örneği, sıfır capture tampon hatası. Son DSP blok süresi0.251ms.
artifacts/package-final/live-result.json. Tampon belleği önceden ayrılır, yalnızca
yazılmış örnekler yayımlanır; kullanılmayan sayfaların başta sıfırlanması kaldırıldı.
Bu değişiklik sonrası CPU ve bellek hedefleri bu kısa capture-only koşulunda sağlandı.
Sanal çıkış/oyun dahil ölçüm veya uzun süre garantisi olarak yorumlanmamalıdır.

## Güvenlik ve teslimat

Gitleaks kaynak taraması: sıfır secret.85 vendored dosyanın SHA256 doğrulaması
geçti. NuGet vulnerability sorgusu: ek direct/transitive paket bulgusu yok.
OSV RNNoise commit sorgusu: bulgu yok. miniaudio0.11.25 için
**CVE-2026-32837** WAV BEXT decoder bulgusu geldi; SES `MA_NO_DECODING` ile
bu kodu derlemiyor. Preprocessed translation unit'te etkilenen fonksiyonların
olmadığı otomatik kontrol edildi. Audio dosyası içe aktarma yok; bu kullanımda
erişilebilir açık değildir. Gelecekte decoder eklenirse dependency yükselt.
Clang SAST: SES kodunda bulgu yok, miniaudio'da2 gereksiz ilk atama uyarısı
source context'te incelendi ve informational olarak raporlandı. Diğer uyarılar
security script'ini başarısız yapar. Managed analyzers: sıfır uyarı/hata.
AddressSanitizer native DSP+resampler testleri geçti. DAST/auth uygulanmaz;
bu uygulamada web servisi yoktur. Taramalar tüm olası açıkların kanıtı değildir.

Bağımsız reviewer960sample hizalama ve anahtar/gain geçiş kusurlarını buldu;
regresyonla düzeltildi ve yeniden incelendi. Kalan Important bulgu bildirilmedi.
Self-contained x64 publish ve gerçek WPF smoke doğrulandı. Paket dijital imzasız.
ZIP ayrı klasöre çıkarılıp Windows dizini çalışma diziniyle açılarak tekrar
smoke testinden geçti; engine DLL'i çalışma dizini/PATH üzerinden aranmadı.

Hedefler: toplam CPU≤%3, gizli UI bellek≤150MB, ek gecikme≤40ms.
RNNoise20ms algoritmik gecikmesi doğrulandı; UI tampon hesabına eklenir.
WASAPI/sanal sürücü dahil fiziksel uçtan uca gecikme **ölçülmedi**.
Discord+Valorant FPS/%1 düşük FPS/frametime ve ikinciPC karşılaştırması bekliyor.
Mikrofon dalgalanmasının donanımsal nedeni tespit edilmiş sayılmaz.
