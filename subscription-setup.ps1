$spDisplayName = "00TestPrincipal"
$subscriptionIds = @("5a2628d8-83e6-4e03-a21e-81ec51fb14cf")
$tenantId = "05b5620f-3842-4876-bc0d-e29c07d272cc"
$cancel = $false

function aad-auth{
    $currentTenant = Get-AzureADTenantDetail
    "`n"
    "Current Tenant Information Below:"
    "Name: $($currentTenant.DisplayName)"
    "ID: $($currentTenant.ObjectId)"
    "`n"
    $confirmation = Read-Host 'Validate you are in the correct tenant according to the above information. If this is the incorrect tenant, type "Cancel". If it is the correct tenant, press Enter.'
        if($confirmation -eq "Y"){
            Disconnect-AzureAD > $null
            Connect-AzureAD -TenantId $tenantId > $null
        }elseif($confirmation -eq "Cancel"){
            $script:cancel = $true
            return
        }
    }
}

function get-sp($spDisplayName){
    $script:sp = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq $spDisplayName}
}

function create-sp($spDisplayName){
    "`n"
    "Creating new Service Principal"
    $signInURL = "https://labondemand.com/User/SignIn"
    #New-AzureADServicePrincipal -DisplayName 00TestPrincipal

    $msGraphPrincipal = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq "Microsoft Graph"}
    $msGraphAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $msGraphAccess.ResourceAppId = $msGraphPrincipal.AppId
    foreach($guid in $($msGraphPrincipal.Oauth2Permissions.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $msGraphAccess.ResourceAccess += $resourceAccess
    }
    foreach($guid in $($msGraphPrincipal.AppRoles.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $msGraphAccess.ResourceAccess += $resourceAccess
    }

    $aadGraphPrincipal = Get-AzureADServicePrincipal -All $true | Where-Object {$_.DisplayName -eq "Windows Azure Active Directory"}
    $aadGraphAccess = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
    $aadGraphAccess.ResourceAppId = $aadGraphPrincipal.AppId
    foreach($guid in $($aadGraphPrincipal.Oauth2Permissions.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $aadGraphAccess.ResourceAccess += $resourceAccess
    }
    foreach($guid in $($aadGraphPrincipal.AppRoles.Id)){
        $resourceAccess = New-Object -TypeName "microsoft.open.azuread.model.resourceAccess" -ArgumentList $guid, "Scope"
        $aadGraphAccess.ResourceAccess += $resourceAccess
    }

    $app = New-AzureADApplication -DisplayName $spDisplayName -HomePage $signInURL -ReplyUrl $signInURL -RequiredResourceAccess $msGraphAccess,$aadGraphAccess
    #Set-AzureADApplication -ObjectId $app.ObjectId -RequiredResourceAccess $aadGraphAccess
    $script:sp = New-AzureADServicePrincipal -AppId $app.AppId 
    $secret = New-AzureADApplicationPasswordCredential -ObjectId $app.ObjectId -CustomKeyIdentifier "LOD Initial Setup" -EndDate (date).AddYears(50)

    $AppInfo = [pscustomobject]@{
        'Application Id' = $app.AppId
        'Application Secret' =  $secret.Value
    }
}

function create-role-assignment($spDisplayName,$subscriptionId){
    $roleAssignment = Get-AzRoleAssignment -ObjectId $sp.ObjectId -Scope "/subscriptions/$subscriptionId/" -RoleDefinitionName "Owner"
    if($roleAssignment -eq $null){
        while ($addRole.DisplayName -ne $sp.DisplayName ) {
        Start-Sleep -Seconds 30
        Write-Host "Waiting for Initial Service Principal Role Assignment (this may take a couple minutes)."
        $addRole = New-AzRoleAssignment -ObjectId $sp.ObjectId -Scope "/subscriptions/$subscriptionId/" -RoleDefinitionName "Owner" -ErrorAction Ignore
        }
        "Service Principal assigned as Owner to subscription $subscriptionId."
    }else{
        "Service Principal already assigned as Owner to subscription $subscriptionId. Continuing..."
    }
}

function arm-auth($subscriptionId){
    $subscription = ''
    try{$subscription = Get-AzSubscription -SubscriptionId $subscriptionid}catch{}
    $script:subscriptionName = $subscription.Name
    if($subscription -eq $null){
        $confirmation = Read-Host "`nSubscription ID $subscriptionId not detected in current context. Would you like to login to a different account?(Y/Cancel)"
        if($confirmation -eq "Y"){
            Logout-AzAccount > $null
            $subscription = Login-AzAccount -SubscriptionId $subscriptionId > $null
            $script:subscriptionName = $subscription.Context.Subscription.Name
        }elseif($confirmation -eq "Cancel"){
            $script:cancel = $true
            return
        }
    }elseif($subscription.Id -ne $subscriptionId){
        Select-AzSubscription -Subscription $subscriptionId > $null
    }
    "`nConfiguring $subscriptionName"
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

#validate-module
aad-auth
if($cancel -eq $true){return "You have identified this as the incorrect tenant. Please login to the correct tenant and try again."}
get-sp -spDisplayName $spDisplayName
if($sp -eq $null){
    create-sp -spDisplayName $spDisplayName
    Write-Host "Service Principal Created, use the below items for authentication info."
    Write-Warning "Be sure to record your secret somewhere secure! This cannot be retrieved in the future."
    $AppInfo | fl
    Read-Host 'After you have put your authentication information in a secure location, press any key when ready to continue.'

}else{
    "`n"
    "Service Principal Found. Continuing..."
}

"Continuing to Subscription Configuration"
foreach($subscriptionId in $subscriptionIds){
    arm-auth -subscriptionId $subscriptionId
    if($cancel -eq $true){return "Cancelling Subscription Setup."}    
    configure-resource-providers -subscriptionId $subscriptionId -subscriptionName $subscriptionName
    create-role-assignment -spDisplayName $spDisplayName -subscriptionId $subscriptionId
}
