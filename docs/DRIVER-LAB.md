# Veylo Mikrofon: izole laboratuvar ve geçiş kapıları

Bu rehber günlük bilgisayarda uygulanmaz. Sürücü 0.5.1.0 geliştirme çıktısıdır;
Microsoft imzası ve çalışan Windows hedefinde kabul kanıtı yoktur. Veylo'nun
normal kurulum paketi sürücüyü içermez. Şimdilik VB-CABLE ile devam edilir.

## Hazırlanan çıktılar

Geliştirme bilgisayarında (hiçbiri sürücü kurmaz):

```powershell
./scripts/build.ps1
./scripts/test.ps1 -Headless
./scripts/build-driver.ps1
./scripts/package-driver.ps1
./scripts/driver-readiness.ps1 -OutFile artifacts/driver-readiness/preflight.json
```

EWDK zaten yoksa yalnız resmi, checksum sabitlenmiş kit için
`build-driver.ps1 -DownloadKit` kullanılır. ZIP adı
`Veylo-driver-0.5.1.0-isolated-lab.zip` olur. INF/SYS/CAT ve lisans hash'leri
manifestte doğrulanır; eski manifestin kendisi hash listesine girmez.
Lab test aracı ve rehberler ayrı arşiv girdileridir; ZIP'in tamamının SHA-256
değeri yanındaki dosyadadır. Hash kontrolü imza veya kernel kabulü yerine geçmez.

## Eksik dış ön koşullar

1. Ayrı bir Windows 10/11 x64 hedefi: VM veya test bilgisayarı; VM için geri
   dönüş snapshot'ı. İşletim sistemi lisansı ve kurulum medyası gerekir.
2. Hedefe uygun test sertifikası ve WDK dağıtım/debug ortamı. Sertifika ve
   test politikaları yalnız izole hedefte yapılandırılır. Normal kurulum
   yardımcısı test imzalarını kabul etmez.
3. Günlük dağıtım için Hardware Dev Center/EV sertifikası ve uygun Microsoft
   imzalama süreci. Satın alma, hesap doğrulama ve sertifika özel anahtarına
   erişim bu otomatik geliştirme akışında yapılmaz.

Mevcut ana makinedeki hipervizörün varlığı, çalışan/provision edilmiş bir
test VM'sinin varlığı anlamına gelmez. Windows Home'da Hyper-V yönetim
komutlarının yokluğu da başka sanallaştırıcıların olmadığı iddiası değildir.
Disk/VM kaynakları `driver-readiness.ps1` ile salt okunur raporlanır.

## Hedefte yükleme ve ilk kabul

Önce boş snapshot al ve Microsoft'un hedef provisioning/test-signing
prosedürünü yalnız bu hedef için tamamla. INF'nin donanım kimliği
`ROOT\SES_MICROPHONE` olan cihazı resmi WDK araçlarıyla kur; normal Veylo
yardımcısının Microsoft imzası kontrolünü değiştirme veya atlatma.

Veylo kapalıyken ve yalnız hedefte:

```powershell
./ses_driver_lab_tests.exe --isolated-lab
```

Bu araç özel üretici IOCTL'lerini test eder; KS biçim müzakeresi, gerçek
WaveRT zamanlaması ve HVCI/Verifier için ayrıca aşağıdaki kontroller gerekir.
Araçtaki `--isolated-lab` bir onay bayrağıdır; sanal makine izolasyonu yaratmaz.

## Ölçülecek kabul matrisi

| Alan | Kontrol | Gerekli kanıt |
| --- | --- | --- |
| KS formatları | 48 kHz mono PCM16/PCM32; yanlış cbSize/FormatSize/blok hizası/bytes-per-second reddi | Gerçek kernel müzakeresi ve debugger/Verifier logu |
| Üretici sınırı | Kısa/uzun boyut, sürüm, sahiplik, replay, reserved ve bilinmeyen IOCTL | Lab aracı sonucu; yalnız sentetik birim testi yeterli değildir |
| Yaşam döngüsü | Başlat, stop/start, çıkar, surprise/remove, açık handle, yeniden kur, ikinci adapter reddi | PnP logu; yükleme/kaldırma sonrası artık endpoint/servis yok |
| Ses | Çıkış açılmadan, tüketici kapat/aç, uygulama çökmesi, 100 ms üzeri kesinti | Sessizlik; eski ses tekrar edilmez |
| Zamanlama | PCM16/32, küçük DPC parçaları, 1–2 ms jitter, farklı saatler ve bir saatlik çalışma | Gerçek timestamp/ses kaydı/tampon sayaçları |
| Uyku/uyanma | Uzun bekleme, saat gerilemesi, çıkar/tak | Eski DMA sesi yok; zaman/bytes hesapları taşmaz |
| HVCI/Verifier | Yalnız SesMicrophone.sys; özel havuz, IRQL, I/O, deadlock, security/code integrity | Bugcheck olmaması ve loglar; kaynakta NX kullanımı yeterli değildir |
| Paylaşımlı capture | İki farklı alıcı, kayıt/toplantı/yayın ve oyun uygulamaları | Aynı işlenmiş giriş; render endpoint yok |
| Kullanıcı alanı | Açılış/gizli açılış, mikrofon değişimi/kaybı, mute/bypass, çıkış bırakma | Akış devamı ve hata durumları |
| İmzalı teslimat | Gerçek Microsoft kataloğu, üyelik, kernel policy, install/update/rollback/remove/reboot | Paket hash'i, OS build ve resmi imza doğrulaması |

Test sonuçlarını OS build, paket SHA-256, VM/fiziksel cihaz ve yöntemle birlikte
kaydet. Başarısızlıkları silme; snapshot geri dönüşünü kullan. Testleri yalnız
uyumlu hedefte çalıştır. Driver Verifier'ı tüm sürücülere veya günlük oyun
bilgisayarına uygulama.

## Günlük geçiş

İzole kabul ve Microsoft imzasından sonra üretim paketi ayrıca hazırlanır.
Güncel normal Setup üretim sürücüsünü paketlemez; bu ayrım henüz kapatılmamıştır.
Veylo çıkışı açıkça **Veylo Mikrofon**, alıcı mikrofonu **Veylo Mikrofon** seçilir.
Varsayılan Windows cihazları değiştirilmez. Aynı işlenmiş mikrofon hoparlöre
sürekli verilmez; kullanıcının başlattığı önizleme veya Windows mikrofon
dinlemesi yine sistem sesine dahil olabilir.

Kaynaklar: [Hedef provisioning](https://learn.microsoft.com/en-us/windows-hardware/drivers/gettingstarted/provision-a-target-computer),
[Microsoft imzalama seçenekleri](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings),
[Driver Verifier](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/driver-verifier).
