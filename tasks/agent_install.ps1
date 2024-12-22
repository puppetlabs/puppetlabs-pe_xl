# agent_install.ps1
Param( 
  $install_flags, 
  $server 
) 
if (Test-Path "C:\Program Files\Puppet Labs\Puppet\puppet\bin\puppet"){
  Write-Host "ERROR: Puppet agent is already installed. Re-install, re-configuration, or upgrade not supported. Please uninstall the agent before running this task."
  Exit 1
}
$flags=$install_flags -replace '^\["*','' -replace 's/"*\]$','' -replace '/", *"',' '
$mypath = $MyInvocation.MyCommand.Path | Split-Path -Parent
try {
  [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}; $webClient = New-Object System.Net.WebClient; $webClient.DownloadFile("https://${server}:8140/packages/current/install.ps1", "${mypath}\install.ps1"); powershell.exe -c "${mypath}\install.ps1 $flags"
  }
  catch {
  Write-Host "Installer failed with Exception: $_.Exception.Message"
  Exit 1
  }
