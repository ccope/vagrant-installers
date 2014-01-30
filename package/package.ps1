<#
.SYNOPSIS
    Packages a Vagrant installer from a substrate package.

.DESCRIPTION
    Packages a Vagrant installer from a substrate package.

    This script requires administrative privileges.

    You can run this script from an old-style cmd.exe prompt using the
    following:

      powershell.exe -ExecutionPolicy Unrestricted -NoLogo -NoProfile -Command "& '.\package.ps1'"

.PARAMETER SubstratePath
    Path to the substrate zip file.

.PARAMETER VagrantRevision
    The commit revision of Vagrant to install.

.PARAMETER VagrantVersion
    The version of Vagrant that will be installed, also the version reported
    by the installer.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$SubstratePath,

    [Parameter(Mandatory=$true)]
    [string]$VagrantRevision,

    [Parameter(Mandatory=$true)]
    [string]$VagrantVersion
)

# Exit if there are any exceptions
$ErrorActionPreference = "Stop"

# Put this in a variable to make things easy later
$UpgradeCode = "1a672674-6722-4e3a-9061-8f539a8b0ed6"

# Get the directory to this script
$Dir = Split-Path $script:MyInvocation.MyCommand.Path

# Lookup the WiX binaries, these will error if they're not on the Path
$WixHeat   = Get-Command heat | Select-Object -ExpandProperty Definition
$WixCandle = Get-Command candle | Select-Object -ExpandProperty Definition
$WixLight  = Get-Command light | Select-Object -ExpandProperty Definition

# Final path to output
$OutputPath = "vagrant_$($VagrantVersion).msi"

#--------------------------------------------------------------------
# Helper Functions
#--------------------------------------------------------------------
function Expand-ZipFile($file, $destination) {
    $shell = New-Object -ComObject "Shell.Application"
    $zip = $shell.NameSpace($file)
    foreach($item in $zip.items()) {
        $shell.Namespace($destination).copyhere($item)
    }
}

#--------------------------------------------------------------------
# Extract Substrate
#--------------------------------------------------------------------
# We need the full path to the file
$SubstratePath = Resolve-Path $SubstratePath

# We need to create a temporary configuration directory
$SubstrateTmpDir = [System.IO.Path]::GetTempPath()
$SubstrateTmpDir = [System.IO.Path]::Combine(
    $SubstrateTmpDir, [System.IO.Path]::GetRandomFileName())
[System.IO.Directory]::CreateDirectory($SubstrateTmpDir) | Out-Null
Write-Host "Substrate temp dir: $($SubstrateTmpDir)"

# Unzip
Write-Host "Expanding substrate..."
Expand-ZipFile -file $SubstratePath -destination $SubstrateTmpDir

# Set the full path to the substrate
$SubstrateDir = "$($SubstrateTmpDir)"

#--------------------------------------------------------------------
# Install Vagrant
#--------------------------------------------------------------------
$VagrantTmpDir = [System.IO.Path]::GetTempPath()
$VagrantTmpDir = [System.IO.Path]::Combine(
    $VagrantTmpDir, [System.IO.Path]::GetRandomFileName())
[System.IO.Directory]::CreateDirectory($VagrantTmpDir) | Out-Null
Write-Host "Vagrant temp dir: $($VagrantTmpDir)"

$VagrantSourceURL = "https://github.com/mitchellh/vagrant/archive/$($VagrantRevision).zip"
$VagrantDest      = "$($VagrantTmpDir)\vagrant.zip"

# Download
Write-Host "Downloading Vagrant: $($VagrantRevision)"
$client = New-Object System.Net.WebClient
$client.DownloadFile($VagrantSourceURL, $VagrantDest)

# Unzip
Write-Host "Unzipping Vagrant"
Expand-ZipFile -file $VagrantDest -destination $VagrantTmpDir

# Set the full path to where Vagrant is
$VagrantSourceDir = "$($VagrantTmpDir)\vagrant-$($VagrantRevision)"

