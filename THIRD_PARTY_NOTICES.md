# Third-party notices

Veylo code: MIT. Third-party components retain their licenses.

* Microsoft Windows-driver-samples / SYSVAD, commit
  2dc3fd3a0cc84a2933f2194e7ec0871584979071: MIT.
  Original notices and LICENSE remain in driver/upstream/sysvad.
  driver/upstream.lock.json pins the archive and all 112 retained files.
  scripts/prepare-driver.py makes the capture-only, integer PCM bridge adaptation
  reproducibly under build/driver/sysvad; the upstream snapshot remains untouched.
  https://github.com/microsoft/Windows-driver-samples/tree/2dc3fd3a0cc84a2933f2194e7ec0871584979071/audio/sysvad
* EWDK 26100.6584 / VS 2022 Build Tools 17.14.5 is a build-only Microsoft toolchain.
  driver/ewdk.lock.json pins its ISO; it is not redistributed in Veylo packages.
  Its Microsoft Enterprise WDK license applies, not Veylo's MIT license.
  https://learn.microsoft.com/en-us/legal/windows/hardware/enterprise-wdk-license-2022

* miniaudio 0.11.25, Mackron: https://github.com/mackron/miniaudio . Dual public
  domain/MIT; Veylo uses MIT. Full notice: licenses/MINIAUDIO-LICENSE in package,
  third_party/MINIAUDIO-LICENSE in source.
* RNNoise v0.2, Xiph.Org contributors: https://github.com/xiph/rnnoise . BSD
  terms: licenses/RNNOISE-COPYING and RNNOISE-AUTHORS in package,
  third_party/rnnoise/COPYING and AUTHORS in source. Source headers retain
  additional author notices. Default generated model from Xiph:
  https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz .
  dependencies.lock.json pins source/model archives and vendored files.
  Local patches: x86cpu.c verifies OSXSAVE/XCR0 before AVX2/FMA selection.
  denoise.c backports the energy-aware transient gain-decay fix from
  Xiph.Org commit bb18d2f00bf4d4f279b0779439afa207b6ea0153. BSD notices retained.
  https://github.com/xiph/rnnoise/commit/bb18d2f00bf4d4f279b0779439afa207b6ea0153
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
