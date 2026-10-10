# Sanal mikrofon: genişletilmiş kabul araçları

Bu araçlar test imzalı sürücünün **yetkilendirilmiş Windows VM'sinde** denenmesi
içindir. Günlük Windows'a sürücü kurmaz; normal uygulama VB-CABLE ile çalışır.
Üretim imzası, fiziksel mikrofon ve uygulama uyumluluğu yerine geçmez.

0.5.4 geliştirme sürücüsü tamamlanan PCM paketlerini önceden ayrılmış sekiz
paketlik özel kuyrukta korur. Windows'un DMA tamponuna yalnız GetReadPacket
tam paketi yayımlar; kısmi paket sonraki okuma alanını değiştirmez. MoreData,
gecikmeli okumadan sonra kalan tam paketlerin sırayla alınmasını sağlar.
Kuyruk taşarsa en eski paket atılır; konum boşluğu kabul testinde görünür kalır.
Üretici kapanması, yeni bağlantı veya zaman aşımı özel kuyruktaki eski sesi
geçersizleştirir. İlk örneğin zamanı paketle saklanır; PAUSE/RUN bunu değiştirmez.
Bu kaynak/çevrimdışı doğrulama, önceki canlı hatanın çözüldüğünü tek başına kanıtlamaz.

Capture raporundaki `clients[].first_invalid_packet`, ilk geçersiz paketin frame
konumunu, beklenen konumu, flag'lerini, QPC zamanlarını ve uygunluk durumunu
saklar; olay yoksa `null` olur. Zamanlar WASAPI'nin QPC tabanlı 100 ns
birimindedir; kernel tanılarındaki interrupt-time saatinden ayrı tutulur.
Bu alan tanı içindir; kabul eşikleri gevşetilmez ve PCM kaydı içermez.

## Sabit ve doğrulanmış test medyası

Önce mevcut [laboratuvar kurulumunu](DRIVER-LAB.md) tamamla. VM kapalıyken:

```powershell
./scripts/build.ps1
./scripts/stage-driver-acceptance.ps1 -VmDirectory $vm
./scripts/start-driver-vm.ps1 -VmDirectory $vm -BootInstalled
```

`$vm`, hazırlama aracının verdiği sahipli VM dizinidir. Staging, VM süreçlerinin
durduğunu ve sanal diskin kilitli olmadığını denetler. Sabit üç dosya salt okunur
seed medyasının `acceptance` dizinine konur. Manifest VM UUID'sini ve script/EXE
SHA-256 değerlerini bağlar. Güncelleme gerekirse VM kapalıyken açıkça
`-ReplaceStaged` kullan: eski doğrulanmış üç dosya özel history dizininde korunur.

Yalnız VM'nin **yükseltilmiş** PowerShell oturumunda, seed sürücüsünün gerçek
harfini kullanarak aşağıdaki kopyayı hazırla. `D:` bir örnektir:

```powershell
New-Item -ItemType Directory -Path C:\VeyloAcceptance
Set-Acl -LiteralPath C:\VeyloAcceptance -AclObject (Get-Acl C:\VeyloLab)
Copy-Item -LiteralPath D:\acceptance\driver-vm-acceptance.ps1 -Destination C:\VeyloAcceptance
Copy-Item -LiteralPath D:\acceptance\ses_driver_capture_lab_tests.exe -Destination C:\VeyloAcceptance
Copy-Item -LiteralPath D:\acceptance\acceptance-manifest.json -Destination C:\VeyloAcceptance
```

ACL kopyalamayı dosya kopyalamadan önce yap. Kök, manifestler, araçlar ve mevcut
çıktılar Administrators/SYSTEM sahipliği ve erişimi gerektirir. Genel kullanıcı
yazma izni, farklı UUID, bozuk hash veya reparse path kabul edilmez. Guest script'i
host üzerinde çalıştırma. `VmId` olarak `vm.json` içindeki tam UUID'yi kullan.

