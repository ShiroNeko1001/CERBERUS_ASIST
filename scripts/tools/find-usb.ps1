$disk = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Model -like '*Lexar USB Flash Drive*' }
$part = Get-Partition -DiskNumber $disk.Index
$vols = $part | Get-Volume
$vols | Format-Table DriveLetter,FileSystemLabel,FileSystem,SizeRemaining,Size -AutoSize