# Build gem
Write-Host "Building Vagrant Gem"
Push-Location $VagrantSourceDir
&"$($SubstrateDir)\embedded\bin\gem.bat" build vagrant.gemspec
Copy-Item vagrant-*.gem -Destination vagrant.gem
Pop-Location

# Install gem. We do this in a sub-shell so we don't have to worry
# about restoring environmental variables.
$env:SubstrateDir     = $SubstrateDir
$env:VagrantSourceDir = $VagrantSourceDir
powershell {
    $ErrorActionPreference = "Stop"

    Set-Location $env:VagrantSourceDir
    $EmbeddedDir  = "$($env:SubstrateDir)\embedded"
    $env:GEM_PATH = "$($EmbeddedDir)\gems"
    $env:GEM_HOME = $env:GEM_PATH
    $env:GEMRC    = "$($EmbeddedDir)\etc\gemrc"
    $env:CPPFLAGS = "-I$($EmbeddedDir)\include"
    $env:LDFLAGS  = "-L$($EmbeddedDir)\lib"
    $env:Path     ="$($EmbeddedDir)\bin;$($env:Path)"
    &"$($EmbeddedDir)\bin\gem.bat" install vagrant.gem --no-ri --no-rdoc
}
Remove-Item Env:SubstrateDir
Remove-Item Env:VagrantSourceDir

#--------------------------------------------------------------------
# MSI
#--------------------------------------------------------------------
$InstallerTmpDir = [System.IO.Path]::GetTempPath()
$InstallerTmpDir = [System.IO.Path]::Combine(
    $InstallerTmpDir, [System.IO.Path]::GetRandomFileName())
[System.IO.Directory]::CreateDirectory($InstallerTmpDir) | Out-Null
[System.IO.Directory]::CreateDirectory("$($InstallerTmpDir)\assets") | Out-Null
Write-Host "Installer temp dir: $($InstallerTmpDir)"

Copy-Item "$($Dir)\support\windows\bg_banner.bmp" `
    -Destination "$($InstallerTmpDir)\assets\bg_banner.bmp"
Copy-Item "$($Dir)\support\windows\bg_dialog.bmp" `
    -Destination "$($InstallerTmpDir)\assets\bg_dialog.bmp"
Copy-Item "$($Dir)\support\windows\license.rtf" `
    -Destination "$($InstallerTmpDir)\assets\license.rtf"
Copy-Item "$($Dir)\support\windows\vagrant-en-us.wxl" `
    -Destination "$($InstallerTmpDir)\vagrant-en-us.wxl"

$contents = @"
<?xml version="1.0" encoding="utf-8"?>
<Include>
  <?define VersionNumber="$($VagrantVersion)" ?>
  <?define DisplayVersionNumber="$($VagrantVersion)" ?>

  <!--
    Upgrade code must be unique per version installer.
    This is used to determine uninstall/reinstall cases.
  -->
  <?define UpgradeCode="$($UpgradeCode)" ?>
</Include>
"@
$contents | Out-File -FilePath "$($InstallerTmpDir)\vagrant-config.wxi"