## Modlar ve kabul kapsamı

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force # yalnız bu guest oturumu
$id = [Guid]'VM-UUID-BURAYA'
$runner = 'C:\VeyloAcceptance\driver-vm-acceptance.ps1'
& $runner -VmId $id -Mode Diagnostics
& $runner -VmId $id -Mode Capture -Extended -DurationSeconds 60
& $runner -VmId $id -Mode Capture -Extended -DurationSeconds 3600
# Uygulamanın gerçek kullanıcı alanı aktarım yolunu ayrıca doğrula:
& $runner -VmId $id -Mode Capture -Extended -ProductBridge -DurationSeconds 60
& $runner -VmId $id -Mode Capture -Extended -ProductBridge -DurationSeconds 3600
```

- **Diagnostics:** Anahtarları kaydetmeden lisans durumu, DeviceGuard/VBS, CPU
  sanallaştırma bilgisi, desteklenen uyku durumları, Verifier ve sınırlı hata logu.
  Bu modun `Passed` sonucu teşhisin toplandığı anlamına gelir; HVCI veya lisans
  kabulü değildir. HVCI için VBS durumunun `2` ve çalışan hizmetlerde `2` gerekir.
- **Capture:** Varsayılan PCM16/PCM32 kısa koşusu; `Extended` ile 10–3600 saniye
  süren gerçek kernel aktarımı. İki paylaşımlı WASAPI istemcisi **aynı süreçtedir**;
  iki ayrı uygulama veya fiziksel mikrofon kabulü değildir. Dalga biçimi, paket
  sürekliliği, zaman damgası, sayaçlar, her istemcinin ilerlemesi ve bellek sınırları
  denetlenir. 550 ms üretici arası ile üretici/tüketici yeniden bağlantısı sonrası
  taze sessizlik ve sinyalin geri gelmesi sınanır.
  Üretici ayrı iş parçacığında, özel timer ve MMCSS ile çalışır; yazma aralığı,
  IOCTL süresi ve en düşük kuyruk doluluğu ayrı raporlanır. 50 ms üretici
  gecikmesi dış sınırdır; tamponun 50 ms kesintiyi karşılayacağı iddiası değildir.
  Sürekli akışta tek underrun bile koşuyu başarısız yapar.
  **ProductBridge:** 480 float frame/10 ms örnekleri doğrudan uygulamanın
  `DriverBridge` sınıfına verir. Gerçek dört blokluk TransferQueue, PCM32
  dönüşümü, özel 2 ms worker zamanlayıcısı ve sürücü IOCTL yolu kullanılır.
  Worker da MMCSS Pro Audio ile çalışmalıdır. Her callback'in başarılı WRITE
  ve ayrı gözlenen kernel received sayacına ulaşması, sıfır kuyruk kaybı ve
  üç gerçek üretici oturumu zorunludur. Oturum kapanışındaki 150 ms flush
  sınırı aşılırsa test başarısız olur. Rapor bu modu açıkça ayırır; atomik
  worker örneklerini doğrudan STATUS çağrısı süresi gibi sunmaz. Bu mod da
  fiziksel mikrofon/DSP veya iki ayrı alıcı uygulama kabulü değildir.
  ProductBridge yalnız Extended/Capture ile kullanılabilir. Varsayılan
  sentetik üretici testi ve onun başarısızlık kayıtları korunur.
- **CodeIntegrityVerifier:** Yalnız `SesMicrophone.sys` için `0x021209bb` bayraklarını
  ayarlar. Yeniden başlatmak gerekir; yeniden açılışta logdan gerçekten etkin
  olduğunu doğrula. Bu kontrol, HVCI açık testin yerine geçmez.
- **EnableHvciLab:** Yalnız guest'te kilitsiz HVCI/VBS test ayarlarını hazırlar.
  Önce korunan registry ve BCD geri dönüş kanıtını kaydeder; mevcut ilk snapshot
  varsa tekrar uygulamayı reddeder. `Mandatory` veya UEFI kilidi açılmaz.
  `RequirePlatformSecurityFeatures=0` bu laboratuvar denemesine özeldir; normal
  Windows güvenlik kurulumu için öneri değildir. Sonuç yalnız **Reboot required**
  olabilir. Yeniden açılışta gerçek VBS/HVCI durumu ve aynı oturumdaki capture
  ayrıca doğrulanmalıdır.
- **RemoveReinstall:** Tam aygıt instance'ını kaldırır, yokluğunu doğrular ve aynı
  doğrulanmış INF'yi yeniden kurar. Farklı sürüme güncelleme/geri alma testi değildir.
- **HibernatePrepare / HibernateVerify:** Yalnız guest'te iki aşamalı S4 testi.
  Hazırlık ilk korumalı baseline'ı kaydeder ve `shutdown /h` ister; güç ayarlarını
  değiştirmez. `Prepared` veya `Requested` sonucu kabul değildir. Aynı sahipli
  sanal diski tekrar başlatıp ilk kullanıcı oturumunda doğrulama çalıştırılır.
  Aynı Windows açılışı ve logon oturumu, eşleşen gerçek S4 giriş/uyanma olayları,
  sağlıklı aynı aygıt ve yeniden yapılan PCM16/PCM32 capture testi birlikte
  gereklidir. Soğuk açılış, yeni logon, temizlenmiş olay logu veya yalnızca komutun
  başarılı dönmesi geçiş sağlamaz; eksik platform kanıtı `Findings` olur.
  Logon sürekliliği mevcut token'ın `AuthenticationId` değeriyle doğrulanır;
  etkin Interactive/RemoteInteractive üyeliği gerekir. Servis, anonim kullanıcı,
  ayrılmış kimlik veya yeni oturum kabul edilmez; token yetkisi değiştirilmez.
- **Shutdown:** Yalnız kimliği doğrulanmış guest'in kapanmasını ister. Sürecin
  gerçekten sonlandığını host kontrolüyle ayrıca doğrula.

```powershell
& $runner -VmId $id -Mode HibernatePrepare
# Guest durduktan sonra host'ta aynı diski -BootInstalled ile başlat.
# Guest'in ilk kullanıcı oturumuna dön, ardından:
& $runner -VmId $id -Mode HibernateVerify
```

İlk hibernate baseline'ı yeniden hazırlayarak üzerine yazma. Bir tekrar için
önceki kanıtı koruyan ayrı sahipli laboratuvar/snapshot kullan. Uyku komutu
desteklenmiyorsa bu araç host veya guest güç politikasını otomatik değiştirmez.

## Gerçek sürüm güncellemesi ve geri alma

`driver-vm-version-transition.ps1` ayrı, sabit hash'li **0.5.0.0 ve 0.5.1.0**
paketleri gerektirir. Eski paket gerçek tarihsel kaynak derlemesidir; INF sürümünü
yeniden etiketlemek yeterli değildir. Hazırlanan özel payload'ın manifesti VM
UUID'sini, runner'ı ve iki paketin altışar dosyasını bağlar. Kanonik manifest
anahtarları Windows `\` ayıracını kullanır.

VM kapalıyken `stage-driver-version-transition.ps1 -VmDirectory $vm
-PreparedDirectory $payload` ile doğrulanmış özel payload'ı aktar. Araç disk kilidi
ve süreç kimliğini kontrol eder. Mevcut medya varsa varsayılan olarak reddeder;
`-ReplaceStaged` eski doğrulanmış payload'ı özel geçmiş dizinine taşıyarak yeni
medyayı yerleştirir. Yayınlama başarısızsa ve hedef hâlâ yoksa eski payload geri
getirilir; sonradan oluşan hedefin üzerine yazılmaz. Guest'te
`C:\VeyloVersionTransition` dizinini önce `C:\VeyloLab` ACL'siyle koru, ardından
salt okunur seed'in `version-transition` içeriğini buraya kopyala. `old` ve
`current` alt dizinlerine de `C:\VeyloLab` ACL'sini uygula. Script'i yalnız
yükseltilmiş guest PowerShell'inde tam VM UUID'siyle çalıştır:

```powershell
& 'C:\VeyloVersionTransition\driver-vm-version-transition.ps1' -VmId $id
```

Sıra: eski sürümü zorlayarak baseline hazırlama → güncel sürüme yükseltme →
Windows `DiRollbackDriver` ile gerçek geri alma → güncel sürümü geri yükleme.
Her aşamada aynı aygıtın kurulu sürümü, SYS hash'i ve PCM16/PCM32 capture kontrolü
gerekir. Tamamlanan işlemin ardından en fazla 30 saniyelik salt okunur bekleme,
aynı instance, sürüm, kurulu INF ve SYS hash'i ile çalışan hizmet için iki
ardışık eşleşme ister. Kurulu sürüm ve OEM INF adı `SetupDiGetDevicePropertyW`
üzerinden, en fazla 10 saniyelik ayrı salt okunur çocuk süreçte okunur. WMI
sürümü ayrıca teşhis olarak saklanır; native kimliğin yerine kullanılmaz;
geç gelen eşleşme başarı sayılmaz. İstek kimliği, orijinal cihaz ve korumalı
parent raporu/kilidi eşleşmeden çocuk sonucu kabul edilmez. Zorlanan eski
baseline, native geri alma
sonucu olarak sayılmaz. Eski
paketin yalnız public test sertifikası bu guest'in iki güven deposuna eklenebilir;
host sertifika depoları değişmez. Yeniden başlatma veya belirsiz devam eden işlem
`NeedsReboot`/`Findings` olur; ardından otomatik başka sürücü işlemi başlatılmaz.

Yükseltme, native geri alma veya son geri yükleme `NeedsReboot` verirse raporu ve
seri kaydı koru, guest'i normal kapatıp aynı diski yeniden aç. Korumalı, değişmez
checkpoint aynı run, cihaz, kaynak hash'i ve tamamlanan gerçek capture kayıtlarına
bağlıdır. Yeni açılış doğrulandıktan sonra aynı yürütücüyle açıkça devam et:

```powershell
& 'C:\VeyloVersionTransition\driver-vm-version-transition.ps1' -VmId $id -Operation Resume
```

`Resume` eski baseline'ı yeniden oluşturmaz; bekleyen aşamanın kurulu kimliğini
ve PCM16/PCM32 capture'ını doğrular, ardından kalan gerçek işlemleri yürütür.
Sadece belirli salt okunur preflight hataları aynı checkpoint ile yeniden
denenebilir. Belirsiz mutasyon, başarısız capture, aynı açılış, değişmiş kaynak
ve eksik/değişmiş kanıt kabul edilmez. Otomatik yeniden başlatma yapılmaz.
Eski yürütücüden geçiş yalnız laboratuvarda korunmuş tek 0.5.0 → 0.5.1 yükseltme
run'ının sabitlenmiş rapor hash'i için desteklenir; genel eski rapor içe aktarımı
değildir. Tam başarı dört gerçek faz capture'ı, `DiRollbackDriver` kanıtı ve
güncel sürüme doğrulanmış dönüş gerektirir.

Raporlar `C:\VeyloAcceptance` altındadır; sonuç ve heartbeat COM1 üzerinden VM'nin
`serial.log` dosyasına gider. Yeni açılış seri logu yenileyebildiğinden sonuçları
yeniden başlatmadan önce sahipli proje artifact dizinine kopyala. Çocuk süreç
süre/çıktı sınırı aşarsa, rapor eksikse veya gerçek koşu kısa kalırsa geçiş sayılmaz.

## Değerlendirme lisansı ve geçici bağlantı

Bir saatlik koşu etkin Windows ya da etkin, süresi dolmamış değerlendirme lisansı
gerektirir. Lisansın etkinleştirilmemesi/süresinin dolması saatlik kapanmaya yol
açabilir. Saat değişimi, rearm veya lisans atlatma yapılmaz.
[Microsoft değerlendirme koşulları](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-iot-enterprise-ltsc).

Normal Microsoft etkinleştirmesi için mevcut **kurulu** VM geçici olarak açılabilir:

```powershell
./scripts/start-driver-vm.ps1 -VmDirectory $vm -BootInstalled -EvaluationActivationNetwork
```

Bu seçenek QEMU user-mode NAT açar. Microsoft'a özel bir ağ filtresi değildir;
guest dış ağa, yerel ağa ve guest'in gördüğü host servislerine erişebilir. Gelen
bağlantı yönlendirmesi, bridge veya host dosya paylaşımı eklenmez. Varsayılan ağ
kapalıdır; aktivasyon penceresinden sonra guest'i kapatıp seçenek **olmadan**
soğuk başlat. Capture/Verifier kabul koşularını ağ kapalıyken çalıştır.
[QEMU ağ sınırları](https://www.qemu.org/docs/master/system/invocation.html).

HVCI, Windows uyku/uyanma, farklı sürümlü upgrade/rollback, gerçek alıcı uygulama,
fiziksel uçtan uca gecikme ve Microsoft üretim imzası kendi kanıtlarını gerektirir.
Araçların mevcut olması veya kısa koşunun geçmesi tüm kabulün tamamlandığını göstermez.

HVCI'nin çalışma kanıtı, VBS durumunun `2`, yapılandırılan ve çalışan hizmetlerde
`2` olmasıdır. Registry'nin yazılması bu kanıt değildir. Laboratuvarın platform
şartı `0`, Microsoft'un VBS test yapılandırmasından gelir;
[platform şartları](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/always-encrypted-enclaves-host-guardian-service-register?view=sql-server-ver17)
ve [HVCI doğrulaması](https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity)
ayrı değerlendirilir.

Üretim bridge'i normal I/O için 30 ms, iptal sonrası terminal tamamlanma için
250 ms bekler. Tamamlanmayan istek, buffer ve iki handle süreç ömrü boyunca
korunur; aynı süreçte yeniden bağlantı reddedilir. Sahte OS fixture'ı worker
join'inin bir saniyelik test sınırında tamamlandığını ve geç gelen yazmanın
geçerli belleğe ulaştığını doğrular. Bu, bozuk gerçek kernel veya Windows
zamanlaması altında aynı süreyi garanti etmez.

## Sürücü 0.5.2: isteğe bağlı kernel tanısı

Protokol 1'in ses ve STATUS yapıları korunur. Ek `SES_IOCTL_DIAGNOSTICS`, bağlı
üreticinin kendi handle'ına, sıfır input ile tam 160 bayt çıktı verir. Ayrı tanı
sürümü 1'dir; PCM, pointer veya ses kaydı içermez. CONNECT ölçümleri sıfırlar.
İlk normal akış underrun'u, yazmanın kernel'e varış aralığı ve capture çağrısının
tampon/örnek bilgileri saklanır. Capture boyutu tek `SesBridgeCapture` çağrısıdır;
DMA sarılmasında bölünen bütün position-update işleminin boyutu sayılmaz.
Zamanlar `KeQueryInterruptTime` temelli 100 ns birimindedir; QPC veya ölçülen ses
gecikmesi değildir.

Yalnız tanı koşusunda, mevcut test komutuna şu seçenek eklenebilir:

```powershell
& 'C:\VeyloAcceptance\driver-vm-acceptance.ps1' -VmId $id -Mode Capture -Extended -ProductBridge -KernelDiagnostics -DurationSeconds 60
```

Uygulama varsayılanında ek tanı IOCTL'i yoktur. Tanı modu ilk underrun'da ve her
üretici oturumu sonunda ek sınırlı sorgu yapar; zamanlamaya etkisi olabileceği
için normal kabul kanıtından ayrılır. Snapshot yalnız worker join sonrasında
okunur. Otomatik sorgu, daha sonra istenen son sorgunun biletini onaylayamaz.
Üç sıralı oturumun tamamı geçerli olmalı; son sorguda görülen underrun da kabulü
reddeder. Son sorgu başarısızsa önceki geçerli ilk hata verisi korunur, ancak
kayıt kullanılabilir/başarılı gösterilmez. Bu ölçümler ses boşluğunu düzeltmiş
olduğumuz anlamına gelmez.

[Güncel sonuçlar](VALIDATION.md) · [Kabul durumu](ACCEPTANCE.md)
