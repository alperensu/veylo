# Veylo Mikrofon: son sürüme geçiş

Geliştirme sürücüsü **0.5.4.0**, uygulama **0.7.5-dev**, ABI **5**, ses
protokolü **1**. Test imzası ve imzasız Microsoft gönderim taslağı, günlük
Windows'a kurulabilen son sürüm değildir. VB-CABLE günlük yönlendirme olarak kalır.

## Doğrulama sırası

1. Sınırlı PCM paket kuyruğu, first-sample zamanları ve üretici oturum sınırları:
   WDK analizi/derleme, InfVerif/Inf2Cat, Release ve ASan testleri; iki bağımsız
   salt okunur kod/güvenlik incelemesi.
2. İzole Windows'ta gerçek kernel kontrolleri ve normal ürün bridge'iyle kısa
   aktarım; ardından kesintisiz bir saat. Normal akış underrun, paket boşluğu,
   taşma, kuyruk kaybı veya yanlış zaman damgası varsa kabul reddedilir.
3. Son paketle kurulum, yeniden başlatma, kaldırma/yeniden kurma, sürüm
   güncelleme/geri alma, uyku/uyanma ve üretici çökmesi/yeniden bağlantı.
4. Etkin HVCI/Bellek Bütünlüğü ve normal kernel imza politikası.
5. Fiziksel mikrofon → Veylo DSP → Veylo Mikrofon → ayrı alıcı uygulamalar;
   eşzamanlı kullanım, gerçek ses dinleme, CPU/bellek ve fiziksel ek gecikme.
6. Microsoft'tan dönen paket üzerinde aynı kabul ve son dağıtım kurulumu.

Kesin sonuçlar, sürüm ve test süresiyle [VALIDATION.md](VALIDATION.md) içinde
saklanır. Eski sürümde geçen kısa/yaşam döngüsü testi yeni sürümün geçtiği
anlamına gelmez. Bir saat istenmesi veya ara heartbeat, tamamlanan saat değildir.

## Dış ön koşullar

- Mevcut QEMU/WHPX laboratuvarı etkin VBS/HVCI'yi göstermedi; BIOS ve UEFI
  denemelerinde `0xc0000189` sistem yeteneği hatası oluştu. Bu sürücüye özgü
  bir bugcheck kanıtı değildir. Etkin Guest VSM/nested virtualization destekli
  izole Windows ortamı veya ayrı test bilgisayarı gerekir.
- Microsoft Hardware Developer Program/Partner Center organizasyon hesabı,
  kimlik doğrulaması ve gerekli EV sertifikası/güvenli anahtar erişimi gerekir.
  Bu çalışma hesap açmaz, satın alma yapmaz veya özel anahtarı edinmez.
- İmzasız CAB taslağı sabit INF/SYS/CAT ve eşleşen PDB içerir; dosyalar ve
  arşiv içeriği doğrulanır. Sertifika sahibinin güvenli EV imzası ve seçilen
  Microsoft gönderim yolunun gereksinimleri tamamlanmadan gönderilmez.

[Microsoft imzalama rehberi](DRIVER-SIGNING.md), gerçek sertifika ve geri dönen
paket doğrulamasının adımlarını içerir. Microsoft imzası ses kalitesi veya
uygulama uyumluluğu kabulünün yerine geçmez. Ana bilgisayarda test signing,
Secure Boot, Bellek Bütünlüğü, ses varsayılanları ve sertifika deposu değiştirilmez.
