> Veylo 0.5.2 varsayılan olarak kurulu VB-CABLE kullanır. Bu rehber yalnızca
> çıkış listesinden seçilen Veylo Mikrofon geliştirme sürücüsü içindir.

# Veylo Mikrofon — sürücü geliştirme ve kurulum

## Mevcut durum

Veylo-driver-0.5.0-development.zip imzasız geliştirme çıktısıdır; günlük bilgisayara
yüklenmemelidir. SYS, INF ve imzasız katalog derlendi. Uygulama ZIP'i üretim
sürücüsü içermez, yalnızca yerel işleme açar. Kur/güncelle üretim paketi yokken
devre dışıdır. Laboratuvar, Microsoft imzası ve gerçek oyun testleri tamamlanmadı.

## Üretim imzalı paketle normal kullanım

Doğrulanmış SesMicrophone.inf, .sys, .cat uygulamanın driver klasöründe bulunur.
Veylo → Veylo sürücüsü → Kur/güncelle. Yalnızca yardımcı UAC ister; Veylo istemez.
Yeniden başlatma gerekiyorsa gösterilir, otomatik yapılmaz. Discord ve Valorant
girişi Veylo Mikrofon seçilir. Windows varsayılanları değiştirilmez.

Geri al önceki Driver Store sürümünü kullanır; önceki sürüm yoksa hata gösterir.
Kaldır yalnızca tam ROOT\SES_MICROPHONE donanım kimliğiyle eşleşen cihaz ve
ilişkili paketi yönetir. Sürücü çıkarılırsa uygulama yerelde işlemeye devam eder.

Yardımcı komutları: Veylo.DriverSetup.exe status / install / remove / rollback.
Status yönetici istemez; diğerleri gerektiğinde UAC açar. Kullanıcıdan INF yolu
veya kabuk komutu kabul edilmez. Paket derlenmiş Veylo INF'iyle birebir eşleşmelidir.
Yükseltilmiş işlem paketi Program Files altında yeni klasöre alır; Microsoft
Windows katalog imzasını/sertifika zincirini kontrol eder. Windows kurulum API'si
katalog üyeliği/kernel imza politikasını ayrıca doğrular. İmzasız veya test imzalı
paket normal yardımcı tarafından reddedilir. Sertifika iptal kontrolü kurulumda
ağ isteyebilir; ses motoru tamamen yereldir.

## Derleme

    ./scripts/build.ps1
    ./scripts/test.ps1
    ./scripts/build-driver.ps1 -DownloadKit
    # Zaten bağlı EWDK:
    ./scripts/build-driver.ps1 -EwdkRoot D:\
    ./scripts/build.ps1 -Sanitize
    ./scripts/test.ps1 -Sanitize
    ./scripts/security.ps1
    ./scripts/package.ps1 -SkipBuild

EWDK 26100.6584 / VS 2022 Build Tools 17.14.5 / MSVC 14.44.35207 sabitlenmiştir.
ISO 20,002,537,472 bayt; driver/ewdk.lock.json SHA256 içerir. Kit dağıtıma konmaz.
SYSVAD commit ve 112 kaynak dosya checksum'ı driver/upstream.lock.json.
Adaptasyon scripts/prepare-driver.py tarafından build/driver/sysvad'a üretilir;
orijinal kaynak/notice değişmez. Yalnızca bir capture endpoint, integer PCM
köprüsü ve nonpaged NX tahsis; ses DSP'si kernel'e taşınmaz.

WDK önerilen kurallarla statik analiz, W4/WX, CFG/Spectre, InfVerif /w ve Inf2Cat
derleme sürecindedir. Build hiçbir sürücüyü kurmaz, imzalamaz veya güvenlik ayarı
değiştirmez. Günlük bilgisayarda test signing, Secure Boot ve Bellek Bütünlüğü
ayarları değiştirilmemiştir.

## Ayrı Windows laboratuvarı

Windows 10 2004+ / Windows 11 x64 için ayrı VM veya test bilgisayarı ve geri
dönüş snapshot'ı gerekir. Test sertifikası ve gerekiyorsa test signing yalnızca
bu ortamda kullanılmalıdır. Resmî WDK/DevCon ve Microsoft test sertifikası
prosedürüyle yükle; normal Veylo kurulum yardımcısını bypass etme. Bu proje için
henüz laboratuvar bulunmuyor.

Uygulama kapalıyken sadece laboratuvarda:

    ./build/bin/ses_driver_lab_tests.exe --isolated-lab

Kısa/bozuk boyut, sürüm/format, bağlantısız yazma, ikinci sahip, replay, bilinmeyen
IOCTL ve cleanup/reconnect testleri yapar. Normal CTest'e dahil değildir.
Driver Verifier yalnızca SesMicrophone.sys için laboratuvarda çalıştırılır:
standart, özel havuz, IRQL, I/O, deadlock, security ve code integrity kontrolleri.
VM sorununda snapshot'a dön. HVCI açık ortamda ayrıca doğrula; NX/integer kod
ve başarılı derleme tek başına HVCI uyumluluğu kanıtı değildir.

Kabul matrisi: açılış/gizli açılış, eski ayarlar, iki mikrofon, çıkar/tak,
uyku/uyanma, üretici kapat/çökert, kur/güncelle/geri al/kaldır/reboot; PCM16/32;
gerçek bir saatlik saat/tampon testi; starvation/bağlantı kopunca sessizlik,
eski ses tekrarı yok; Discord + Valorant eşzamanlı giriş; tüm ekran + sistem
sesinde ikinci sürekli mikrofon yok. Türkçe/hafif konuşma, fan/klavye/mouse,
clipping dinleme testi; Ryzen 5 7600 CPU/RAM/gecikme ve oyun frametime ölçümü.

## Microsoft imzası ve günlük teslimat

Hardware Dev Center hesabı ve EV sertifikası henüz yok; satın alma ve yayımlama
bu göreve dahil değildir. Kamuya/günlük kullanıma çıkış için uygun HLK/Windows
Hardware Compatibility imzalama yolu ve gönderim koşulları tamamlanmalıdır.
Attestation test imzası bu projenin günlük kullanım kabulü değildir.

* [Microsoft imzalama seçenekleri](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings)
* [SYSVAD açıklaması](https://github.com/microsoft/Windows-driver-samples/blob/2dc3fd3a0cc84a2933f2194e7ec0871584979071/audio/sysvad/README.md)
* [Vanguard gereksinimleri](https://support.riotgames.com/en-us/riot/performance/vanguard-security-requirements)

Microsoft imzası Valorant uyumluluğu garantisi değildir; imzalı paketle ayrıca
gerçek oyun testi gerekir. Kabul raporu OS build, cihaz, paket hash'i, test
sonucu ve ölçüm yöntemini içermelidir. Doğrulanmayan testler başarı sayılmaz.
