# Sık sorulanlar

[← Veylo](../README.md) · [Kurulum rehberi](INSTALL.md) · [Doğrulanan kapsam](ACCEPTANCE.md)

## Sesim kullandığım uygulamaya gitmiyor

Veylo'da giriş **fiziksel mikrofonun**, çıkış **VB-CABLE / CABLE Input** olmalı.
Diğer uygulamanın mikrofon girişi **CABLE Output**, ses çıkışı ise normal
kulaklığın/hoparlörün olmalı. Bu yönlendirme kayıt, yayın, toplantı ve iletişim
uygulamalarında aynı mantıkla kullanılır; uyumluluk her uygulamada ayrıca sınanmalıdır.

Veylo'da giriş ve çıkış ölçerlerini kontrol et. **Sustur** kapalı olsun;
basılı tutarak konuşma açıksa seçili tuşu basılı tut. “Yalnızca yerel işleme”
diğer uygulamalara ses göndermez. VB-CABLE eksikse resmî kurulumunu tamamla,
gerekirse Windows'u yeniden başlat ve **Cihazları yenile** seç.

Kayıtlı cihaz kaybolursa Veylo başka mikrofona/çıkışa kendiliğinden geçmez.
Kendi cihazını bağla veya yeni cihazı açıkça seç. Windows mikrofon izinlerinde
masaüstü uygulamalarına erişim verilmiş olmalı.

## Klavye veya masa sesi hâlâ duyuluyor

Önce diğer uygulamanın girişinin fiziksel mikrofon yerine **CABLE Output**
olduğunu kontrol et. Veylo'da **Orijinal ses** kapalı ve gürültü azaltma açık olsun.
Gerekirse **Güçlü temizlemeyi uygula** seçeneğini dene: ham sesin karışıma
geri eklenmesini kaldırır, otomatik eşikli yumuşak expander uygular.
Mevcut ton ve dengeleme korunur; kayıt/kalibrasyon sırasında uygulanmaz.

Bu ayar bütün darbeleri veya konuşurken yapılan her tuş vuruşunu silemez.
Mikrofonu klavyeden/masadan uzaklaştırmak ve titreşimi azaltmak yardımcı olabilir.
Kendi sesini, özellikle kısık kelimeleri ve cümle başlangıçlarını tekrar dinle;
kesilme oluyorsa duyarlılık veya temizleme ayarını yumuşat.

## Kalibrasyon ne kadar sürüyor?

Varsayılan hızlı ölçüm **10 saniye**: 2 saniye ortam, 8 saniye doğal konuşma.
Seçtiğin EQ/ton korunur; seviye ve kompresör önerileri oluşturulur.
İsteğe bağlı ayrıntılı ölçüm **20 saniye** sürer. Yetersiz konuşma, clipping
veya kirli ortam örneğinde öneri reddedilebilir. Önce dinle, sonra uygula.
Windows mikrofon seviyesi kendiliğinden değiştirilmez.

## Hangi profille başlamalıyım?

Doğal en hafif başlangıçtır. Net Konuşma açıklık, Sıcak Ses dolgunluk,
Yayın daha parlak ton ve sıkı dinamikler, Podcast — Tok ve Net ise dolgun/net
bir karakter ve güçlü temizleme sunar. Sonuç mikrofona ve konuşmana bağlıdır.
Profil farkını dinlerken **Orijinal ses** kapalı olsun. Aynı RAM örneğini
Profiller sayfasında ham/seçili profil olarak, ses yüksekliği eşlenmiş dinleyebilirsin.

Güncelleme kayıtlı ayarlarını değiştirmez. Yeni fabrika profil değerlerini almak
için başka hazır profili, ardından istediğin profili seç. Kalibrasyon silinmez.

## Pencereyi kapatınca işleme durur mu?

Hayır. X düğmesi bildirim alanına gizler; işleme sürer. Tam kapatmak için
bildirim alanındaki **Veylo'dan çık** komutunu kullan.
Açılışta kayıtlı mikrofon ve ayarlarla işleme otomatik başlar.
Windows ile açılma isteğe bağlıdır; etkinse gizli açılışta da işlenir.

## Ekran paylaşımında sesim iki kez duyuluyor

Windows varsayılan çıkışını **CABLE Input** yapma. **CABLE Output → Bu aygıtı dinle**
kapalı olsun. Diğer uygulamanın çıkışı normal kulaklığın olmalı.

Bu kontroller tek başına ekran paylaşımında çift sesi engelleme garantisi değildir.
Veylo sürekli mikrofon sesini fiziksel hoparlöre göndermez; VB-CABLE yolunda
**CABLE Input'a bir WASAPI oynatma akışı** açar. Discord'un tüm ekranla birlikte
sistem sesini yakalaması bu akışı da içerebilir. Dinleme kapalıyken ve kendi
sesini kulaklıkta duymuyorken de karşı tarafa ikinci bir ses gidebilir.
Discord'un kullandığı yakalama yolu bu kurulumda ayrıca doğrulanmalıdır.