$contents = @"
<?xml version="1.0"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi" xmlns:util="http://schemas.microsoft.com/wix/UtilExtension">
  <!-- Include our wxi -->
  <?include "$($InstallerTmpDir)\vagrant-config.wxi" ?>

  <!-- The main product -->
  <Product Id="*"
           Language="!(loc.LANG)"
           Name="!(loc.ProductName)"
           Version="`$(var.VersionNumber)"
           Manufacturer="!(loc.ManufacturerName)"
           UpgradeCode="`$(var.UpgradeCode)">

    <!-- Define the package information -->
    <Package Compressed="yes"
             InstallerVersion="200"
             InstallPrivileges="elevated"
             InstallScope="perMachine"
             Manufacturer="!(loc.ManufacturerName)" />

    <!-- Disallow installing older versions until the new version is removed -->
    <!-- Note that this creates the RemoveExistingProducts action -->
    <MajorUpgrade DowngradeErrorMessage="A later version of Vagrant is installed. Please remove this version first. Setup will now exit."
                  Schedule="afterInstallInitialize" />

    <!-- The source media for the installer -->
    <Media Id="1"
           Cabinet="Vagrant.cab"
           CompressionLevel="high"
           EmbedCab="yes" />

     <!-- Require Windows NT Kernel -->
     <Condition Message="This application is only supported on Windows 2000 or higher.">
       <![CDATA[Installed or (VersionNT >= 500)]]>
     </Condition>

     <!-- Some steps for our installation -->
     <InstallExecuteSequence>
       <ScheduleReboot After="InstallFinalize"><![CDATA[UILevel <> 2]]></ScheduleReboot>
     </InstallExecuteSequence>

     <!-- Get the proper system directory -->
     <SetDirectory Id="WINDOWSVOLUME" Value="[WindowsVolume]" />

     <!-- The directory where we'll install Vagrant -->
     <Directory Id="TARGETDIR" Name="SourceDir">
       <Directory Id="WINDOWSVOLUME">
         <Directory Id="MANUFACTURERDIR" Name="HashiCorp">
           <Directory Id="VAGRANTAPPDIR" Name="Vagrant">
             <Component Id="VagrantBin"
               Guid="{12a01bfc-ae9e-4543-8a32-47865cc03071}">
               <!--
                 Add our bin dir to the PATH so people can use
                 vagrant right away in the shell.
               -->
               <Environment Id="Environment"
                 Name="PATH"
                 Action="set"
                 Part="last"
                 System="yes"
                 Value="[VAGRANTAPPDIR]bin" />
             </Component>
           </Directory>
         </Directory>
       </Directory>
     </Directory>

     <!-- Define the features of our install -->
     <Feature Id="VagrantFeature"
              Title="!(loc.ProductName)"
              Level="1">
       <ComponentGroupRef Id="VagrantDir" />
       <ComponentRef Id="VagrantBin" />
     </Feature>

     <!-- WixUI configuration so we can have a UI -->
     <Property Id="WIXUI_INSTALLDIR" Value="VAGRANTAPPDIR" />

     <UIRef Id="VagrantUI_InstallDir" />
     <UI Id="VagrantUI_InstallDir">
       <UIRef Id="WixUI_InstallDir" />
     </UI>

     <WixVariable Id="WixUILicenseRtf" Value="$($InstallerTmpDir)\assets\license.rtf" />
     <WixVariable Id="WixUIDialogBmp" Value="$($InstallerTmpDir)\assets\bg_dialog.bmp" />
     <WixVariable Id="WixUIBannerBmp" Value="$($InstallerTmpDir)\assets\bg_banner.bmp" />
  </Product>
</Wix>
"@
$contents | Out-File -FilePath "$($InstallerTmpDir)\vagrant-main.wxs"

Write-Host "Running heat.exe"
&$WixHeat dir $SubstrateDir `
    -nologo `
    -srd `
    -gg `
    -cg VagrantDir `
    -dr VAGRANTAPPDIR `
    -var 'var.VagrantSourceDir' `
    -out "$($InstallerTmpDir)\vagrant-files.wxs"

Write-Host "Running candle.exe"
$CandleArgs = @(
    "-nologo",
    "-I$($InstallerTmpDir)",
    "-dVagrantSourceDir=$($SubstrateDir)",
    "-out $InstallerTmpDir",
    "$($InstallerTmpDir)\vagrant-files.wxs",
    "$($InstallerTmpDir)\varant-main.wxs"
)
Start-Process -NoNewWindow -Wait `
    -ArgumentList $CandleArgs -FilePath $WixCandle

Write-Host "Running light.exe"
&$WixLight `
    -nologo `
    -ext WixUIExtension `
    -cultures:en-us `
    -loc "$($InstallerTmpDir)\vagrant-en-us.wxl" `
    -out $OutputPath `
    "$($InstallerTmpDir)\vagrant-files.wixobj" `
    "$($InstallerTmpDir)\vagrant-main.wixobj"

Write-Host "Installer at: $($OutputPath)"
