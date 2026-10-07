# SES

Yerel Windows mikrofon iyileştirme uygulaması: gürültü azaltma, yavaş ses
dengeleme, dört bant EQ, de-esser, kompresör ve −1dBFS limiter. **Doğal**,
**Net Konuşma**, **Sıcak Ses**, **Yayın** profilleri uygulamaya dahildir.

ZIP'i tamamen çıkar, **SES.exe** aç, fiziksel mikrofonunu seç. Doğal profil ve
Kalibrasyon ile başla. Discord/Valorant aktarımı ayrı VB-CABLE kurulumu gerektirir:
[kurulum rehberi](docs/INSTALL.md). Sürücü olmadan yerel test/kalibrasyon/A-B
dinleme çalışır. SES Windows mikrofon seviyesini değiştirmez.

İnternet, hesap, GPU, abonelik gerekmez. Ses yüklenmez. En fazla20sn örnek
RAM'de tutulur; WAV yalnızca açık dışa aktarımda yazılır. Türkçe/İngilizce,
tray, Ctrl+Alt+M sustur / Ctrl+Alt+B bypass. Kullanıcı profilleri sürümlü JSON;
paylaşım dosyalarında cihaz/ses kaydı yoktur. MIT; GitHub'a yayımlanmadı.

## Geliştirme

Windows x64 PowerShell:

```powershell
./scripts/build.ps1
./scripts/test.ps1
./scripts/test.ps1 -Live  #32sn mikrofon işleme,2sn RAM örneği; oynatmaz/kaydetmez
./scripts/build.ps1 -Sanitize
./scripts/test.ps1 -Sanitize
./scripts/security.ps1
./scripts/package.ps1
```

İlk build resmi SDK/CMake ve LLVM-MinGW'yi doğrulayıp `.tools` altına kurar;
Windows'a Visual Studio/sürücü kurmaz. Sonraki build'lerde indirme tekrarlanmaz.
Kaynak/model checksum'ları [dependencies.lock.json](dependencies.lock.json).
Güvenlik komutu gerektiğinde ayrı Gitleaks aracını indirir.

`native/`: C API/DSP/WASAPI; `app/Ses.Core/`: doğrulama, profiller, kalibrasyon,
P/Invoke; `app/Ses.Desktop/`: WPF/tray; `tests/`: managed regresyonlar.
Paketler `dist/` içinde. [Doğrulama](docs/VALIDATION.md),
[mimari](docs/ARCHITECTURE.md), [lisanslar](THIRD_PARTY_NOTICES.md).

## English

Offline Windows microphone processing with four presets. Extract the complete
portable ZIP, run SES.exe and select EN. Choose physical microphone → CABLE Input
in SES; choose CABLE Output in Discord/Valorant. Install VB-CABLE separately from
its official site. Without the driver, local calibration and loudness-matched
A/B still work. No recordings leave the computer; WAV export is explicit.
Closing/minimizing keeps SES in the tray; tray Exit stops it. Shortcuts:
Ctrl+Alt+M mute / Ctrl+Alt+B bypass. Source MIT; third-party notices apply.
