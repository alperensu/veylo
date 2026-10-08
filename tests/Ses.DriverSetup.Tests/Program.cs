using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using Installer=Ses.DriverSetup.Program;

// Read-only verifier tests. No UAC, device/Driver Store mutation or test certificate import.
string root=args.Length==1?Path.GetFullPath(args[0]):throw new ArgumentException("Workspace path required");
string directory=Path.Combine(root,"artifacts","security","catalog-tests");Directory.CreateDirectory(directory);
int count=0;
void Reject(string name,byte[] catalog){
    string path=Path.Combine(directory,name+".cat");File.WriteAllBytes(path,catalog);
    try{Installer.VerifyMicrosoftCatalog(path);throw new InvalidOperationException("Accepted unsafe catalog: "+name);}
    catch(CryptographicException){++count;Console.WriteLine("PASS rejected "+name);}
}
Reject("malformed",new byte[]{1,2,3,4});
using var key=RSA.Create(2048);
var request=new CertificateRequest("CN=Microsoft Windows Fake, O=Microsoft Fake",key,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
using var certificate=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(1));
var cms=new SignedCms(new ContentInfo(new byte[]{4,5,6}));cms.ComputeSignature(new CmsSigner(certificate));
byte[] fakeSigned=cms.Encode();Reject("untrusted-microsoft-name",fakeSigned);
cms.ComputeSignature(new CmsSigner(certificate));Reject("multiple-signers",cms.Encode());
string development=Path.Combine(root,"build","driver","package","sesmicrophone.cat");
if(File.Exists(development))Reject("unsigned-development",File.ReadAllBytes(development));
else Console.WriteLine("SKIP unsigned development CAT: build the driver first");
void Check(bool condition,string name){if(!condition)throw new InvalidOperationException(name);++count;Console.WriteLine("PASS "+name);}
Check(Installer.ParseAction(Array.Empty<string>())=="status","empty command is read-only status");
Check(Installer.ParseAction(new[]{"package-status"})=="package-status","package status command accepted");
Check(Installer.ParseAction(new[]{"install","arbitrary.inf"}) is null,"extra command arguments rejected");
Check(Installer.ParseAction(new[]{"unexpected"}) is null,"unknown command rejected");
var removal=Installer.PlanPackageRemoval(new string?[]{"oem12.inf","OEM12.INF","oem8.inf",null,"../oem7.inf","oem9.inf\n","other.inf"});
Check(removal.SequenceEqual(new[]{"oem12.inf","oem8.inf"}),"OEM removal plan deduplicates package identities and rejects paths");
Check(Installer.PlanPackageRemoval(Array.Empty<string?>()).Length==0,"empty device removal plan is safe");
string fixtures=Path.Combine(directory,"packages-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(fixtures);
using var expected=typeof(Installer).Assembly.GetManifestResourceStream("SES.Expected.inf")!;
using var expectedMemory=new MemoryStream();expected.CopyTo(expectedMemory);byte[] expectedInf=expectedMemory.ToArray();
void RejectPackage(string name,Action<string> configure)
{
    string package=Path.Combine(fixtures,name);Directory.CreateDirectory(package);
    File.WriteAllBytes(Path.Combine(package,"SesMicrophone.inf"),expectedInf);
    File.WriteAllBytes(Path.Combine(package,"SesMicrophone.sys"),new byte[]{1});
    File.WriteAllBytes(Path.Combine(package,"SesMicrophone.cat"),fakeSigned);
    configure(package);
    try{Installer.ReadPackage(package);throw new InvalidOperationException("Accepted unsafe package: "+name);}
    catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException or CryptographicException){++count;Console.WriteLine("PASS rejected package "+name);}
}
try
{
    RejectPackage("missing-catalog",package=>File.Delete(Path.Combine(package,"SesMicrophone.cat")));
    RejectPackage("changed-inf",package=>File.AppendAllText(Path.Combine(package,"SesMicrophone.inf"),"; changed"));
    RejectPackage("empty-sys",package=>File.WriteAllBytes(Path.Combine(package,"SesMicrophone.sys"),Array.Empty<byte>()));
    RejectPackage("oversized-sys",package=>{using var file=new FileStream(Path.Combine(package,"SesMicrophone.sys"),FileMode.Open,FileAccess.Write);file.SetLength(16*1024*1024+1);});
    RejectPackage("fake-signer",_=>{});
    RejectPackage("malformed-catalog",package=>File.WriteAllBytes(Path.Combine(package,"SesMicrophone.cat"),new byte[]{1,2,3}));
}
finally
{
    // The unique fixture directory was created under artifacts by this process.
    if(!Path.GetFullPath(fixtures).StartsWith(Path.GetFullPath(directory)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("Unsafe fixture cleanup path.");
    Installer.EnsureNoReparsePath(fixtures);Directory.Delete(fixtures,true);
}
Check(System.Runtime.InteropServices.Marshal.SizeOf<Ses.DriverSetup.CatalogMembership.CatalogInfo>()==72&&
      System.Runtime.InteropServices.Marshal.SizeOf<Ses.DriverSetup.CatalogMembership.TrustData>()==88,"catalog verification interop layouts match Windows x64");
string memberPath=Path.Combine(directory,"unsigned-member.inf");File.WriteAllBytes(memberPath,expectedInf);
using(var member=new FileStream(memberPath,FileMode.Open,FileAccess.Read,FileShare.Read)){
    try{Ses.DriverSetup.CatalogMembership.Verify(Path.Combine(directory,"untrusted-microsoft-name.cat"),memberPath,member);throw new InvalidOperationException("Accepted untrusted catalog membership");}
    catch(CryptographicException){++count;Console.WriteLine("PASS Windows catalog membership rejects an unrelated untrusted catalog");}
}
Console.WriteLine($"{count} driver package and removal-plan checks passed; no driver installed");
