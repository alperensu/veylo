using System.Buffers.Binary;
using System.Formats.Asn1;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

// This tool never opens a Windows certificate store. Verification checks cryptography,
// an explicit public certificate, and catalog membership, not Windows kernel acceptance.
try
{
    if (args.Length != 2 || args[0] is not ("create" or "verify" or "sign-sys-digest" or "sign-cat-digest"))
        throw new InvalidDataException("Use create, verify, sign-sys-digest or sign-cat-digest with one directory.");
    string directory = Path.GetFullPath(args[1]);
    CheckPath(directory, true);
    if (args[0] == "create") Create(directory);
    else if (args[0] == "verify") Verify(directory);
    else SignDigest(directory, args[0] == "sign-sys-digest" ? "SesMicrophone.sys" : "SesMicrophone.cat");
    return 0;
}
catch (Exception exception) when (exception is CryptographicException or IOException or ArgumentException or UnauthorizedAccessException or AsnContentException)
{
    Console.Error.WriteLine("Lab certificate/signature operation rejected: " + exception.GetType().Name + ": " + exception.Message);
    return 1;
}

static void CheckPath(string path, bool directory)
{
    string full = Path.GetFullPath(path);
    if (full.Length < 3 || !char.IsAsciiLetter(full[0]) || full[1] != ':' || full[2] != '\\' || full.AsSpan(3).Contains(':'))
        throw new InvalidDataException("Only local paths without alternate data streams are allowed.");
    for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
        if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Reparse points are not allowed.");
    if (directory != Directory.Exists(path)) throw new InvalidDataException("Wrong path type.");
    if (!directory && (new FileInfo(path).Length is <= 0 or > 16 * 1024 * 1024))
        throw new InvalidDataException("File size is outside the bound.");
}

static byte[] ReadFile(string directory, string name)
{
    string path = Path.Combine(directory, name);
    CheckPath(path, false);
    return File.ReadAllBytes(path);
}

