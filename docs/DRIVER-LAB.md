# Veylo Mikrofon: izole Windows laboratuvarı

Veylo **0.7.5-dev**, sürücü **0.5.1.0**. Normal Setup kernel sürücüsünü
paketlemez; günlük uygulama mevcut VB-CABLE ile çalışır. Dosya düzeyinde test
imzalı SYS/CAT ve içerik doğrulamaları tamamlandı. İzole Windows 11 build 26100
guest'te kurulum, 104 IOCTL kontrolü ve PCM16/PCM32 gerçek WASAPI capture geçti.
Driver Verifier standart kontrolleri açıkken aynı kısa testler geçti.
HVCI, uzun süreli testler ve alıcı uygulama kabulü henüz **Not run** durumundadır;
günlük kullanıma hazır olunduğu anlamına gelmez. [Güncel kanıt ve sınırlar](https://github.com/alperensu/veylo/blob/main/docs/VALIDATION.md).

## Host üzerinde hazırlanabilen çıktılar

Depo kökünde:

```powershell
./scripts/build.ps1
./scripts/test.ps1 -Headless
./scripts/build-driver.ps1 -EwdkRoot D:\
./scripts/package-driver.ps1
./scripts/sign-driver-lab.ps1 -ValidateOnly
./scripts/sign-driver-lab.ps1 -EwdkRoot D:\
./scripts/driver-readiness.ps1 -OutFile artifacts/driver-readiness/preflight.json
```

`D:\` örneği zaten salt okunur bağlanmış EWDK içindir. EWDK 26100.6584 ISO'su,
SignTool ve Inf2Cat hash'leri imzalama öncesinde sabitlenmiş değerlere karşı
kontrol edilir. Kit yoksa `build-driver.ps1 -DownloadKit` resmi EWDK indirme ve
hash kontrolü yoludur; EWDK dağıtım paketine konmaz.

İmzasız çıktı `Veylo-driver-0.5.1.0-isolated-lab.zip`, test imzalı çıktı
`artifacts/driver-test-signing/<run>/Veylo-driver-0.5.1.0-TEST-SIGNED-isolated-lab.zip`
olur. `<run>` her çalışmada yeni kimliktir. Test paketinde INF/SYS/CAT, açık
`lab-test.cer`, iki lab test aracı, lisanslar, rehberler ve
`test-signing-manifest.json` bulunur. PFX veya özel anahtar bulunmaz.

Gerçek SYS Authenticode imzası, CAT imzası ve INF/SYS katalog içerik digest'leri
açık sertifikaya karşı kriptografik olarak doğrulandı. Manifest ve ZIP hash'leri
ayrıca doğrulanır. Bu işlem sırasında host sertifika deposuna sertifika
eklenmedi; host test-signing, Secure Boot, Bellek Bütünlüğü veya sürücü kurulumu
ayarları değiştirilmedi. Test sertifikasını normal kurulum yardımcısı reddeder.

## VM girdileri ve değerlendirme lisansı

Hazırlık Windows **11 IoT Enterprise LTSC 2024 Evaluation x64** medyasını ve
QEMU **11.1.0-20260811** Windows build'ini kullanır. Microsoft değerlendirme
sürümünü 90 gün için sunar; kullanım koşullarını inceleyip kabul etmek ayrı
bir adımdır. Bu medya mevcut günlük Windows'u yükseltmek veya değiştirmek için
kullanılmaz. Kaynaklar: [Microsoft değerlendirme sayfası](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-iot-enterprise-ltsc),
[Windows IoT lisans koşulları](https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/commercialization/licensing).

QEMU'nun [Windows indirme sayfasının](https://www.qemu.org/download/#windows)
işaret ettiği Weilnetz build'i kullanılır. İndirme URL'leri, QEMU installer
SHA-512 değeri, çalıştırılan iki QEMU aracının SHA-256 değerleri ve Windows ISO
değeri `driver/lab.lock.json` içinde sabitlenmiştir. VM hazırlama betiği hazır
girdileri bekler:

```text
.tools/driver-lab/Windows11-IoT-LTSC-2024-eval.iso
.tools/driver-lab/qemu/qemu-system-x86_64.exe
.tools/driver-lab/qemu/qemu-img.exe
```

Windows ISO için bulunan Microsoft PDF checksum'ı
`8abf91c9cd408368dc73aab3425d5e3c02dae74900742072eb5c750fc637c195`,
güncel indirilen ISO'nun SHA-256 değeri ise
`2cee70bd183df42b92a2e0da08cc2bb7a2a9ce3a3841955a012c0f77aeb3cb29`.
**Resmi PDF checksum eşleşmesi yoktur.** Hazırlıkta güncel Microsoft HTTPS
yönlendirmesinden iki bağımsız indirme aynı ISO hash'ini verdi; çıkarılan
`setup.exe` için Microsoft Windows Authenticode imzası `Valid` görüldü.
Bu kanıt ISO'nun tamamı için yayımlanmış resmi checksum eşleşmesi olarak
sunulmaz. Ayrıntı `publishedPdfHashMatched=false` ve `pinEvidence` alanlarında
tutulur. [Microsoft checksum PDF'si](https://go.microsoft.com/fwlink/?linkid=2272287).

## Hazırlama, ilk açılış ve sürücü öncesi snapshot

Aşağıdaki örnekte `C:\tam\yol\package`, imzalama çıktısının gerçek `package`
klasörüyle değiştirilir. `-AcceptEvaluationLicense` Microsoft değerlendirme
konuğunun koşullarını açıkça kabul eder. Betik bu bayrak olmadan durur.

```powershell
$signedPackage = 'C:\tam\yol\package'
./scripts/test-driver-signing.ps1 -SignedPackageDirectory $signedPackage
./scripts/prepare-driver-vm.ps1 -AcceptEvaluationLicense `
    -TestSignedPackage $signedPackage -EwdkRoot D:\ -Accelerator tcg
```

Hazırlık yeni, projeye ait 64 GB sanal QCOW2 disk ve özel seed klasörü üretir;
en az 40 GB boş çalışma alanı ister. Mevcut host diskleri veya VM'ler bu disk
olarak kullanılmaz. Varsayılan hızlandırıcı `whpx`'tir; hazır ve kullanılabilir
WHPX yerine CPU emülasyonu gerektiğinde örnekteki `tcg` seçilir. Betikler host
Windows özelliklerini etkinleştirmez. TCG sonucu performans kabulü sayılmaz.

VM başlatma/kontrol betikleri PowerShell 7 ister. Çıktıdaki gerçek `vm-...`
klasörünü kullanarak ilk açılışı yap:

```powershell
$vm = 'C:\tam\yol\.tools\driver-lab\vm-...'
./scripts/start-driver-vm.ps1 -VmDirectory $vm
```

Başlatıcı guest ağını kapatır; kullanıcı klasörlerini veya host cihazlarını
iletmez. Yalnız o VM'ye ait özel seed salt okunur bağlanır. Yeni guest Windows
kurulumu ilk açılışta gerçekleşir. `guest.ps1`, QEMU üretici/model bilgisini,
`VEYLO-LAB` adını, VM UUID'sini ve seed hash'lerini kontrol ettikten sonra
**yalnız guest içinde** açık test sertifikasını Root/TrustedPublisher deposuna
ekler ve guest test-signing'i açar. Ardından sürücüyü kurmadan kapanır.
Guest oturumu yükseltilmiş değilse yalnız VM içinde UAC onayı ister. SYSTEM
başlangıç görevinin kodu ve manifesti guest Administrators/SYSTEM dışına kapatılır.
Temiz imajda TrustedPublisher deposu yoksa sabit Windows certutil aracıyla
oluşturulur; bir yetki hatası başarı olarak gösterilmez.

QEMU `-no-reboot` ile çalışır: Windows yeniden başlatma istediğinde süreç
kapanır. Aynı sanal diskte kuruluma `start-driver-vm.ps1 -VmDirectory $vm
-BootInstalled` ile devam edilir; bu yol ISO'yu bağlamaz ve diski yeniden
biçimlendirmez. WHPX'nin sıcak reset hatası böylece izole edilir. Windows'un
kurulum yeniden başlatması, aşağıdaki sürücü öncesi hazırlık mesajıyla aynı
şey değildir; mesaj gelmeden hazırlık tamamlandı veya snapshot alındı denmez.

QMP, özel supervisor sürecinin `stdio` kanalındadır; ağ dinleyicisi açılmaz.
Kontrol istekleri aynı VM'nin owner/SYSTEM-only klasöründe, sabit komutlar ve
oturum kimliğiyle işlenir. Çalışan VM'nin durumunu ve ekranını görmek için:

```powershell
./scripts/control-driver-vm.ps1 -VmDirectory $vm -Command query-status
./scripts/control-driver-vm.ps1 -VmDirectory $vm -Command screendump
```

Ekran görüntüsü yalnız `$vm\screen.ppm` dosyasına yazılır. Kurulum takılmışsa
inceleme için bu görüntü ve sınırlı `qemu-stderr.log` kullanılır. VM işlemini
sonlandırmak gerektiğinde:

```powershell
./scripts/control-driver-vm.ps1 -VmDirectory $vm -Command quit
```

`quit`, düzgün Windows kapanışı veya temiz snapshot kanıtı değildir; sürücü
öncesi checkpoint için aşağıdaki guest kapanışını bekle.

`serial.log` içindeki `guest prepared; shutting down for clean pre-driver snapshot`
mesajını ve QEMU işleminin tamamen sonlandığını doğrula. Mesaj tek başına
snapshot değildir. Disk kapalıyken sürücü öncesi snapshot al:

```powershell
& .tools/driver-lab/qemu/qemu-img.exe snapshot -c before-driver "$vm\windows.qcow2"
& .tools/driver-lab/qemu/qemu-img.exe snapshot -l "$vm\windows.qcow2"
```

Snapshot listesinde `before-driver` görünmeden ikinci açılışa geçme. Bu noktada
Windows/guest test politikaları hazırlanmış, sürücü ise henüz kurulmamış olmalı.
Guest betiği günlük host üzerinde çalıştırılmaz.

## Yalnız guest içinde kurulum ve gerçek capture

Snapshot'tan sonra kurulu diski açıkça seçerek aynı VM'yi tekrar başlat:

```powershell
./scripts/start-driver-vm.ps1 -VmDirectory $vm -BootInstalled
```

İlk ISO açılışının tekrarı reddedilir; devam için `-BootInstalled` kullanılır.
Guest
başlangıç görevi sabitlenmiş WDK DevCon ile `ROOT\SES_MICROPHONE` cihazını kurar,
IOCTL testini ve gerçek capture testini çalıştırır. Kurulum ayrıca reboot
isterse akış bunu başarılı kabul etmez; ayrı takip gerekir.

Elle tekrar gerektiğinde, Veylo kapalıyken yalnız guest içinde:

```powershell
C:\VeyloLab\ses_driver_lab_tests.exe --isolated-lab
C:\VeyloLab\ses_driver_capture_lab_tests.exe --isolated-lab `
    --json-report C:\VeyloLab\capture.json
```

IOCTL aracı bozuk boyut, sürüm, sahiplik, replay ve yaşam döngüsü sınırlarını
denetler. Capture aracı tam donanım kimliği/servisi eşleşen tek endpoint'i arar;
48 kHz mono PCM16/PCM32 için belirli sinyalin capture'a ulaşmasını ve üretici
kapanınca yeni sessiz örnekleri ölçer. Desteklenmeyen formatlar geçiş sayılmaz.
`--isolated-lab` bir onay bayrağıdır, tek başına izolasyon oluşturmaz.

Host üzerinde güvenli `ses_driver_capture_lab_tests.exe --self-test` yalnız
analizör/PCM/tampon kontrolleridir; gerçek endpoint veya kernel capture kanıtı
değildir. Guest raporları `C:\VeyloLab\result.json`, `capture.json`, `install.log`,
`ioctl.log`, `capture.log` altındadır; seri çıktı VM klasöründeki `serial.log`'a
yazılır. Süreç başladı diye testi geçmiş sayma. Bu sürümde kısa izole kernel
ve capture testleri geçti; HVCI, uzun süreli testler ve uygulama kabulü bekliyor.

## Tamamlanacak kabul matrisi

| Alan | Kontrol | Gerekli kanıt |
| --- | --- | --- |
| KS formatları | 48 kHz mono PCM16/PCM32; yanlış cbSize/FormatSize/hizalama/bytes-per-second reddi | Gerçek kernel müzakeresi ve debugger/Verifier logu |
| Üretici sınırı | Kısa/uzun boyut, sürüm, sahiplik, replay, reserved, bilinmeyen IOCTL | Guest lab aracı; sentetik test yeterli değildir |
| Yaşam döngüsü | Stop/start, açık handle, surprise/remove, yeniden kur, ikinci adapter reddi | PnP logları; artık endpoint/servis yok |
| Ses | Çıkış açılmadan, tüketici kapat/aç, üretici çökmesi, 100 ms üzeri kesinti | Yeni sessizlik; eski ses tekrarı yok |
| Zamanlama | PCM16/32, küçük DPC parçaları, jitter, farklı saatler, bir saatlik çalışma | Gerçek timestamp/ses kaydı/tampon sayaçları |
| Uyku/uyanma | Uzun bekleme, saat gerilemesi, çıkar/tak | Eski DMA sesi yok; zaman/bytes taşması yok |
| HVCI/Verifier | Yalnız SesMicrophone.sys; havuz, IRQL, I/O, deadlock, security/code integrity | Bugcheck olmaması ve loglar; kaynakta NX yeterli değildir |
| Paylaşımlı capture | İki farklı alıcı, kayıt/toplantı/yayın ve oyun | Aynı işlenmiş giriş; render endpoint yok |
| Kullanıcı alanı | Gizli açılış, mikrofon değişimi/kaybı, mute/bypass, çıkış bırakma | Gerçek akış ve hata sonuçları |
| Günlük teslimat | Microsoft imzası, katalog üyeliği, kernel policy, install/update/rollback/remove/reboot | Dönen paket hash'i, OS build ve resmi imza doğrulaması |

OS build, paket SHA-256, VM/fiziksel cihaz, hızlandırıcı ve yöntemi sonuçlarla
birlikte kaydet. HVCI/Driver Verifier ayrı lab aşamasıdır; mevcut guest görevi
bunları çalıştırmaz. Verifier'ı tüm sürücülere veya günlük bilgisayara uygulama.
Geri dönüş gerektiğinde önce VM'yi tamamen kapat, sonra aynı sahipli diskte
`qemu-img snapshot -a before-driver` ile lab durumuna dön; başka diski hedefleme.

## Günlük geçiş

Guest kabulü, uygun Microsoft imzalama süreci ve dönen paketin doğrulanması
tamamlanınca üretim paketi ayrıca hazırlanır. Şu an normal Setup kernel
sürücüsünü dışarıda tutar; VB-CABLE yolu devam eder. Microsoft imzası tek başına
HVCI, zamanlama veya Discord/Valorant uyumluluğunu kanıtlamaz. Varsayılan Windows
cihazları değiştirilmez; uygulama mikrofonu hoparlöre sürekli geri vermez.

Kaynaklar: [Microsoft hedef hazırlama](https://learn.microsoft.com/en-us/windows-hardware/drivers/gettingstarted/provision-a-target-computer),
[test imzalı paket](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/test-signing-driver-packages),
[imzalama seçenekleri](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings),
[Driver Verifier](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/driver-verifier).
