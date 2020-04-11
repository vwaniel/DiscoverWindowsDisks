function DiscoverWindowsDisks {
	<#
	.SYNOPSIS
	Accepts a list of Windows hosts.  Discovers drive letters and mount points, and maps them to physical disk information.  Optionally specifiy a vCenter server to map physical disk information to VMDKs.

	.DESCRIPTION
	Accepts a list of Windows hosts.  Discovers drive letters and mount points, and maps them to physical disk information.  Optionally specifiy a vCenter server to map physical disk information to VMDKs.

	This function assumes the following:
	1.  PSRemoting is enabled on the remote host(s) that are being queried.
	2.  All remote hosts being to the same vCenter instance (if -vCenterServer has been specified).
	3.  The user has downloaded a local copy of Sysinternals' DiskExt utility.
	4.  The remote hosts are not using dynamic disks.  Dynamic disks will fail to map correctly.

	.PARAMETER WindowsHostnames
	A single host, comma-separated list of hosts, or an array of hostnames to be scanned.  FQDN is highly preferred.

	.PARAMETER DiskExtPath
	A valid path to a directory containing the Sysinternals' DiskExt executables.

	.PARAMETER RemoteDiskExtDirectory
	Specify this parameter to change the directory path on the remote host where the DiskExt executables are temporarily copied.  The path is relative to the remote host's C:\ drive.

	.PARAMETER Credential
	A pscredential object if the user wishes to use alternative credentials to connect to the remote hosts.

	.PARAMETER vCenterServer
	Optional parameter, which if specified, will cause the script to connect to the specified vCenter instance and attempt to map the disks discovered on remote hosts to VMDK files.  This parameter requires that the VMware PowerCLI be installed on the system where this script is being run.

	.PARAMETER Test
	An optional parameter designed to output the information collected at several key steps during the disk mapping process.  Used for debugging.

	.EXAMPLE
	PS> DiscoverWindowsDisks -WindowsHostname "server1.example.com" -DiskExtPath ".\diskext"

	Connects to "server1.example.com" using the current user's credentials.  Assuming that ".\diskext" is a valid path containing the DiskExt executables, the script will return a list of drive letters and mount points on "server1.example.com" and associated physical disk information.

	.EXAMPLE
	PS> DiscoverWindowsDisks -WindowsHostname "server1.example.com" -DiskExtPath ".\diskext" -vCenterServer "vsphere.example.com"

	Connects to "server1.example.com" using the current user's credentials.  As "-vCenterServer" has been specified, the script will attempt to load the VMware PowerCLI, connect to vCenter (prompting for credentials if the current user does not have rights to connect), and map each drive letter/mount point to a corresponding VMDK file.

	.EXAMPLE
	PS> "server1.example.com","server2.example.com","server3.example.com","server4.example.com","server5.example.com" | DiscoverWindowsDisks -DiskExtPath ".\diskext" -vCenterServer "vsphere.example.com"

	Connects to all of the servers specified in the pipeline input and discovers disk information.  Connects to "vsphere.example.com" and attempts to discover VMDK information for disks on all servers.
	#>
	[cmdletbinding()]
	param(
		[Parameter(Mandatory=$true,Position=1,ValueFromPipeline=$true)][string[]]$WindowsHostnames,
		[Parameter(Mandatory=$true,Position=2)][string]$DiskExtPath,
		[Parameter(Mandatory=$false)]$RemoteDiskExtDirectory = "\temp\diskext",
		[Parameter(Mandatory=$false)][pscredential]$Credential,
		[Parameter(Mandatory=$false)][string]$vCenterServer,
		[Parameter(Mandatory=$false)][ValidateSet("WMI","diskext")][string]$Test
	)
	
	Begin {
		# Validate "DiskExtPath" variable.
		$DiskExtPath = $DiskExtPath.TrimEnd("\\")
		if (Test-Path $DiskExtPath) {
			# Look for executables.
			if (!(Test-Path "$($DiskExtPath)\diskext.exe")) {
				Write-Error "Unable to find diskext.exe in $($DiskExtPath)!"
				break
			}
			if (!(Test-Path "$($DiskExtPath)\diskext64.exe")) {
				Write-Error "Unable to find diskext64.exe in $($DiskExtPath)!"
				break
			}
		} else {
			Write-Error "$($DiskExtPath) is not a valid path!"
			break
		}
		if ($vCenterServer) {
			# Attempt to load VMware PowerCLI.
			if (!(Get-Module "VMware.PowerCLI" -ErrorAction "SilentlyContinue")) {
				try {
					Import-Module "VMware.PowerCLI" -ErrorAction "Stop"
				}
				catch {
					Write-Error "`"vCenterServer`" was specified, but unable to load VMware PowerCLI.  $($_.Exception.Message)"
					exit
				}
			}
			# Connect to vCenter.
			try {
				$objVCenterConnection = Connect-VIServer $vCenterServer -ErrorAction "Stop"
			}
			catch {
				Write-Error "`"vCenterServer`" was specified, but connection to vCenter instance $($vCenterServer) failed.  $($_.Exception.Message)"
				exit
			}
		}
	}

	Process {
		foreach ($WindowsHostname in $WindowsHostnames) {
			# Discover all disks/partitions and store in a hashtable.
			$htPartitions = @{}
			try {
				if ($objVCenterConnection) {
					if ($Credential) {
						$WindowsHostUUID = ((Get-WMIObject -Query "SELECT SerialNumber FROM Win32_BIOS" -ComputerName $WindowsHostname -Credential $Credential -ErrorAction "Stop").SerialNumber.TrimStart("VMware-") -replace " ","").Insert(8,"-").Insert(13,"-").Insert(23,"-")
					} else {
						$WindowsHostUUID = ((Get-WMIObject -Query "SELECT SerialNumber FROM Win32_BIOS" -ComputerName $WindowsHostname -ErrorAction "Stop").SerialNumber.TrimStart("VMware-") -replace " ","").Insert(8,"-").Insert(13,"-").Insert(23,"-")
					}
				}
				if ($Credential) {
					$arrDiskDrives = Get-WMIObject Win32_DiskDrive -ComputerName $WindowsHostname -Credential $Credential -ErrorAction "Stop"
				} else {
					$arrDiskDrives = Get-WMIObject Win32_DiskDrive -ComputerName $WindowsHostname -ErrorAction "Stop"
				}
				foreach ($diskdrive in $arrDiskDrives) {
					# Get partitions associated with each disk drive.
					if ($Credential) {
						$partitions = Get-WMIObject -Query "ASSOCIATORS OF {WIN32_DiskDrive.DeviceID='$($diskdrive.DeviceID)'} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ComputerName $WindowsHostname -Credential $Credential
					} else {
						$partitions = Get-WMIObject -Query "ASSOCIATORS OF {WIN32_DiskDrive.DeviceID='$($diskdrive.DeviceID)'} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ComputerName $WindowsHostname
					}
					if ($partitions) {
						$partitions | Foreach-Object {
							$htPartitions.Add("$($_.DiskIndex):$($_.StartingOffset)",$(
								New-Object PSObject -Property @{
									"Partition" = $_.DeviceID;
									"DiskID" = $_.DiskIndex;
									"Offset" = $_.StartingOffset;
									"DiskSize" = $diskdrive.Size;
									"DiskSerialNumber" = $diskdrive.SerialNumber;
									"PartitionSize" = $_.Size;
									"SCSIBus" = $diskdrive.SCSIBus;
									"SCSILogicalUnit" = $diskdrive.SCSILogicalUnit;
									"SCSIPort" = $diskdrive.SCSIPort;
									"SCSITargetId" = $diskdrive.SCSITargetId
								}
							)) > $null
						}
						Remove-Variable partitions
					}
					
				}
				Remove-Variable arrDiskDrives
			}
			catch {
				Write-Error "Failed to get disk/partition information via WMI.  $($_.Exception.Message)"
				break
			}
			
			if ($Test -eq "WMI") {
				$htPartitions
				continue
			}
			
			# Correct SCSI Port values to match what is returned in VMware.
			$lowest_scsiport = $arrPartitions | Foreach-Object {$_.SCSIPort} | Sort | Select -First 1
			foreach ($partition in $arrPartitions) {
				$partition.SCSIPort = $partition.SCSIPort - $lowest_scsiport
			}
			
			# Map PSDrive to remote system, run diskext, and tear down.
			$psdrive_name = $WindowsHostname.Split(".")[0]
			try {
				if ($Credential) {
					$psdrive = New-PSDrive -Name "$($psdrive_name)_c" -Root "\\$($WindowsHostname)\c`$" -PsProvider "FileSystem" -Credential $Credential -ErrorAction "Stop"
				} else {
					$psdrive = New-PSDrive -Name "$($psdrive_name)_c" -Root "\\$($WindowsHostname)\c`$" -PsProvider "FileSystem" -ErrorAction "Stop"
				}
			}
			catch {
				Write-Error "Failed to mount PSDrive.  $($_.Exception.Message)"
				break
			}
			try {
				New-Item -ItemType "Directory" -Path "$($psdrive.Name):$($RemoteDiskExtDirectory)\" -ErrorAction "Stop" > $null
			}
			catch {
				Write-Error "Failed to create remote temporary directory.  $($_.Exception.Message)"
				break
			}
			try {
				Copy-Item "$($DiskExtPath)\*" "$($psdrive.Name):$($RemoteDiskExtDirectory)\" -ErrorAction "Stop"
			}
			catch {
				Write-Error "Failed to copy DiskExt components to remote system.  $($_.Exception.Message)"
				break
			}
			try {
				if ($Credential) {
					$volumes = Invoke-Command -ComputerName $WindowsHostname -ScriptBlock {& "c:$($args[0])\diskext.exe" '-nobanner' '-accepteula'} -ArgumentList $RemoteDiskExtDirectory -Credential $Credential
				} else {
					$volumes = Invoke-Command -ComputerName $WindowsHostname -ScriptBlock {& "c:$($args[0])\diskext.exe" '-nobanner' '-accepteula'} -ArgumentList $RemoteDiskExtDirectory
				}
			}
			catch {
				Write-Error "Failed to invoke diskext utility on remote system.  $($_.Exception.Message)"
				break
			}
			try {
				Remove-Item -Force -Path "$($psdrive.Name):$($RemoteDiskExtDirectory)" -Recurse -ErrorAction "Stop"
			}
			catch {
				Write-Error "Failed to remove diskext executables from remote system.  $($_.Exception.Message)"
			}
			try {
				$psdrive | Remove-PSDrive -ErrorAction "Stop" > $null
			}
			catch {
				Write-Error "Failed to unmount PSDrive.  $($_.Exception.Message)"
			}
			
			if ($Test -eq "diskext") {
				$volumes
				continue
			}
			
			# Extract volume/extent information from diskext output.
			$volumes = $volumes -join "`n"
			$volumes = $volumes -split "Volume: "
			$volume_regex = "\\\\\?\\Volume{(?<VolumeID>[0-9,a,b,c,d,e,f,-]*)}\\`n\s*Mounted at: (?<MountPoint>.*)`n"
			$extent_regex = "\[(?<ExtentID>[0-9]{1,2})\]:\s*Disk:\s*(?<DiskID>[0-9]{1,2})\s*Offset:\s*(?<Offset>[0-9]*)\s*Length:\s*(?<ExtentLength>[0-9]*)"
			$arrExtents = [System.Collections.ArrayList]@()
			foreach ($volume in $volumes) {
				switch -regex ($volume) {
					$volume_regex {
						$volume_id = $matches.VolumeID
						$mountpoint = $matches.MountPoint
						$extents = $volume -replace $volume_regex,""
						$extents = $extents -split "(`n|)   Extent "
						foreach ($extent in $extents) {
							switch -regex ($extent) {
								$extent_regex {
									$partition = $htPartitions["$($matches.DiskID):$($matches.Offset)"]
									$arrExtents.Add($(
										New-Object PSObject -Property @{
											"Hostname" = $WindowsHostname;
											"VolumeID" = $volume_id;
											"MountPoint" = $mountpoint;
											"ExtentID" = $matches.ExtentID;
											"ExtentOffset" = [int64]($matches.Offset);
											"ExtentSize" = [int64]($matches.ExtentLength);
											"PartitionSize" = $partition.PartitionSize;
											"DiskID" = $partition.DiskID;
											"DiskSize" = $partition.DiskSize;
											"DiskSerialNumber" = $partition.DiskSerialNumber;
											"SCSIBus" = $partition.SCSIBus;
											"SCSILogicalUnit" = $partition.SCSILogicalUnit;
											"SCSIController" = $partition.SCSIPort;
											"SCSIControllerPort" = $partition.SCSITargetId;
										} | Select "Hostname","MountPoint","VolumeID","DiskSerialNumber","DiskID","DiskSize","ExtentID","ExtentOffset","PartitionSize","SCSIBus","SCSIController","SCSIControllerPort","SCSILogicalUnit"
									)) > $null
									Remove-Variable partition
								}
							}
						}
					}
				}
			}
			
			if ($objVCenterConnection) {
				# Get virtual machine object by UUID.
				$objVM = Get-VM | Where {$_.ExtensionData.Config.UUID -eq $WindowsHostUUID}
				if ($objVM) {
					# Get virtual disks.
					$arrVMDKs = $objVM | Get-HardDisk
					# Get hard disk serial numbers.
					$objVMDatacenterView = $objVM | Get-Datacenter | Get-View
					$objVirtualDiskManager = Get-View -Id VirtualDiskManager-virtualDiskManager
					$htVMDKs = @{}
					foreach ($vmdk in $arrVMDKs) {
						$vmdk_uuid = $objVirtualDiskManager.QueryVirtualDiskUUID($vmdk.Filename, $objVMDatacenterView.MoRef)
						$vmdk | Add-Member -MemberType "NoteProperty" -Name "UUID" -Value $vmdk_uuid -Force
						$vmdk_uuid = ($vmdk_uuid -replace "( |-)","").ToLower()
						$htVMDKs.Add($vmdk_uuid,$vmdk) > $null
						Remove-Variable vmdk_uuid
					}
					Remove-Variable arrVMDKs
					
					# Cycle through extent output and match to VMDK.
					foreach ($extent in $arrExtents) {
						$extent | Add-Member -MemberType "NoteProperty" -Name "vCenterServer" -Value $vCenterServer
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMPersistentID" -Value $objVM.PersistentId
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMDKName" -Value $null
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMDKFilename" -Value $null
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMDKDiskType" -Value $null
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMDKStorageFormat" -Value $null
						$extent | Add-Member -MemberType "NoteProperty" -Name "VMDKUUID" -Value $null
						if ($htVMDKs.ContainsKey("$($extent.DiskSerialNumber)")) {
							$vmdk = $htVMDKs["$($extent.DiskSerialNumber)"]
							$extent.VMDKName = $vmdk.Name
							$extent.VMDKFilename = $vmdk.Filename
							$extent.VMDKDiskType = $vmdk.DiskType
							$extent.VMDKStorageFormat = $vmdk.StorageFormat
							$extent.VMDKUUID = $vmdk.UUID
						}
					}
				}
			}
			
			# Return output.
			$arrExtents
		}
	}
	
	End {
		if ($objVCenterConnection) {
			$objVCenterConnection | Disconnect-VIServer -Confirm:$false -Force -ErrorAction "SilentlyContinue" > $null
		}
	}
}