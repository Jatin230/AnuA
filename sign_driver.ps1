# Run this as Administrator — trust the self-signed cert so Windows accepts the driver
$thumb = "AFA10C71552B67EB796101C042B41E36EF9F6FCE"
$cert = Get-Item "Cert:\CurrentUser\My\$thumb"
$cer = "$env:TEMP\anuvadini.cer"

Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Remove-Item $cer -ErrorAction SilentlyContinue

Write-Output "Cert installed to TrustedPublisher and Root"

# Verify
$dll = "C:\Users\jatin\Downloads\rustdesk\drivers\AnuvadiniPrinterDriver\printer_driver_adapter.dll"
$cat = "C:\Users\jatin\Downloads\rustdesk\drivers\AnuvadiniPrinterDriver\anuvadiniprinterdriver.cat"
Get-AuthenticodeSignature -FilePath $dll | Format-List Status, StatusMessage, SignerCertificate
Get-AuthenticodeSignature -FilePath $cat | Format-List Status, StatusMessage, SignerCertificate
Write-Output "Done"
