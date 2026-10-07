# Third-party notices

SES code: MIT. Third-party components retain their licenses.

* miniaudio 0.11.25, Mackron: https://github.com/mackron/miniaudio . Dual public
  domain/MIT; SES uses MIT. Full notice: licenses/MINIAUDIO-LICENSE in package,
  third_party/MINIAUDIO-LICENSE in source.
* RNNoise v0.2, Xiph.Org contributors: https://github.com/xiph/rnnoise . BSD
  terms: licenses/RNNOISE-COPYING and RNNOISE-AUTHORS in package,
  third_party/rnnoise/COPYING and AUTHORS in source. Source headers retain
  additional author notices. Default generated model from Xiph:
  https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz .
  dependencies.lock.json pins source/model archives and vendored files.
  Local patch: x86cpu.c verifies OSXSAVE/XCR0 before AVX2/FMA selection.
* Microsoft .NET 10.0.11 / WPF / Windows Forms runtime: MIT plus component
  notices. Portable ZIP includes runtime LICENSE.txt and ThirdPartyNotices.txt
  from Microsoft, retained without replacement.
  WPF/WinForms license: licenses/WPF-WINFORMS-LICENSE.
  https://github.com/dotnet/runtime ; https://github.com/dotnet/wpf .
* Build tools are not runtime dependencies: SDK10.0.401, CMake4.4.4,
  LLVM-MinGW20260922, optional Gitleaks8.30.1, publisher downloads verified
  by scripts/bootstrap.ps1 before extraction.

VB-CABLE is separately distributed/licensed by VB-Audio and never bundled.
https://vb-audio.com/Cable/ ; https://vb-audio.com/Services/licensing.htm .
