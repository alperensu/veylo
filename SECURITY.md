# Güvenlik politikası / Security policy

## Güvenlik açığı bildirimi

Veylo herkese açık bir depodur. Güvenlik açığı, kişisel veri sızıntısı veya
kernel sürücüsüyle ilgili hassas bir bulgu için **herkese açık Issue açma**.
[GitHub'ın özel güvenlik bildirimi kanalını kullan](https://github.com/alperensu/veylo/security/advisories/new).
GitHub hesabınla oturum açman gerekir; bu kanala yalnız yetkili bakımcılar erişir.

Etkilenen sürümü, beklenen/gerçekleşen davranışı ve kişisel veri içermeyen
tekrarlama adımlarını belirt. Token, parola, gerçek konuşma, kullanıcı ayar dosyası
veya cihaz kimliği gönderme. Yalnızca sana ait ya da açıkça yetkilendirilmiş
test ortamlarında doğrulama yap. Yanıt veya düzeltme süresi taahhüdü verilmez.

Normal ses, kurulum veya arayüz sorunları için [hata bildirimi](https://github.com/alperensu/veylo/issues/new/choose) kullanabilirsin.

## Sürüm kapsamı

Proje şu anda `-dev` geliştirme sürümleri yayımlar. İncelemeler güncel `main`
ve en yeni geliştirme sürümüne odaklanır; eski sürümlere düzeltme garantisi veya
üretim güvenlik sertifikası sunulmaz. Bildiriminde tam sürümü yaz.

## Gizlilik ve sınırlar

- Ses işleme yereldir; hesap, bulut ses servisi veya ses telemetrisi bulunmaz.
- Karşılaştırma örneği RAM'de tutulur; WAV yalnız açık dışa aktarım isteğiyle yazılır.
- Paylaşılan JSON profilleri ses kaydı ve cihaz kimliği içermez.
- Uygulama yönetici olmadan çalışır. Ayrı sürücü kurulumu yönetici izni isteyebilir.
- Normal Setup kendi kernel sürücümüzü içermez. TEST-SIGNED sürücü yalnız
  izole, ayrıca yetkilendirilmiş Windows laboratuvarı içindir.
- Host test-signing, Secure Boot veya Bellek Bütünlüğünü kapatmak normal kurulumun parçası değildir.

[Teknik güvenlik kapsamı ve geçmiş inceleme notları](docs/SECURITY-SCOPE.md) ·
[Güncel kabul durumu](docs/ACCEPTANCE.md) · [Sürücü laboratuvarı](docs/DRIVER-LAB.md)

## Reporting in English

Please use [private vulnerability reporting](https://github.com/alperensu/veylo/security/advisories/new)
for sensitive findings, rather than public Issues. Include the exact version,
impact and a minimal reproduction without credentials, personal recordings,
device identifiers or local user state. Only test systems you own or are
explicitly authorized to test. No response-time or fix-time guarantee is offered.

Veylo is in development. A passing test or review is scoped evidence, not a
production security certification. The virtual microphone package is currently
test-signed for isolated labs, not Microsoft production signed.
