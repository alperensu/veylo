# Geliştirme ve doğrulama

Depo kökünden Windows x64 üzerinde çalıştırın. Git ve PowerShell gerekir;
PowerShell 7 önerilir ve VM başlatma/kontrol betiklerinde zorunludur.
Sabit araç sürümleri ve SHA kontrolleri [bootstrap.ps1](../scripts/bootstrap.ps1),
native bağımlılıklar [dependencies.lock.json](../dependencies.lock.json) içindedir.

## Uygulama ve testler

```powershell
./scripts/build.ps1
./scripts/test.ps1 -Headless
./scripts/security.ps1
./scripts/build.ps1 -Sanitize
./scripts/test.ps1 -Sanitize
```

Normal derleme native C++20 motorunu, .NET 10 WPF masaüstünü ve sürücü kurulum
yardımcısını hazırlar. Başlatılabilir uygulama:
`app/Ses.Desktop/bin/Release/net10.0-windows/Veylo.exe`.

Normal test akışı native/managed testleri, masaüstü kalıcılık ve çıkış testlerini,
sürücü paket/imzalama/VM fixture kontrollerini, katalog reddetme testlerini ve UI
smoke çıktısını kapsar. Bu akış kernel sürücüsü kurmaz, EWDK indirmez veya Windows
güvenlik ayarlarını değiştirmez. VM fixture testi gerçek Windows VM kabulü değildir.

`-Headless` yalnızca boş ses cihazı listesinin kabul edilmesini sağlar; gerçek
enumeration API'si ve dönen cihazların sınırları yine kontrol edilir. Cihaz yoksa
fiziksel bulunabilirlik kontrolü `SKIP` raporlanır. Cihaz bulunan makinede normal
kontrol ve isteğe bağlı gerçek mikrofon testi:

```powershell
./scripts/test.ps1
./scripts/test.ps1 -Live
```

`-Live` gerçek mikrofonu açar; uygun cihaz ve izinleri olan yerel ortamda çalıştırın.
`-Live` ile `-Headless` birlikte kullanılamaz. Sanitizer akışı yalnız native
AddressSanitizer derleme/testlerini çalıştırır; managed ve UI testlerinin yerine
geçmez. `security.ps1` dependency hash, Gitleaks, NuGet/OSV metadata, Clang statik
analiz ve managed analyzer kontrollerini içerir; çevrimiçi metadata erişimi ister.

## Paketleme

Başarılı normal derleme ve ilgili testlerden sonra:

```powershell
./scripts/package.ps1 -SkipBuild
./scripts/test-installer.ps1
```

`-SkipBuild` önceki doğrulamaya güvenir; kendi başına test çalıştırmaz.
Bayraksız `package.ps1` önce normal build/test akışını çalıştırır; ses cihazı
olmayan makinelerde önce açıkça `test.ps1 -Headless` çalıştırıp `-SkipBuild`
kullanın. Paketleme checksum ile sabitlenmiş Inno Setup derleyicisini gerekirse
`.tools` altına indirir. Inno Setup ticari kullanım lisans koşulları ayrıca
incelenmelidir.

Çıktılar `dist` altında Setup EXE, taşınabilir Windows x64 ZIP ve kaynak ZIP ile
her dosyanın SHA-256 değeridir. Kurulum yaşam döngüsü testi ayrı ürün kimliği ve
`artifacts/installer` dizini kullanır; normal kullanıcı profillerini ve başlangıç
tercihini koruyarak test kurulumunu kurar/kaldırır. Bu test yerel durumu değiştirir.

Alternatif CMake çıktı dizinindeki native DLL için:

```powershell
./.tools/dotnet/dotnet.exe build app/Ses.Desktop -c Release -p:NativeBinary=C:\tam\yol\ses_native.dll
./scripts/package.ps1 -SkipBuild -NativeBinary C:\tam\yol\ses_native.dll
```

Örnekteki yolu kendi DLL yolunuzla değiştirin. Uygulama ve DLL ABI **5** birlikte
kullanılır; farklı ABI sürümlerini karıştırmayın. Bu yol yerel geliştirici girdisidir,
preset dosyalarından okunmaz. Sürücü protokolü **1**'dir.

## CI ve sürüm yayımlama

[Windows validation](https://github.com/alperensu/veylo/actions/workflows/windows.yml)
`windows-2022` üzerinde build, headless test, history secret scan, statik analiz,
sanitizer, paketleme, installer yaşam döngüsü ve checksum kontrollerini çalıştırır.
CI kernel sürücüsünü derlemez veya kurmaz. Geliştirme CAT dosyası bulunmadığında
o dosyaya özel unsigned CAT testi atlanır; diğer katalog reddetme testleri çalışır.

Başarılı koşunun `veylo-windows-<commit>` artifact'i Setup, uygulama/kaynak ZIP'leri
ve SHA-256 dosyalarını içerir; 14 gün saklanır. `veylo-diagnostics-<commit>` tanı
artifact'i 7 gün saklanır ve hata durumunda da üretilebilir. Kalıcı indirmeler
[Releases](https://github.com/alperensu/veylo/releases) üzerinden yayımlanır.

Sürüm hazırlarken [proje sürümünü](../app/Ses.Desktop/Ses.Desktop.csproj), tag'in
hedef commit'ini, o commit'in CI sonucunu, paket checksum'larını ve paket içindeki
`release-status.json` sınırlarını doğrulayın. `-dev` paketlerini prerelease olarak
etiketleyin. Mevcut **0.7.5-dev** paketi kod imzalı değildir; VB-CABLE ve kernel
sürücüsü pakete eklenmez. Derleme başarısı günlük kullanım kabulü değildir.

## Kernel sürücüsü laboratuvarı

Günlük çıkış VB-CABLE'dır. Kernel geliştirme ayrı, izole Windows hedefi gerektirir;
normal katkı akışı için EWDK, test sertifikası veya sürücü kurulumu gerekmez.
Sürücü derleme/imzalama ve VM komutları için [DRIVER.md](DRIVER.md),
[DRIVER-SIGNING.md](DRIVER-SIGNING.md) ve [DRIVER-LAB.md](DRIVER-LAB.md) kullanın.
Host Windows güvenlik ayarlarını değiştirmeyin veya test imzalı paketi günlük
makineye kurmayın. Güncel kanıt ve kalan kabul kapıları [VALIDATION.md](VALIDATION.md)
ile [ACCEPTANCE.md](ACCEPTANCE.md) içindedir.
