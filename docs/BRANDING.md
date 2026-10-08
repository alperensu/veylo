# Veylo — ad değişikliği

Uygulamanın yeni adı **Veylo**. Pencere, bildirim alanı, kullanıcı mesajları,
Türkçe/İngilizce marka metinleri, preset dışa aktarma adı, exe, sürücü yardımcısı,
geliştirme sürücüsünün görünen adı ve yeni ZIP paketleri bu adı kullanır.

Yeni uygulama: **Veylo.exe**. Yardımcı: **Veylo.DriverSetup.exe**.
Yeni geliştirme sürücüsünün cihaz adı: **Veylo Mikrofon**. VB-CABLE cihaz adları
üçüncü taraf adlarıdır; CABLE Input/CABLE Output değişmez.

## Eski kurulumlarla uyumluluk

- Ayarlar, profiller ve cihaz kalibrasyonları aynı
  `%LOCALAPPDATA%\SES\state.json` dosyasından okunur. Veri taşınmaz veya silinmez.
- Windows ile başlatma tercihi eski `Run\SES` anahtarını kullanmaya devam eder.
  Açık tercih, yeni uygulama normal olarak başlatıldığında güvenli sürüm politikası
  üzerinden `Veylo.exe --minimized` hedefine güncellenebilir. Kapalı tercih açılmaz.
- Tek örnek mutex kimliği korunur; eski SES ile Veylo aynı anda normal oturum
  başlatamaz. Geçiş için eski uygulamayı bildirim alanından kapatıp Veylo.exe aç.
- Native DLL adı, C ABI sembolleri, JSON şeması, kaynak namespace/proje yolları,
  sürücü donanım kimliği `ROOT\SES_MICROPHONE`, servis ve IOCTL yolu korunur.
  Bunlar teknik uyumluluk kimlikleridir; yeni görünen marka değildir.
- Sürücü dosyaları `SesMicrophone.inf/.sys/.cat` adlarını korur. Yeniden hazırlanan
  INF'in görünen adı Veylo'dur. Önceden kurulu cihazların adları bu dosya değişikliği
  ile Windows'ta kendiliğinden değiştirilmez; imzalı sürücü güncellemesi gerekir.
- Eski paketler ve tarihsel test raporları özgün isimleriyle korunur. Üçüncü taraf
  kaynakları ve lisans bildirimlerindeki sahip adları değiştirilmez.

Ad değişikliği DSP ayarlarını veya gürültü temizleme davranışını değiştirmez.
Sürücü imzası/laboratuvarı ayrı, ertelenmiş geliştirme çalışmasıdır.
