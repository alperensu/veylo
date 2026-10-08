# Veylo geliştirme

Kaynak deposu: https://github.com/alperensu/veylo. Repo başlangıçta özeldir;
erişim hesabın GitHub izinlerine bağlıdır. Lisans MIT'dir.

## Çalışma akışı

1. Güncel `main` dalını al; değişikliği `codex/kisa-aciklama` dalında geliştir.
2. İhtiyacı bir Issue'da takip et. Mevcut ayar/preset uyumluluğunu koru.
3. Yerel derleme ve ilgili testleri çalıştır; bir Pull Request aç.
4. Windows validation başarılı olsun. Kod ve güvenlik incelemelerindeki geçerli
   bulguları düzelt. Yeşil CI, gerçek mikrofon/uyumluluk testi yerine geçmez.
5. İncelenen PR'ı `main` dalına birleştir. Sürümleri GitHub Releases ile takip et.

## Yerel komutlar

Windows x64 ve PowerShell gerekir. İnternet yalnızca araç/bağımlılık doğrulama ve
indirme için gereklidir; günlük ses işleme çevrimdışıdır.

```powershell
./scripts/build.ps1
./scripts/test.ps1
./scripts/security.ps1
./scripts/build.ps1 -Sanitize
./scripts/test.ps1 -Sanitize
./scripts/package.ps1 -SkipBuild
```

SDK/CMake/LLVM sürümleri ve SHA kontrolleri `scripts/bootstrap.ps1` içinde
sabittir. RNNoise/miniaudio dosyaları `dependencies.lock.json` ile doğrulanır.
CI aynı komutları temiz bir `windows-2022` makinesinde çalıştırır; mikrofon açmaz,
sürücü kurmaz, EWDK indirmez ve Windows güvenlik ayarlarını değiştirmez.
CI'da geliştirme sürücüsü derlenmediğinden unsigned development CAT kontrolü atlanır;
diğer katalog reddetme testleri çalışır.

## Paketler ve sürümler

Başarılı [Actions](https://github.com/alperensu/veylo/actions) koşusunun
`veylo-windows-<commit>` artifact'i uygulama ZIP'i, kaynak ZIP'i ve SHA256
dosyalarını içerir. Hata durumunda tanı artifact'i bulunabilir. Paketler 14,
tanı çıktıları 7 gün tutulur; kalıcı indirmeler Releases'e eklenir.

Sürüm oluştururken önce `app/Ses.Desktop/Ses.Desktop.csproj` sürümünü güncelle;
o commit'in CI sonucunu ve paket checksum'larını doğrula. Release tag'i o commit'i
göstermeli; ZIP içindeki `release-status.json` doğrulama sınırlarını açıklar.
`-dev` sürümler prerelease olarak yayımlanır. Bu başlangıç sürümünde VB-CABLE
ayrıca kurulur; kendi kernel sürücümüz imzalı kurulum paketi olarak sunulmaz.
Kernel doğrulaması ve imzalama ayrı laboratuvar işidir: [DRIVER.md](docs/DRIVER.md).

## İnceleme sınırları

Ses callback'inde bellek tahsisi, disk erişimi ve bloklayan kilit ekleme.
Susturma ve güvenlik limiter'i bypass'ta da korunsun. Paylaşılan presetlere
ses kaydı veya cihaz kimliği ekleme. CI token'ı yalnızca kaynak okuma yetkisine
sahiptir; fork PR'larında secret veya yazma yetkisi kullanılmaz.
GitHub Actions sürümleri tam commit SHA ile sabitlenir; Dependabot önerileri
incelemeden birleştirilmez. İmzalama anahtarları, token'lar, `.env` dosyaları,
gerçek kullanıcı durumu ve ses örnekleri Git'e eklenmez.