**Sınanabilecek sürücü ayarı:** Kurulu VB-CABLE sürümü 3.3.1.7 ise üreticinin
[resmî kılavuzu, s.13](https://vb-audio.com/Cable/VBCABLE_ReferenceManual.pdf),
kontrol panelinde varsayılan açık **Loopback** seçeneğini belgeler. Bu seçenek
CABLE Input oynatma ucunun ayrıca yakalanması içindir; Windows'un **Bu aygıtı
dinle** özelliğiyle aynı değildir. `VBCABLE_ControlPanel.exe` içindeki Loopback
seçeneğini kapatıp paylaşımı yeniden başlatarak karşılaştırabilirsin. Veylo çıkışı
**CABLE Input**, görüşme mikrofonu **CABLE Output**, diğer uygulamaların çıkışı
normal kulaklığın olarak kalsın. Hem mikrofonun hem diğer uygulamaların seslerinin
karşıya ulaştığını ve mikrofonun paylaşımda ikinci kez duyulmadığını kontrol et.
Değişiklik işe yaramazsa önceki Loopback ayarını geri al. Bu ayarın süreç bazlı
yakalamayı da dışladığı belgelenmez; gerçek Discord sonucu henüz doğrulanmadı.
Veylo bu üçüncü taraf sürücü ayarını kendiliğinden değiştirmez.

[Discord'un resmî rehberi](https://discord.com/blog/how-to-stream-to-discord-from-desktop-or-mobile),
uygulama paylaşımında seçilen uygulamanın, tüm ekran + sistem sesi paylaşımında
ise uygulamaların seslerinin aktarıldığını açıklar. Geçici seçenekler, tek
uygulamayı sesiyle paylaşmak veya tüm ekranı sistem sesi kapalı paylaşmaktır;
sesli görüşmenin mikrofon girişi **CABLE Output** olarak kalabilir.

**Tüm ekran ve diğer bütün uygulamaların sesleri gerekli olduğunda bu geçici
seçenekler ihtiyacı karşılamaz.** Mevcut VB-CABLE aktarımında Veylo sesini
Discord'un yakalamasından dışlayan doğrulanmış bir çözüm yok. Başka bir
uygulamanın süreç sesini dışlama kararı yakalama yapan taraftadır
([Microsoft süreç loopback API'si](https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ne-audioclientactivationparams-process_loopback_mode)).
Susturmak veya işlemeyi kapatmak bu koşul için bir çözüm değildir.

Açıkça oynattığın karşılaştırma veya Windows dinleme özelliği ayrıca sistem
sesine karışabilir; karşılaştırmayı bitir ve dinlemeyi kapat. Kendi Veylo Mikrofon
aktarımı normal oynatma akışı açmaz, ancak sürücü günlük kullanıma hazır değildir
ve gerçek ekran paylaşımı kabulü henüz yapılmamıştır.

## Birden fazla gürültü azaltmayı açmalı mıyım?

Önce Veylo'yu tek başına dinle. Karşılaştırmada kullandığın uygulamanın ek
gürültü azaltma/otomatik kazancını kapat; üst üste işleme konuşmayı bozabilir.
Son ayarları gerçek kullanımında dinleyerek doğrula.

## İnternet, hesap veya GPU gerekiyor mu?

Günlük ses işleme için hayır. İndirme, güncelleme dosyasını edinme ve geliştirme
araçlarını hazırlama internet gerektirebilir. Örnekler RAM'de tutulur;
ses dosyası yalnız **WAV dışa aktar** seçersen yazılır.

## VB-CABLE ücretsiz mi; pakete dahil mi?

VB-CABLE ayrı bir üçüncü taraf ürünüdür, Veylo'ya dahil edilmez.
Güncel indirme ve kullanım koşulları için [resmî VB-Audio sayfasını](https://vb-audio.com/Cable/) incele.
Veylo kaynak kodunun MIT lisansı VB-CABLE'ın lisansını değiştirmez.

## Kendi Veylo Mikrofon sürücüsünü kurabilir miyim?

Günlük bilgisayar için henüz hazır değil. Windows 11 VM'de kısa kernel ve
PCM16/PCM32 testleri normal koşulda ve standart Driver Verifier açıkken geçti;
Microsoft üretim imzası, HVCI, uzun süreli testler ve alıcı uygulama kabulü eksik.
TEST-SIGNED paket yalnız ayrı, açıkça yetkilendirilmiş bir laboratuvar içindir.
Normal Setup bunu kurmaz; günlük kullanımda VB-CABLE kullan.
[Laboratuvar rehberi](DRIVER-LAB.md) ve [güncel rapor](VALIDATION.md).

## Windows Setup uyarı veriyor

Geliştirme kurulum dosyası kod imzalı değildir; Windows tanınmayan yayıncı
uyarısı gösterebilir. Güvenlik ayarlarını kapatma. Yalnız
[resmî GitHub sürümünü](https://github.com/alperensu/veylo/releases) indir ve
yanındaki `.sha256` dosyasıyla hash'i karşılaştır:

```powershell
Get-FileHash -LiteralPath .\Veylo-0.7.5-dev-win-x64-Setup.exe -Algorithm SHA256
```

Farklıysa dosyayı çalıştırma; kaynağı ve indirmeyi tekrar kontrol et.

## Nereden destek alabilirim?

[Hata, özellik veya kullanım sorusu](https://github.com/alperensu/veylo/issues/new/choose)
bildirebilirsin. Windows sürümü, Veylo sürümü, mikrofon modeli ve kişisel
veri içermeyen tekrarlama adımları yeterli bir başlangıçtır. Ses kayıtlarını,
özel konuşmaları ve ayar dosyanı ekleme. Hassas güvenlik bulguları için
[özel bildirim kanalını](https://github.com/alperensu/veylo/security/advisories/new) kullan.
