function Show-Menu {
    Clear-Host
    Write-Host "IT Support Tools" -ForegroundColor Green
    Write-Host "1. Ping a device"
    Write-Host "2. Check IP configuration"
    Write-Host "3. Flush DNS cache"
    Write-Host "4. Release and Renew IP address"
    Write-Host "5. View current network connections"
    Write-Host "6. Exit"
}

while ($true) {
    Show-Menu
    $input = Read-Host "Please make a selection"

    switch ($input) {
        "1" {
            $device = Read-Host "Enter the device IP or hostname to ping"
            ping $device -n 4
            pause
        }
        "2" {
            ipconfig /all
            pause
        }
        "3" {
            ipconfig /flushdns
            pause
        }
        "4" {
            ipconfig /release
            ipconfig /renew
            pause
        }
        "5" {
            netstat -ano
            pause
        }
        "6" {
            break
        }
        Default {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
            pause
        }
    }
}
