# Enables key-only OpenSSH access for the WSL build bridge. Everything else
# (PowerShell 7, .NET SDK) is installed later over SSH with vm/guest-toolchain.ps1.
$ErrorActionPreference = 'Stop'

# Phase 1: install the OpenSSH server optional feature (needs network access).
$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}

# Phase 2: write a key-only config before the first start. Restarting sshd straight
# after its first start failed during setup ("Cannot stop sshd"), so never restart here.
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ssh' | Out-Null
$config = 'C:\ProgramData\ssh\sshd_config'
$text = Get-Content 'C:\Windows\System32\OpenSSH\sshd_config_default' -Raw
$text = $text -replace '(?m)^#?PasswordAuthentication .*$', "PasswordAuthentication no`r`nKbdInteractiveAuthentication no"
Set-Content $config $text -Encoding ascii

# Phase 3: administrator keys must be owned and readable only by SYSTEM and Administrators,
# otherwise sshd ignores the file.
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Copy-Item 'C:\OEM\administrators_authorized_keys' $keys -Force
icacls.exe $keys /inheritance:r /grant 'SYSTEM:F' /grant '*S-1-5-32-544:F' | Out-Null

# Phase 4: open the firewall, then start the service once.
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Output 'ssh ready'
