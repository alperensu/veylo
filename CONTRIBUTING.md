# Veylo'ya katkı

Veylo, Windows için yerel mikrofon ve ses işleme uygulamasıdır. Kaynak depo
[alperensu/veylo](https://github.com/alperensu/veylo), lisans [MIT](LICENSE).
Hata düzeltmeleri, erişilebilirlik, Türkçe/İngilizce arayüz ve belgelendirme
katkıları kabul edilir. Başlamak için Issue açmak zorunlu değildir; büyük bir
özellik veya davranış değişikliğinde kapsamı önce bir Issue'da konuşmak yararlıdır.

## İlk derleme

Windows x64, Git ve PowerShell kullanın; PowerShell 7 önerilir ve VM laboratuvarı
betikleri için gereklidir. Depoyu fork edip klonlayın, ardından depo kökünde:

```powershell
git switch -c codex/kisa-aciklama
./scripts/build.ps1
./scripts/test.ps1 -Headless
```

`build.ps1` gerekli .NET, CMake ve LLVM araçlarını checksum doğrulamasıyla
`.tools` altına hazırlar; ayrıca native motoru, masaüstünü ve kurulum yardımcısını
derler. İlk araç/bağımlılık indirmeleri internet ister. Günlük ses işleme yereldir.

`-Headless`, ses cihazı olmayan makinelerde test çalıştırmak içindir; gerçek
mikrofon kabulü değildir. Ses cihazı olan geliştirme makinesinde
`./scripts/test.ps1`, açıkça mikrofon testi istediğinizde
`./scripts/test.ps1 -Live` kullanın. `-Live` ve `-Headless` birlikte kullanılamaz.
Güvenlik, sanitizer, paketleme ve sürücü laboratuvarı ayrıntıları
[DEVELOPMENT.md](docs/DEVELOPMENT.md) içindedir.

## Pull Request hazırlığı

- Değişikliğin amacı, önceki/sonraki davranış ve varsa ilgili Issue bağlantısını yazın.
- Mevcut ayar, profil, kalibrasyon ve ABI sözleşmelerini koruyun. Davranış değişirse
  gerekli geçişi ve dokümantasyonu aynı PR'a ekleyin; ilgisiz refactor yapmayın.
- İlgili derleme/testleri ve güvenlik kontrollerini çalıştırın. Çalıştırılan komutları,
  sonuçları ve çalıştırılamayan kontrollerin nedenini açıkça belirtin.
- Arayüz değişikliklerinde Türkçe/İngilizce metinleri, klavye erişimini ve Windows
  hareket/yüksek kontrast tercihlerini kontrol edin. Kişisel veri içermeyen
  ekran görüntüleri ekleyin.
- Kod ve güvenlik incelemelerinde geçerli bulguları düzeltin. Yeşil
  [Windows validation](https://github.com/alperensu/veylo/actions/workflows/windows.yml),
  gerçek mikrofon, oyun veya alıcı uygulama uyumluluk kabulünün yerine geçmez.

## Ses, gizlilik ve güven sınırları

Ses callback'ine bellek tahsisi, disk erişimi veya bloklayan kilit eklemeyin.
Susturma ve güvenlik limiter'i Orijinal ses/bypass modunda da korunmalıdır.
Paylaşılan profillere ses kaydı, cihaz kimliği veya yerel yönlendirme bilgisi
koymayın. İmzalama anahtarlarını, token'ları, `.env` dosyalarını, gerçek kullanıcı
ayarlarını ve kişisel ses örneklerini Git'e veya Issue/PR eklerine eklemeyin.
Güvenlik açığı bildirimi için [SECURITY.md](SECURITY.md) kullanın.

CI token'ı kaynak okuma yetkisiyle sınırlıdır; fork PR'larında secret veya yazma
yetkisi kullanılmaz. Actions sürümleri tam commit SHA ile sabitlenir; bağımlılık
ve Dependabot değişiklikleri inceleme gerektirir.

## Sürüm ve paket durumu

**0.7.5-dev geliştirme sürümüdür.** Normal Setup ve taşınabilir paket VB-CABLE'ı
ve kendi kernel sürücümüzü içermez. VB-CABLE ayrıca kurulur. Veylo Mikrofon
sürücüsü yalnız ayrı izole laboratuvar paketinde test imzalıdır; Microsoft üretim
imzası, HVCI, dayanıklılık ve alıcı uygulama kabulü tamamlanmamıştır.

Sürüm yayımlama bakımcı işidir: proje sürümü, tag/commit, CI sonucu, SHA-256
ve `release-status.json` birlikte doğrulanır; `-dev` sürümleri prerelease olarak
yayımlanır. Paket üretimi ve CI artifact ayrıntıları [DEVELOPMENT.md](docs/DEVELOPMENT.md),
kabul sınırları [VALIDATION.md](docs/VALIDATION.md) içindedir.
