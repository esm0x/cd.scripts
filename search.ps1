# Get user input for file name
$file_name = Read-Host "Enter file name to search for:"

# Initialize variables
$search_path = "C:\"
$results = @()
$counter = 0
$total_files = 0

# Get total number of files to search through
Get-ChildItem -Path $search_path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $total_files++
}

# Search for file and display progress bar
Write-Host "Searching for '$file_name'..." -NoNewline
Get-ChildItem -Path $search_path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -eq $file_name) {
        $results += $_.FullName
    }
    $counter++
    Write-Progress -Activity "Searching for '$file_name'..." -Status "$($counter) of $($total_files) files searched" -PercentComplete ($counter / $total_files * 100)
}

# Display search results
if ($results.Count -gt 0) {
    Write-Host "`nSearch results for '$file_name':" -ForegroundColor Green
    $results | ForEach-Object {
        Write-Host $_
    }
} else {
    Write-Host "`nNo results found for '$file_name'." -ForegroundColor Yellow
}