static void Create(string directory)
{
    if (Directory.EnumerateFileSystemEntries(directory).Any()) throw new InvalidDataException("Private directory must be empty.");
    CheckPrivateDirectory(directory);
    using var rsa = RSA.Create(3072); // Unnamed, process-local key; no persisted Windows key container.
    var request = new CertificateRequest("CN=Veylo Isolated Lab TEST ONLY", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
    request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
    request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.3") }, true));
    request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
    using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(90));
    byte[] pfx = certificate.Export(X509ContentType.Pfx, string.Empty);
    try
    {
        // No password is placed in a child command line. The short-lived PFX inherits
        // the owner/SYSTEM-only directory ACL and is deleted before any ZIP is written.
        using var output = new FileStream(Path.Combine(directory, "lab-private.pfx"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(pfx);
    }
    finally { CryptographicOperations.ZeroMemory(pfx); }
    using var publicOutput = new FileStream(Path.Combine(directory, "lab-test.cer"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
    publicOutput.Write(certificate.Export(X509ContentType.Cert));
    Console.WriteLine("Ephemeral lab certificate created; no certificate store changed.");
}

static void CheckPrivateDirectory(string directory)
{
    var acl = new DirectoryInfo(directory).GetAccessControl();
    var owner = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException();
    var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
    if (!acl.AreAccessRulesProtected || !owner.Equals(acl.GetOwner(typeof(SecurityIdentifier))))
        throw new UnauthorizedAccessException("Private directory ACL is not protected.");
    var allowed = new HashSet<string> { owner.Value, system.Value };
    var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier));
    if (rules.Count != 2) throw new UnauthorizedAccessException("Private directory ACL has an unexpected count.");
    foreach (FileSystemAccessRule rule in rules)
        if (rule.AccessControlType != AccessControlType.Allow || !allowed.Remove(rule.IdentityReference.Value) || rule.FileSystemRights != FileSystemRights.FullControl)
            throw new UnauthorizedAccessException("Private directory ACL has another principal.");
}

static void SignDigest(string directory, string name)
{
    CheckPrivateDirectory(directory);
    byte[] pfx = ReadFile(directory, "lab-private.pfx");
    try
    {
        using var certificate = X509CertificateLoader.LoadPkcs12(pfx, string.Empty, X509KeyStorageFlags.EphemeralKeySet);
        using var publicCertificate = X509CertificateLoader.LoadCertificate(ReadFile(directory, "lab-test.cer"));
        if (!certificate.RawData.AsSpan().SequenceEqual(publicCertificate.RawData)) throw new CryptographicException("Digest certificate mismatch.");
        // SignTool /dg emits a base64-encoded SHA-256 digest of its signed attributes.
        // /di ingests the base64 signature. Only .cer files ever reach SignTool;
        // private key loading explicitly uses an ephemeral process-local key set.
        byte[] digest = Convert.FromBase64String(Encoding.ASCII.GetString(ReadFile(directory, name + ".dig")));
        if (digest.Length != 32) throw new InvalidDataException("Expected a SHA-256 digest.");
        using RSA key = certificate.GetRSAPrivateKey() ?? throw new CryptographicException("Missing ephemeral RSA key.");
        byte[] signature = key.SignHash(digest, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var output = new FileStream(Path.Combine(directory, name + ".dig.signed"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(Encoding.ASCII.GetBytes(Convert.ToBase64String(signature)));
    }
    finally { CryptographicOperations.ZeroMemory(pfx); }
    Console.WriteLine("Digest signed with an ephemeral in-memory key; no certificate store changed.");
}

static SignedCms CheckCms(byte[] encoded, X509Certificate2 expected)
{
    var cms = new SignedCms();
    cms.Decode(encoded);
    if (cms.SignerInfos.Count != 1 || cms.SignerInfos[0].Certificate is not { } signer ||
        !signer.RawData.AsSpan().SequenceEqual(expected.RawData) || cms.SignerInfos[0].DigestAlgorithm.Value != "2.16.840.1.101.3.4.2.1")
        throw new CryptographicException("Unexpected signer.");
    cms.CheckSignature(true); // Cryptography only: deliberately does not import or trust this certificate.
    return cms;
}

static void Verify(string directory)
{
    using var certificate = X509CertificateLoader.LoadCertificate(ReadFile(directory, "lab-test.cer"));
    if (certificate.HasPrivateKey || certificate.Subject != "CN=Veylo Isolated Lab TEST ONLY" || certificate.Subject != certificate.Issuer ||
        DateTime.UtcNow < certificate.NotBefore.ToUniversalTime() || DateTime.UtcNow >= certificate.NotAfter.ToUniversalTime() ||
        !certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().Any(x => x.EnhancedKeyUsages.Cast<Oid>().Any(o => o.Value == "1.3.6.1.5.5.7.3.3")))
        throw new CryptographicException("Invalid test certificate.");
    using var chain = new X509Chain();
    chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
    chain.ChainPolicy.CustomTrustStore.Add(certificate); // In-memory chain only, never a Windows store.
    chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
    chain.ChainPolicy.DisableCertificateDownloads = true;
    chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.3"));
    if (!chain.Build(certificate)) throw new CryptographicException("Invalid self-signed test certificate.");

    byte[] pe = ReadFile(directory, "SesMicrophone.sys");
    if (pe.Length < 256 || pe[0] != 'M' || pe[1] != 'Z') throw new InvalidDataException("Invalid PE.");
    int offset = BinaryPrimitives.ReadInt32LittleEndian(pe.AsSpan(0x3c, 4));
    if (offset < 64 || offset > pe.Length - 256 || !pe.AsSpan(offset, 4).SequenceEqual("PE\0\0"u8)) throw new InvalidDataException("Invalid PE header.");
    int optional = offset + 24;
    if (BinaryPrimitives.ReadUInt16LittleEndian(pe.AsSpan(optional, 2)) != 0x20b) throw new InvalidDataException("Expected PE32+.");
    int certificateEntry = optional + 112 + 4 * 8;
    uint position = BinaryPrimitives.ReadUInt32LittleEndian(pe.AsSpan(certificateEntry, 4));
    uint size = BinaryPrimitives.ReadUInt32LittleEndian(pe.AsSpan(certificateEntry + 4, 4));
    if (position < certificateEntry + 8 || size < 8 || (ulong)position + size != (ulong)pe.Length || position % 8 != 0)
        throw new InvalidDataException("Invalid certificate table.");
    int start = checked((int)position);
    uint signedSize = BinaryPrimitives.ReadUInt32LittleEndian(pe.AsSpan(start, 4));
    if (signedSize < 8 || signedSize > size || ((signedSize + 7u) & ~7u) != size ||
        BinaryPrimitives.ReadUInt16LittleEndian(pe.AsSpan(start + 4, 2)) != 0x200 ||
        BinaryPrimitives.ReadUInt16LittleEndian(pe.AsSpan(start + 6, 2)) != 2)
        throw new InvalidDataException("Invalid Authenticode signature.");
    var embedded = CheckCms(pe.AsSpan(start + 8, checked((int)signedSize - 8)).ToArray(), certificate);
    if (embedded.ContentInfo.ContentType.Value != "1.3.6.1.4.1.311.2.1.4") throw new CryptographicException("Unexpected PE content.");
    var content = new AsnReader(embedded.ContentInfo.Content, AsnEncodingRules.BER);
    var indirect = content.ReadSequence();
    indirect.ReadEncodedValue();
    var digestInfo = indirect.ReadSequence();
    var algorithm = digestInfo.ReadSequence();
    if (algorithm.ReadObjectIdentifier() != "2.16.840.1.101.3.4.2.1") throw new CryptographicException("Expected SHA-256.");
    byte[] signedHash = digestInfo.ReadOctetString();
    if (!signedHash.AsSpan().SequenceEqual(Catalog.Hash(Path.Combine(directory, "SesMicrophone.sys"))))
        throw new CryptographicException("PE signature hash mismatch.");

    var catalog = CheckCms(ReadFile(directory, "SesMicrophone.cat"), certificate);
    if (catalog.ContentInfo.ContentType.Value != "1.3.6.1.4.1.311.10.1") throw new CryptographicException("Unexpected catalog content.");
    Catalog.CheckMembers(directory);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
#pragma warning disable CA1308 // Thumbprint serialization is lowercase ASCII hexadecimal by contract.
        certificateThumbprint = certificate.Thumbprint.ToLowerInvariant(),
#pragma warning restore CA1308
        certificateSha256 = Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)),
        certificateNotAfterUtc = certificate.NotAfter.ToUniversalTime().ToString("O"),
        embeddedSignature = "passed-cryptographic-only",
        catalogSignature = "passed-cryptographic-only",
        catalogMembership = Catalog.PayloadNames,
        windowsKernelPolicy = "not-validated", microsoftProductionSigned = false
    }));
}

