# PowerCLI script to create a CentOS v7.x Linux VM for running Perforce with the following disk layout:
# SCSI 0:0 = 12GB HDD on paravirtual
#   This will become:
#   /boot
#   swap
#   /
# 
# SCSI 0:1 = 10GB HDD on paravirtual
#   This will be mounted at /metadata
# SCSI 0:2 = 25GB HDD on paravirtual
#   This will be mounted at /depotdata
# SCSI 0:3 = 10GB HDD on paravirtual
#   This will be mounted at /logs
# 
#   

# VM host we will create the VM on
# $VS5_Host = "192.168.1.10"
$VS5_Host = "10.254.250.52"
# Name of VM we want to create
$vmName1 = "Perforce"
# How many vCPUs in the VM
$vm_cpu = 2
# How much RAM in the VM (in GB)
$vmRAM = 8
# The public network the VM will talk on
$public_network_name = "VMs"
# The datastore name that the boot drive (XFS) will reside on
$osstore = "RAID0"
# Size of the boot drive (in GB)
$osstore_size_GB = 12
# OS Install ISO - I'm using the CentOS network install ISO
$isofile = "[RAID0] ISOs/CentOS-7.0-1406-x86_64-DVD.iso"
# Guest OS type in vSphere, this value works for RHEL/CentOS v6
$guestid = "rhel6_64Guest"
# The vSphere folder name (in the Inventory -> VMs and Templates view in vSphere) that the VM will be created in.
$location = "Perforce"

#===============================================================================

# Stops the client whining about certs
Set-PowerCLIConfiguration -InvalidCertificateAction ignore

# Edit these values to suit your environment
# Connect-VIServer -server vcenter.dev.acme.com -User root -Password *******************
Connect-VIServer -server vcenter.devdmz.mywebgrocer.com -User root -Password MyWebGrocer2013#

# Don't edit below this line
#===============================================================================

# Load our functions module
# PowerShell modules must reside in one of the paths listed in $env:PSModulePath
# By default for the current user that is: %HOMEPATH%\Documents\WindowsPowerShell\Modules
Import-Module vsphere_functions.psm1

# Create the basic VM
$VM1 = new-vm `
-Host "$VS5_Host" `
-Name $vmName1 `
-Datastore (get-datastore "$osstore") `
-Location $location `
-GuestID $guestid `
-CD `
-MemoryGB $vmRAM `
-DiskGB $osstore_size_GB `
-NetworkName "$public_network_name" `
-DiskStorageFormat "Thin" `
-Version "v8" `
-NumCpu $vm_cpu `
-Confirm:$false

# Create data HDDs
$New_Disk1 = New-HardDisk -vm($VM1) -CapacityGB "10" -StorageFormat Thin -datastore "SSD"
# set-harddisk -Confirm:$false -harddisk $New_Disk1 -controller $New_SCSI_1_1
$New_Disk2 = New-HardDisk -vm($VM1) -CapacityGB "25" -StorageFormat Thin -datastore "RAID0"
# set-harddisk -Confirm:$false -harddisk $New_Disk2 -controller $New_SCSI_1_1
$New_Disk3 = New-HardDisk -vm($VM1) -CapacityGB "10" -StorageFormat Thin -datastore "RAID0"
# set-harddisk -Confirm:$false -harddisk $New_Disk3 -controller $New_SCSI_1_1

# Set VM to boot from BIOS on first boot so that we can disable the floppy/serial/parallel ports etc.
# Requires external modules
Get-VM $vmName1 | Set-VMBIOSSetup -PassThru

# Remove serial/parallel ports - Still needs disabling in the BIOS though...
# Requires external modules
# Get-VM $vmName1 | Get-SerialPort | Remove-SerialPort
# Get-VM $vmName1 | Get-ParallelPort | Remove-ParallelPort

# Set any additional VM params that are useful
# Based on: https://github.com/rabbitofdeath/vm-powershell/blob/master/vsphere5_hardening.ps1
$ExtraOptions = @{
	# Creates /dev/disk/by-id in Linux
	"disk.EnableUUID"="true";
	# Disable virtual disk shrinking
	"isolation.tools.diskShrink.disable"="true";
	"isolation.tools.diskWiper.disable"="true";
	# 5.0 Prevent device removal-connection-modification of devices
	"isolation.tools.setOption.disable"="true";
	"isolation.device.connectable.disable"="true";
	"isolation.device.edit.disable"="true";
	# Disable copy/paste operations to/from VM
	"isolation.tools.copy.disable"="true";
	"isolation.tools.paste.disable"="true";
	"isolation.tools.dnd.disable"="false";
	"isolation.tools.setGUIOptions.enable"="false";
	# Disable VMCI
	"vmci0.unrestricted"="false";
	# Log Management
	"tools.setInfo.sizeLimit"="1048576";
	"log.keepOld"="10";
	"log.rotateSize"="100000";
	# Limit console connections - choose how many consoles are allowed
	#"RemoteDisplay.maxConnections"="1";
	"RemoteDisplay.maxConnections"="2";
	# 5.0 Disable serial port
	"serial0.present"="false";
	# 5.0 Disable parallel port
	"parallel0.present"="false";
	# 5.0 Disable USB
	"usb.present"="false";
	# Disable VIX Messaging from VM
	"isolation.tools.vixMessage.disable"="true"; # ESXi 5.x+
	"guest.command.enabled"="false"; # ESXi 4.x
	# Disable logging
	#"logging"="false";	
	# 5.0 Disable HGFS file transfers [automated VMTools Upgrade]
	"isolation.tools.hgfsServerSet.disable"="false";
	# Disable tools auto-install; must be manually initiated.
	"isolation.tools.autoInstall.disable"="false";
	# 5.0 Disable VM Monitor Control - VM not aware of hypervisor
	#"isolation.monitor.control.disable"="true";
	# 5.0 Do not send host information to guests
	"tools.guestlib.enableHostInfo"="false";
}

# Build our configspec using the hashtable from above.
$vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec

# Note we have to call the GetEnumerator before we can iterate through
Foreach ($Option in $ExtraOptions.GetEnumerator()) {
    $OptionValue = New-Object VMware.Vim.optionvalue
    $OptionValue.Key = $Option.Key
    $OptionValue.Value = $Option.Value
    $vmConfigSpec.extraconfig += $OptionValue
}
# Change our VM settings
$vmview=get-vm $vmName1 | get-view
$vmview.ReconfigVM_Task($vmConfigSpec)

# Attach an OS install ISO
Get-CDDrive -VM $vmName1 | Set-CDDrive -IsoPath $isofile –StartConnected $True -confirm:$false

# Start the VM
# Start-VM $vmName1

# Eject the ISO when we are finished installing the OS
# Get-CDDrive -VM $vmName1 | Set-CDDrive -NoMedia -confirm:$false

# Stop the VM
$date = Get-Date -format "MMM-dd-yyyy"
$name = "$date - $env:USERNAME"
$desc = "Base OS only installed, no apps"
New-Snapshot -VM $vmName1 -Name $name -Description $desc

# TO-DO
# Grab the MAC address of the VM and add a DHCP reservation for the VM
