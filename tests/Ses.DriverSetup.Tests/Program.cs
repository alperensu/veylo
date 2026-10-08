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
Reject("untrusted-microsoft-name",cms.Encode());
cms.ComputeSignature(new CmsSigner(certificate));Reject("multiple-signers",cms.Encode());
string development=Path.Combine(root,"build","driver","package","sesmicrophone.cat");
if(File.Exists(development))Reject("unsigned-development",File.ReadAllBytes(development));
else Console.WriteLine("SKIP unsigned development CAT: build the driver first");
Console.WriteLine($"{count} catalog rejection checks passed; no driver installed");