static class Catalog
{
    public static readonly string[] PayloadNames = ["SesMicrophone.inf", "SesMicrophone.sys"];
    public static byte[] Hash(string path, string algorithm = "SHA256")
    {
        if (algorithm is not ("SHA256" or "SHA1")) throw new ArgumentException("Unsupported catalog hash algorithm.");
        if (!CryptCATAdminAcquireContext2(out var context, IntPtr.Zero, algorithm, IntPtr.Zero, 0)) throw new CryptographicException("Catalog context failed.");
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            uint size = 0;
            if (!CryptCATAdminCalcHashFromFileHandle2(context, file.SafeFileHandle.DangerousGetHandle(), ref size, null, 0) || size != (algorithm == "SHA256" ? 32 : 20))
                throw new CryptographicException("Catalog hash size failed.");
            var hash = new byte[size];
            if (!CryptCATAdminCalcHashFromFileHandle2(context, file.SafeFileHandle.DangerousGetHandle(), ref size, hash, 0)) throw new CryptographicException("Catalog hash failed.");
            return hash;
        }
        finally { CryptCATAdminReleaseContext(context, 0); }
    }

    public static void CheckMembers(string directory)
    {
        // This pinned Inf2Cat version emits a SHA-256 entry and a SHA-1 tag alias
        // for each of the two files. Accept the exact four tags; SHA-256 entries
        // must contain signed indirect-data digests. SHA-1 aliases are compatibility
        // metadata only and cannot satisfy the strong membership checks.
        var expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string name in PayloadNames)
        {
            expected.Add(Convert.ToHexString(Hash(Path.Combine(directory, name))));
            expected.Add(Convert.ToHexString(Hash(Path.Combine(directory, name), "SHA1")));
        }
        if (expected.Count != 4) throw new CryptographicException("Catalog member hash collision.");
        var catalog = CryptCATOpen(Path.Combine(directory, "SesMicrophone.cat"), 0, IntPtr.Zero, 0x200, 0);
        if (catalog == IntPtr.Zero || catalog == new IntPtr(-1)) throw new CryptographicException("Cannot open catalog.");
        try
        {
            IntPtr member = IntPtr.Zero;
            int count = 0;
            while ((member = CryptCATEnumerateMember(catalog, member)) != IntPtr.Zero)
            {
                if (++count > 4) throw new CryptographicException("Unexpected catalog member.");
                var value = Marshal.PtrToStructure<Member>(member);
                string tag = Marshal.PtrToStringUni(value.ReferenceTag) ?? throw new CryptographicException("Missing catalog tag.");
                if (!expected.Remove(tag)) throw new CryptographicException("Catalog hash membership mismatch.");
                if (value.IndirectData == IntPtr.Zero)
                {
                    if (tag.Length == 40) continue; // Exact verified SHA-1 alias; both SHA-256 digests remain mandatory.
                    throw new CryptographicException("Missing SHA-256 catalog member digest.");
                }
                var indirect = Marshal.PtrToStructure<IndirectData>(value.IndirectData);
                bool sha256 = tag.Length == 64;
                if (Marshal.PtrToStringAnsi(indirect.Algorithm.Oid) != (sha256 ? "2.16.840.1.101.3.4.2.1" : "1.3.14.3.2.26") ||
                    indirect.Digest.Size != (sha256 ? 32 : 20) || indirect.Digest.Data == IntPtr.Zero)
                    throw new CryptographicException("Catalog member algorithm mismatch.");
                var digest = new byte[sha256 ? 32 : 20];
                Marshal.Copy(indirect.Digest.Data, digest, 0, digest.Length);
                if (!Convert.ToHexString(digest).Equals(tag, StringComparison.OrdinalIgnoreCase))
                    throw new CryptographicException("Catalog member content digest mismatch.");
            }
            if (count != 4 || expected.Count != 0) throw new CryptographicException("Incomplete catalog membership.");
        }
        finally { CryptCATClose(catalog); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct Blob { public uint Size; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)] private struct Attribute { public IntPtr Oid; public Blob Value; }
    [StructLayout(LayoutKind.Sequential)] private struct Algorithm { public IntPtr Oid; public Blob Parameters; }
    [StructLayout(LayoutKind.Sequential)] private struct IndirectData { public Attribute Subject; public Algorithm Algorithm; public Blob Digest; }
    [StructLayout(LayoutKind.Sequential)] private struct Member
    {
        public uint Size; public IntPtr ReferenceTag; public IntPtr FileName; public Guid SubjectType;
        public uint Flags; public IntPtr IndirectData; public uint CertificateVersion; public uint Reserved;
        public IntPtr ReservedHandle; public Blob EncodedIndirectData; public Blob EncodedMemberInfo;
    }
    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CryptCATAdminAcquireContext2(out IntPtr context, IntPtr subsystem, string algorithm, IntPtr policy, uint flags);
    [DllImport("wintrust.dll", SetLastError = true)] private static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr context, IntPtr file, ref uint size, [Out] byte[]? hash, uint flags);
    [DllImport("wintrust.dll")] private static extern bool CryptCATAdminReleaseContext(IntPtr context, uint flags);
    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CryptCATOpen(string path, uint flags, IntPtr provider, uint version, uint encoding);
    [DllImport("wintrust.dll")] private static extern IntPtr CryptCATEnumerateMember(IntPtr catalog, IntPtr previous);
    [DllImport("wintrust.dll")] private static extern bool CryptCATClose(IntPtr catalog);
}
