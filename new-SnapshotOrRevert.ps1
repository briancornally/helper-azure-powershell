<#
.SYNOPSIS
	create snapshot, or if one already exists revert to latest snapshot 
	
.DESCRIPTION
	if no existing snapshot then snapshot VM; else revert to latest snapshot
    note: for revert, VM must be removed to clear storage lease & then recreated
    note2: snapshots can be created with VM powered-on. However snapshot created on a busy database classic VM was once noted as corrupted & recovery was not possible. 
	
.NOTES
    Author: Brian Cornally
#>
# create snapshot if it doesn't exist

$VerbosePreference='SilentlyContinue'
#$VerbosePreference='Continue'
$ErrorActionPreference = 'Stop'
$stopwatch=[system.diagnostics.stopwatch]::startNew()

# Set variable values
$vmName = "testvm"
$resourceGroupName = "resourcegroup13579"

# get & save configuration to a file
$vm=get-azurermvm -ResourceGroupName $ResourceGroupName -Name $vmName 
$vm | ConvertTo-Json | out-file "$vmName.json"
$vmConfig=Get-Content "$vmName.json" | ConvertFrom-Json
#$vmConfig | out-file "$vmName.txt"

# infer settings
$location = $vmConfig.Location
$vmSize = $vmConfig.HardwareProfile.VmSize
$vnetName = $resourceGroupName
$nicName = $vmConfig.NetworkInterfaceIDs.split("/")[-1]
$dnsName = $vmName
$vmConfig.StorageProfileText -match "https://(.*).blob.core.windows.net" > $null
$storageAccountName = $Matches[1]
$diskName = $vmConfig.StorageProfile.OsDisk.Name;
$publicIpName = $vmName
$vmConfig.StorageProfileText  -match "https://.*.blob.core.windows.net/.*.vhd" > $null
$osVhdUri=$Matches[0]
$osVhdName=$osVhdUri.split("/")[-1]

$adminUsername = 'localadmin'
$adminPassword = '*****'
$Container="vhds"

<#
write-host "power off VM..." -ForegroundColor Green
Stop-AzureRMVM -ResourceGroupName $resourceGroupName -Name $vmName -Force -Verbose
#>

$StorageKey = (Get-AzureRmStorageAccountKey -storageaccountname $StorageAccountName -ResourceGroupName $ResourceGroupName -ErrorAction Stop).Key1
$Context = New-AzureStorageContext  -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKey 
#Get-AzureStorageContainer -Context $Context -Name $Container | Get-AzureStorageBlob | ? name -match "vhd" | select name
$Blob=Get-AzureStorageContainer -Context $Context -Name $Container | Get-AzureStorageBlob | ? Name -match $osVhdName | ? -Property SnapshotTime -EQ $null 
$Snapshots=Get-AzureStorageContainer -Context $Context -Name $Container | Get-AzureStorageBlob | ? Name -match $osVhdName | ? -Property SnapshotTime
if ($Snapshots -eq $null) {
    write-host "no existing snapshot. create one" -ForegroundColor Green
    $Blob.ICloudBlob.CreateSnapshot()
} else {
    write-host "existing snapshot detected. reverting to latest" -ForegroundColor Green

    write-host "remove vm to clear storage lease ..." -ForegroundColor Green
    remove-AzureRMVM -ResourceGroupName $resourceGroupName -Name $vmName -Force -Verbose

    write-host "overwrite original blob" -ForegroundColor Green
    $snapshot = Get-AzureStorageContainer -Context $Context -Name $Container | Get-AzureStorageBlob | Where-Object -Property SnapshotTime | select -Last 1 # most recent snapshot
    Start-AzureStorageBlobCopy -ICloudBlob $snapshot.ICloudBlob -DestICloudBlob $Blob.ICloudBlob -Context $ctx -force
    $Blob.ICloudBlob.CopyState # copy is immediate

    write-host "re-create VM ..." -ForegroundColor Green
    $nic=get-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $resourceGroupName

    Write-Verbose "Creating VM $vmName Config"
    $vm = $null
    $vm = New-AzureRmVMConfig -vmName $vmName -VMSize $vmSize 
    $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzureRMVMOSDisk -VM $vm -Name $osVhdName -VhdUri $osVhdUri -CreateOption Attach -Windows

    Write-Verbose "Creating VM $vmName ..."
    $result = New-AzureRmVM -ResourceGroupName $resourceGroupName -Location $location -VM $vm  
    if ($result.StatusCode -ne "OK") {
        throw "failed: suggest retry the New-AzureRmVM command" 
        $result
    }
    # open rdp
    $IpAddress=(Get-AzureRmPublicIpAddress -Name $vmName -ResourceGroupName $ResourceGroupName).IpAddress
    $command="cmdkey"
    $Argumentlist="/generic:$IpAddress /user:$adminUsername /pass:$adminPassword"
    Start-Process -FilePath $command -ArgumentList $Argumentlist
    $command="mstsc"
    $Argumentlist="/v $IpAddress"
    Start-Process -FilePath $command -ArgumentList $Argumentlist
}
$stopwatch.stop
"completed in {0:N0} minutes" -f $stopwatch.Elapsed.TotalMinutes