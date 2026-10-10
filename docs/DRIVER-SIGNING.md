# Veylo Mikrofon: test imzası ve Microsoft gönderimi

Veylo **0.7.5-dev**, sürücü **0.5.4.0**. Yerel test imzalı paket üretildi ve
dosyaların kriptografik doğrulaması geçti. Bu paket **Microsoft üretim imzalı
değildir** ve `dailyUseReady=false` taşır. Normal Setup kernel sürücüsünü
paketlemez; günlük uygulama mevcut VB-CABLE ile çalışmaya devam eder.

## Dosya düzeyinde test imzalama

Depo kökünde, güncel imzasız geliştirme paketi ve zaten salt okunur bağlı
sabitlenmiş EWDK ile:

```powershell
./scripts/sign-driver-lab.ps1 -ValidateOnly
./scripts/test-driver-signing.ps1
./scripts/sign-driver-lab.ps1 -EwdkRoot D:\
```

`-ValidateOnly` yalnız sabit dosya envanterini, sürüm/ABI/protokolü, kaynak INF
ve manifest hash'lerini kontrol eder. Dosya imzalamaz. Asıl akış EWDK ISO'sunun
tam hash'ini ve SignTool/Inf2Cat hash'lerini doğrular; imzasız paket kopyasını
yeniden doğrulayıp çıktının kaynak bilgisini bu kopyadan alır.

Yeni 90 günlük RSA/SHA-256 test sertifikası ve geçici PFX, owner/SYSTEM-only
ACL'li klasörde oluşturulur. SignTool'a yalnız açık `.cer` verilir: `/dg` özet
ve imzasız PKCS7 üretir; .NET araç PFX'i `EphemeralKeySet` ile bellek içinde
yükleyip özeti imzalar; `/di` imzayı dosyaya yerleştirir. SYS imzalandıktan sonra
Inf2Cat katalogu yeniden üretir ve aynı yöntemle CAT imzalanır. Timestamp yoktur;
sertifika süresi dolunca lab paketi yeniden oluşturulmalıdır.

PFX ve imzalama ara dosyaları `finally` bloğunda tam dosya adlarıyla silinir.
Host sertifika deposuna test sertifikası eklenmez, kalıcı anahtar kapsayıcısı
oluşturulmaz. Host test-signing, Secure Boot, Bellek Bütünlüğü ve sürücü kurulumu
politikaları değiştirilmez. ZIP yalnız açık sertifikayı içerir; özel anahtar,
PFX veya parola içermez.

## Gerçekten doğrulananlar

| Kontrol | Durum ve sınır |
| --- | --- |
| SYS Authenticode | **Passed:** beklenen açık sertifika, SHA-256 CMS imzası ve PE imzalanan digest'i ile Windows SIP digest'i eşleşti |
| CAT imzası | **Passed:** aynı açık sertifikaya karşı SHA-256 CMS imzası |
| INF/SYS üyeliği | **Passed:** iki dosyanın SHA-256 signed indirect-data digest'i gerçek içerikle eşleşti; Inf2Cat'ın iki SHA-1 uyumluluk etiketi de tam hesaplanan hash'lerle doğrulandı |
| Paket/ZIP | **Passed:** sabit envanter, dosya hash'leri, sürüm/ABI/protokol; PFX/özel anahtar girdisi yok |
| Hata senaryoları | **Passed:** 35 bütünlük ve gerçek SYS/CAT/INF/CER bozma kontrolü |
| Managed analyzer build | **Passed:** `latest-all`, 0 uyarı |
| İzole test-policy kernel ve capture | **Passed:** Windows 11 build 26100 guest'te kurulum, 104 IOCTL ve PCM16/PCM32 için 20 gerçek WASAPI kontrolü; üretim politikası kabulü değildir |
| Günlük Windows kernel politikası | **Not run:** Microsoft üretim imzalı paket yok |
| Driver Verifier | **Passed:** yalnız Veylo için standart kontroller açıkken kısa 104 IOCTL / 20 WASAPI kontrolü; HVCI veya uzun süreli kabul değildir |
| Microsoft üretim imzası | **Not run:** test sertifikası bu kabulü sağlamaz |

CMS doğrulaması yalnız kriptografidir. Sertifika zinciri explicit test
sertifikasıyla bellek içindeki custom trust kullanır; Windows'un günlük kernel
politikasının sertifikayı kabul ettiği iddia edilmez. SHA-1 uyumluluk etiketleri
güçlü SHA-256 içerik kontrollerinin yerine geçmez. Manifestte
`windowsKernelPolicy=not-validated`, `microsoftProductionSigned=false` ve
`dailyUseReady=false` korunur.

