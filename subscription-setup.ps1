#to use: iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/James-Burnham/Test/master/subscription-setup.ps1'))

$cancel = $false

function aad-auth{
    $currentTenant = Get-AzureADTenantDetail
    "`n"
    "Current Tenant Information Below:"
    "Name: $($currentTenant.DisplayName)"
    "ID: $($currentTenant.ObjectId)"
    "`n"
    $confirmation = Read-Host 'Validate you are in the correct tenant according to the above information. If this is the incorrect tenant, type "Cancel". If it is the correct tenant, press Enter.'
    if($confirmation -eq "Cancel"){
        $script:cancel = $true
        return
    }
}

function get-spperms{
    $msGraphPrincipal = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq "Microsoft Graph"}
    $script:msGraphAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $script:msGraphAccess.ResourceAppId = $msGraphPrincipal.AppId
    foreach($guid in $($msGraphPrincipal.Oauth2Permissions.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $script:msGraphAccess.ResourceAccess += $resourceAccess
    }
    foreach($guid in $($msGraphPrincipal.AppRoles.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $script:msGraphAccess.ResourceAccess += $resourceAccess
    }

    $aadGraphPrincipal = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq "Windows Azure Active Directory"}
    $script:aadGraphAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $script:aadGraphAccess.ResourceAppId = $aadGraphPrincipal.AppId
    foreach($guid in $($aadGraphPrincipal.Oauth2Permissions.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $script:aadGraphAccess.ResourceAccess += $resourceAccess
    }
    foreach($guid in $($aadGraphPrincipal.AppRoles.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $script:aadGraphAccess.ResourceAccess += $resourceAccess
    }
}

function get-sp($spDisplayName){
    $script:spDisplayName = ''
    $script:spDisplayName = Read-Host 'Enter the name of your service principal here. If left blank, it will default to "cloud-slice-app"'
    if($spDisplayName -eq ""){
        $script:spDisplayName = "cloud-slice-app"
    }
    $spDisplayName
    $script:sp = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq $spDisplayName}
    if($sp -ne $null){
        $app = Get-AzureADApplication -All $true | Where-Object {$_.DisplayName -eq $spDisplayName}
        Set-AzureADApplication -ObjectId $app.ObjectId -RequiredResourceAccess $msGraphAccess,$aadGraphAccess
    }
}

function create-sp($spDisplayName){
    "`n"
    "Creating new Service Principal"
    $signInURL = "https://labondemand.com/User/SignIn"
    
    $app = New-AzureADApplication -DisplayName $spDisplayName -HomePage $signInURL -ReplyUrl $signInURL -RequiredResourceAccess $msGraphAccess,$aadGraphAccess
    $script:sp = New-AzureADServicePrincipal -AppId $app.AppId 
    $secret = New-AzureADApplicationPasswordCredential -ObjectId $app.ObjectId -CustomKeyIdentifier "LOD Initial Setup" -EndDate (get-date).AddYears(50)
    $companyAdminRole = Get-AzureADDirectoryRole | Where-Object DisplayName -eq 'Company Administrator'
    Add-AzureADDirectoryRoleMember -ObjectId $companyAdminRole.ObjectId -RefObjectId $sp.ObjectId
    
    $script:AppInfo = [pscustomobject]@{
        'Application Name' = $app.DisplayName
        'Application Id' = $app.AppId
        'Application Secret' =  $secret.Value
    }
}

function create-role-assignment($spDisplayName,$subscriptionId,$sp){
    $roleAssignment = Get-AzRoleAssignment -ObjectId $sp.ObjectId -Scope "/subscriptions/$subscriptionId/" -RoleDefinitionName "Owner"
    if($roleAssignment -eq $null){
        $addRole = New-AzRoleAssignment -ObjectId $sp.ObjectId -Scope "/subscriptions/$subscriptionId/" -RoleDefinitionName "Owner" -ErrorAction Ignore
        while ($addRole.DisplayName -ne $sp.DisplayName ) {
        Write-Host "Waiting for Initial Service Principal Role Assignment (this may take a couple minutes)."
        Start-Sleep -Seconds 30
        $addRole = New-AzRoleAssignment -ObjectId $sp.ObjectId -Scope "/subscriptions/$subscriptionId/" -RoleDefinitionName "Owner" -ErrorAction Ignore
        }
        "Service Principal assigned as Owner to subscription $subscriptionId."
    }else{
        "Service Principal already assigned as Owner to subscription $subscriptionId. Continuing..."
    }
}

function get-subscriptions{
    $script:subscriptionIds = @()
    Do {
    "`n"
    $subscriptions = Get-AzSubscription | Sort-Object -Property Name
    $menu = @{}
    for ($i=1;$i -le $subscriptions.count; $i++) {
        Write-Host "$i. $($subscriptions[$i-1].Name) - $($subscriptions[$i-1].Id)"
        $menu.Add($i,($subscriptions[$i-1].Id))
        }
    "Currently Selected:"
    $script:subscriptionIds | fl
    "`n"
    [int]$ans = Read-Host 'Select Subscription Number(s), input 0 or leave blank when ready to proceed with current selections'
    if($ans -eq '0'){
        break
    }
    $selection = $menu.Item($ans)
    $script:subscriptionIds += $selection
    } While ($True)
    $script:subscriptionIds = $script:subscriptionIds | Select-Object -Unique
    "`n"
    "Selected Subscriptions for Configuration:"
    $script:subscriptionIds | fl
    if($script:subscriptionIds -eq $null){
        "return"
    }
}

function configure-resource-providers($subscriptionId,$subscriptionName){
    "Registering Resource Providers for subscription ${subscriptionId}:"
    # Register most providers
    Get-AzResourceProvider -ListAvailable | Where-Object {$_.RegistrationState -ne "Registered"} | foreach-object{
        $registering = Register-AzResourceProvider -ProviderNamespace $_.ProviderNamespace -ErrorAction Ignore
        if($registering -ne $null){
            "$($registering.ProviderNamespace): $($registering.RegistrationState)"
        }
    }

    # Register Databricks Provider
    $databricks = Get-AzResourceProvider -ProviderNamespace Microsoft.Databricks
    if($databricks.RegistrationState -ne "Registered"){
        $registering = Register-AResourceProvider -ProviderNamespace Microsoft.Databricks
        "$($registering.ProviderNamespace): $($registering.RegistrationState)"
    }

    # Register site recovery provider
    $siterecovery = Get-AzResourceProvider -ProviderNamespace Microsoft.SiteRecovery
    if($siterecovery.RegistrationState -ne "Registered"){
        $registering = Register-AzResourceProvider -ProviderNamespace Microsoft.SiteRecovery
        "$($registering.ProviderNamespace): $($registering.RegistrationState)"
    }
    "All resource providers registered for $subscriptionName."
}

aad-auth
if($cancel -eq $true){return "You have identified this as the incorrect tenant. Please login to the correct tenant and try again."}
get-spperms
get-sp -spDisplayName $spDisplayName
if($sp -eq $null){
    create-sp -spDisplayName $spDisplayName
    Write-Host "Service Principal Created, use the below items for authentication info."
    Write-Warning "Be sure to record your secret somewhere secure! This cannot be retrieved in the future."
    $AppInfo | fl
    Read-Host 'After you have put your authentication information in a secure location, press the Enter key when ready to continue'
}else{
    "`n"
    "Service Principal found, validating permissions."
}

"Continuing to Subscription Configuration"
get-subscriptions
foreach($subscriptionId in $script:subscriptionIds){
    $subscription = Select-AzSubscription -Subscription $subscriptionId
    $subscriptionName = $subscription.Subscription.Name
    "`nConfiguring $subscriptionName - $subscriptionId"
    if($cancel -eq $true){return "Cancelling Subscription Setup."}    
    configure-resource-providers -subscriptionId $subscriptionId -subscriptionName $subscriptionName
    create-role-assignment -spDisplayName $spDisplayName -subscriptionId $subscriptionId -sp $sp
}
