# Check if the script is running with administrative privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    # If the script is not running with administrative privileges, restart it with administrative privileges
    Start-Process powershell.exe -Verb runAs -ArgumentList "-File `"$PSCommandPath`""
    exit
}

# Get the current user's SID
$userSID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

# Get the local administrators group
$adminGroup = [ADSI]"WinNT://./Administrators"

# Check if the user is already a member of the local administrators group
if ($adminGroup.Invoke("Members") | %{ $_.GetType().InvokeMember("ADsPath", 'GetProperty', $null, $_, $null).Split('/')[-1] } -contains $userSID) {
    Write-Host "User is already a member of the local Administrators group."
    exit
}

# Add the user to the local administrators group
$userObj = [ADSI]"WinNT://./$userSID"
$adminGroup.Invoke("Add", $userObj.Path)
Write-Host "User has been granted local Administrator rights."