Üretilen gerçek `package` klasörüne karşı kontroller tekrar edilebilir:

```powershell
$signedPackage = 'C:\tam\yol\package' # Gerçek çıktı klasörünü yaz.
./scripts/test-driver-signing.ps1 -SignedPackageDirectory $signedPackage
& .tools/dotnet/dotnet.exe `
    tools/Ses.DriverSigning/bin/Release/net10.0-windows/Ses.DriverSigning.dll `
    verify $signedPackage
```

Son komut dosya doğrulama sonucunu JSON olarak verir ve sürücü yüklemez.
İzole guest hazırlığı ve sürücü öncesi snapshot sırası
[DRIVER-LAB.md](DRIVER-LAB.md) içindedir. Test imzalı paketi normal kurulum
yardımcısı reddeder.

## Microsoft gönderimi için CAB taslağı

Güncel imzasız `build/driver/package` ve derlenmiş PDB ile:

```powershell
./scripts/prepare-driver-submission.ps1 -ValidateOnly
./scripts/prepare-driver-submission.ps1
```

Araç `artifacts/driver-submission/<run>/VeyloMic-0.5.4.0-UNSIGNED-submission-draft.cab`
ve `submission-manifest.json` üretir. CAB içindeki `VeyloMic` alt klasöründe
yalnız `SesMicrophone.inf`, `.sys`, `.cat` ve `.pdb` vardır. Manifest kopyalanan
dosyaların hash'lerini ve CAB hash'ini kaydeder. Bu bir **imzasız gönderim
taslağıdır**: `evSigned=false`, `submitted=false`, `dailyUseReady=false`.

PDB'nin varlığı, boyutu ve hash'i yanında SYS CodeView GUID/Age bilgisiyle
PDB eşleşmesi sabitlenmiş LLVM okuyucularıyla doğrulanır. `-ValidateOnly`
aynı eşleşmeyi CAB oluşturmadan kontrol eder. CAB dosya tablosu tam dört
`VeyloMic` yoluyla sınırlandırılır; çıkarılan içerik hash'leri de doğrulanır.
İzole kernel kabulü ve EV imzası tamamlanmadan taslak gönderilebilir paket
olarak sunulmaz. Microsoft'un CAB açıklaması PDB'yi
otomatik crash analizi için ister ve gönderilen kataloğun yeniden üretileceğini
belirtir. [Microsoft attestation gönderimi](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-attestation).

## Otomasyon dışında kalan adımlar

1. İzole Windows kernel/capture kabulü ve ayrıca HVCI/Verifier,
   yaşam döngüsü, uzun süreli zamanlama ve alıcı uygulama testleri tamamlanır.
2. Microsoft Windows Hardware Developer Program/Partner Center hesabı ve
   organizasyon kimlik doğrulaması tamamlanır; gerekli EV kod imzalama
   sertifikası ile güvenli anahtar erişimi sağlanır. Mevcut organizasyon
   sertifikası varsa bunun koşulları doğrulanır. Bu araçlar sertifika satın
   almaz, hesap doğrulamaz veya EV özel anahtarını edinmez.
3. Hedef dağıtıma uygun Microsoft yolu seçilir. Microsoft HLK/WHCP yolunu önerir;
   attestation için HLK testi gerekmese de bu yol Windows Certified anlamına
   gelmez ve retail Windows Update yayınına uygun değildir. Bu proje için
   attestation da günlük kullanım kabulü yerine geçmez.
4. Gerçek EV sertifikasıyla CAB, sağlayıcının güvenli imzalama sürecine göre
   imzalanır ve Hardware Dev Center'a gönderilir. Mevcut taslak EV ile
   imzalanmadı ve herhangi bir yere yüklenmedi.
5. Microsoft'tan dönen SYS/CAT paketi için Microsoft imzası/zinciri, beklenen
   INF, INF/SYS katalog üyeliği ve uygun kernel policy doğrulanır. Gerçek
   install/update/rollback/remove/reboot ve alıcı uygulama testleri tamamlanır;
   ardından normal dağıtım paketi ayrıca hazırlanır.

EV/HDC gereksinimleri bu çalışma sırasında otomatik olarak tamamlanmış
varsayılmaz. Tutar, onay süresi veya mevcut bir organizasyon hesabı/sözleşmesi
uydurulmaz. Microsoft imzası, Veylo'nun ses davranışı veya oyun/anti-cheat
uyumluluğu için tek başına garanti değildir.

Kaynaklar: [Microsoft imzalama seçenekleri](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings),
[Hardware Developer Program kaydı](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/hardware-program-register),
[kod imzalama sertifikalarının yönetimi](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-cert-manage),
[SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool).
