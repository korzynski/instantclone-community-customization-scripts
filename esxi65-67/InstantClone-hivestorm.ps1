<#
.SYNOPSIS Script to deploy Nested ESXi Instasnt Clones
.NOTES  Author:  William Lam
.NOTES  Site:    www.virtuallyghetto.com
.NOTES  Reference: http://www.virtuallyghetto.com/2018/05/leveraging-instant-clone-in-vsphere-6-7-for-extremely-fast-nested-esxi-provisioning.html
.NOTES  Customized by korin for WGU CyberClub Hivestorm 2022 practice and competition environment
#>

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Import-Module InstantClone.psm1

$SourceVM = "Nested_ESXi7.0u2a"
$VIServer = "vcenter.wgucc.net"
$VIDatacenter = "WGUCC_Labs"
$portgroupBaseName = "Hivestorm"

$VIUser = Read-Host 'VI User' # administrator@vsphere.local
$VIPassword = Read-Host 'VI Password'

$VMPassword = "VMware1!" #default password for nested clones

$numOfHosts = 9 #Number of clones to create
$nameBase = "hivestorm"

$ipNetwork = "172.31"
$netmask = "255.255.255.0"
$networktype = "static" # static or dhcp
$dnsDomain = "wgucc.net"



$StartTime = Get-Date
Write-host ""
$esxHostList = new-object -TypeName System.Collections.ArrayList

if ($global:DefaultVIServers.Count -ne 0) {
    disconnect-viserver -force -confirm:$false
}

$VC = connect-viserver -server $VIServer -user $VIUser -password $VIPassword


foreach ($i in 1..$numOfHosts) {
    $newVMName = "$nameBase$i.$dnsDomain"
    $VMIPAddress = "$ipNetwork.$i.2" # Network address will use the clone number as the second octet

    # Generate random UUID which will be used to update
    # ESXi Host & VSAN Node UUID
    $uuid = [guid]::NewGuid()
    # Changing ESXi Host UUID requires format to be in hex
    $uuidHex = ($uuid.ToByteArray() | %{"0x{0:x}" -f $_}) -join " "

    $guestCustomizationValues = @{
        "guestinfo.ic.hostname" = "$newVMName"
        "guestinfo.ic.ipaddress" = "$VMIPAddress"
        "guestinfo.ic.netmask" = "$netmask"
        "guestinfo.ic.gateway" = "$ipNetwork.$i.1"
        "guestinfo.ic.dns" = "$ipNetwork.$i.1"
        "guestinfo.ic.sourcevm" = "$SourceVM"
        "guestinfo.ic.networktype" = "$networktype"
        "guestinfo.ic.uuid" = "$uuid"
        "guestinfo.ic.uuidHex" = "$uuidHex"
    }
    $ipStartingCount++

    # Create Instant Clone
    New-InstantClone -SourceVM $SourceVM -DestinationVM $newVMName -CustomizationFields $guestCustomizationValues

    # Retrieve newly created Instant Clone
    $VM = Get-VM -Name $newVMName

    # assign to portgroup
    $VM | Get-NetworkAdapter -Name "Network adapter 1" | Set-NetworkAdapter -Portgroup $portgroupBaseName$i -confirm:$false

    #add to the list
    $esxHostList.add($VM)
   
}

#korin - skip adding to vCenter until I can fix the datastore conflicting GUID issue
<#
# Add new Hosts to vCenter
foreach ($esxHost in $esxHostList) {


    $esxHostIP = $esxHost.guest.IPAddress[0]
    $vESXi = $null

    Write-host -NoNewline "Waiting for $($esxHost.name) to come online."
    $esxOnline=$false
    For ($i=0; $i -le 10; $i++) {
        try {
            write-host -NoNewLine "."
            if (Test-Connection -ComputerName $esxHostIP -Quiet) {
                write-host " Online!"
                $esxOnline=$true
                break
            }
        }
        catch {
            #Host not ready yet, sleep 5 seconds ...
            sleep 5
        }
     
    }

    if ($esxOnline) {
        try {
            $vESXi = Connect-VIServer -Server $esxHostIP -User root -Password $VMPassword -WarningAction SilentlyContinue
        }
        catch {
            write-host "Failed to connect to $($esxHost.name)."
        }

        if ($vESXi.IsConnected) {
            write-host "Connected to $($esxhost.name)."

            #Before adding to vCenter, we have to resignature the datastore, otherwise the UUID will conflict with the datastores from the other clones
            #first, connect to the host, put it in maintenance mode and get a cli object

            $datastore = get-datastore -server $esxHostIP
            $esxcli = Get-EsxCli -VMhost $esxHostIP -V2

            # unregister hosted VMs to apply the datastores new UUID
            $childVMs = get-vm -server $esxHostIP
            foreach ($childVM in $childVMs) {
                #record path to remount the VM later
                $childVM | add-member -NotePropertyName VMPathNote -NotepropertyValue $childVM.ExtensionData.Config.Files.VmPathName
                Remove-VM -VM $childVM -DeletePermanently:$false -Confirm:$false
            }

            #resignature the datastore
            write-host "unmounting $($datastore.Name)"
            $esxcli.storage.filesystem.unmount.invoke(@{volumelabel = $datastore.Name})
            write-host "resignaturing $($datastore.Name)"
            $esxcli.storage.vmfs.snapshot.resignature.invoke(@{volumelabel=$datastore.name})

    
            #register VMs
            foreach ($childVM in $childVMs) {
                write-host "Registering $($childVM.name)"
                New-VM -VMFilePath $childVM.VmPathNote -vmhost $esxHost.name -Confirm:$false
            }
    
            #add to vCenter
            write-host "Adding $newVMName to vCenter Server $VIDatacenter"
            Add-VMHost -Server $VC -Location $VIDatacenter -User "root" -Password $VMPassword -Name $newVMName -Force

            #disconnect from the host
            disconnect-viserver -Server $esxHostIP -force -confirm:$false
        }
        else {
                write-host "Failed to connect to $($esxhost.name)"
        }
    }
    else {
        write-host "$($esxHost.name) can't be reached"
    }
}
#>

#Restart frozen source VM
#Restart-VM -VM $SourceVM -Confirm:$False

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

Write-Host -ForegroundColor Cyan  "`nTotal Instant Clones: $numOfVMs"
Write-Host -ForegroundColor Cyan  "StartTime: $StartTime"
Write-Host -ForegroundColor Cyan  "  EndTime: $EndTime"
Write-Host -ForegroundColor Green " Duration: $duration minutes"

Disconnect-VIServer -Force -Confirm:$false