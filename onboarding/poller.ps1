<# 
 AD Onboarding Poller
 - Receives onboarding payloads from SQS
 - Creates on-prem AD users (clone selected attributes from a template + payload overrides)
 - Adds to on-prem groups
 - Deletes SQS message on success
#>

#region Configuration ----------------------------------------------------------
$SqsQueueUrl   = "https://sqs.us-east-1.amazonaws.com/699041963732/newhire-queue"
$AwsRegion     = "us-east-1"

$BasePath      = "C:\Onboarding"
$NewUsersFile  = Join-Path $BasePath "PostSync\NewHires.csv"
$LogFile       = Join-Path $BasePath "Logs\Poller.log"

# AD defaults
$OUPath        = "CN=Users,DC=lab,DC=local"
$PasswordLength = 16
$EnableAccount  = $true
$ChangePasswordAtNextLogon = $true

# Poll behavior
$MaxPerReceive   = 5
$WaitTimeSeconds = 20
$VisibilitySec   = 300
$SleepBetweenDrainsSec = 2

# Retry tuning
$MaxCreateRetries   = 2
$MaxAddGroupRetries = 2
#endregion --------------------------------------------------------------------

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts [$Level] $Message"
    try {
        $dir = Split-Path $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    } catch {}
    Write-Output $line
}

# Ensure CSV folder
try {
    $csvDir = Split-Path $NewUsersFile
    if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Force -Path $csvDir | Out-Null }
} catch {}

# Modules
try { Import-Module ActiveDirectory -ErrorAction Stop; Log "Imported ActiveDirectory module." } catch { Log ("ActiveDirectory module not available: " + ($_ | Out-String)) "ERROR"; throw }
try { Import-Module AWS.Tools.SQS    -ErrorAction Stop; Log "Imported AWS.Tools.SQS module."    } catch { Log ("AWS.Tools.SQS module not available: "    + ($_ | Out-String)) "ERROR"; throw }

function New-RandomPassword {
    param([int]$Length = 16)
    Add-Type -AssemblyName System.Web
    [System.Web.Security.Membership]::GeneratePassword($Length, 4)
}

function Append-NewHireCsv {
    param([string]$Upn, [string]$JobTitle)
    $record = [PSCustomObject]@{
        UserPrincipalName = $Upn
        JobTitle          = $JobTitle
        Timestamp         = (Get-Date).ToString("s")
    }
    if (-not (Test-Path $NewUsersFile)) {
        $record | Export-Csv -Path $NewUsersFile -NoTypeInformation
    } else {
        $record | Export-Csv -Path $NewUsersFile -NoTypeInformation -Append
    }
    Log ("Appended CSV -> " + $Upn + "," + $JobTitle)
}

function Get-TemplateUser {
    param([string]$Identifier)
    if (-not $Identifier) { return $null }
    try {
        if ($Identifier -match '^[0-9a-fA-F\-]{36}$') {
            $u = Get-ADUser -Identity $Identifier -Properties * -ErrorAction SilentlyContinue
            if ($u) { return $u }
        }
        $u = Get-ADUser -Filter "SamAccountName -eq '$Identifier'"    -Properties * -ErrorAction SilentlyContinue
        if ($u) { return $u }
        $u = Get-ADUser -Filter "UserPrincipalName -eq '$Identifier'" -Properties * -ErrorAction SilentlyContinue
        if ($u) { return $u }
        $u = Get-ADUser -Identity $Identifier -Properties * -ErrorAction SilentlyContinue
        return $u
    } catch {
        Log ("Get-TemplateUser error for '" + $Identifier + "': " + ($_ | Out-String)) "ERROR"
        return $null
    }
}

function Process-Message {
    param([hashtable]$Payload)

    # Extract payload fields
    $templateId  = $null
    $memberOf    = $null
    $upn         = $null
    $givenName   = $null
    $sn          = $null
    $displayName = $null
    $jobTitle    = $null
    $office      = $null

    if ($Payload.ContainsKey('templateUserId'))     { $templateId  = $Payload.templateUserId }
    if ($Payload.ContainsKey('memberOf'))           { $memberOf    = $Payload.memberOf }
    if ($Payload.ContainsKey('userPrincipalName'))  { $upn         = $Payload.userPrincipalName }
    if ($Payload.ContainsKey('givenName'))          { $givenName   = $Payload.givenName }
    if ($Payload.ContainsKey('sn'))                 { $sn          = $Payload.sn }
    if ($Payload.ContainsKey('displayName'))        { $displayName = $Payload.displayName }
    if ($Payload.ContainsKey('title'))              { $jobTitle    = $Payload.title }
    if ($Payload.ContainsKey('physicalDeliveryOfficeName')) { $office = $Payload.physicalDeliveryOfficeName }

    if (-not $templateId) { Log "Payload missing templateUserId; skipping." "WARN"; return $false }
    if (-not $upn)        { Log "Payload missing userPrincipalName; skipping." "ERROR"; return $false }

    # Idempotency
    $exists = $null
    try { $exists = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties * -ErrorAction SilentlyContinue } catch {}
    if ($exists) {
        Log ("User already exists: " + $upn + " (sAM: " + $exists.SamAccountName + ")")
        $jt = if ($jobTitle) { $jobTitle } else { "UNKNOWN" }
        try { Append-NewHireCsv -Upn $upn -JobTitle $jt } catch {}
        return $true
    }

    # Template user
    $templateUser = Get-TemplateUser -Identifier $templateId
    if (-not $templateUser) { Log ("Template user not found: " + $templateId) "ERROR"; return $false }

    # Build names
    if (-not $givenName -and $displayName) {
        $givenName = ($displayName -split '\s+')[0]
    }
    if (-not $sn -and $displayName) {
        $sn = ($displayName -split '\s+')[-1]
    }
    $gName = if ($givenName) { [string]$givenName } else { "" }
    $sName = if ($sn)       { [string]$sn }       else { "" }
    $disp  = if ($displayName -and ($displayName -ne "")) { [string]$displayName } else { ($gName + " " + $sName).Trim() }
    if (-not $disp) { $disp = $upn }

    # sAM from UPN
    $sam = ($upn -split '@')[0]
    Log ("Initial sAMAccountName candidate: " + $sam)
    $orig = $sam; $i = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $sam = $orig + $i; $i++
        if ($i -gt 100) { Log ("Too many duplicates for base sAM '" + $orig + "'") "ERROR"; return $false }
    }
    if ($sam -ne $orig) { Log ("Adjusted sAMAccountName to: " + $sam) }

    # Target OU (from template DN if possible)
    $targetOU = $OUPath
    try {
        $dn = $templateUser.DistinguishedName
        $idx = $dn.IndexOf("OU=")
        if ($idx -ge 0) { $targetOU = $dn.Substring($idx) }
    } catch {}

    # Create user (PassThru so we can keep the object)
    $newUserParams = @{
        Name                 = $disp
        SamAccountName       = $sam
        UserPrincipalName    = $upn
        GivenName            = $gName
        Surname              = $sName
        DisplayName          = $disp
        Enabled              = $false
        Path                 = $targetOU
        AccountPassword      = (ConvertTo-SecureString (New-RandomPassword -Length $PasswordLength) -AsPlainText -Force)
        PasswordNeverExpires = $false
        PassThru             = $true
    }

    $adUser = $null
    $created = $false
    for ($attempt = 1; $attempt -le $MaxCreateRetries; $attempt++) {
        try {
            Log ("Creating AD user: " + $disp + " (sAM: " + $sam + ") attempt " + $attempt)
            $adUser = New-ADUser @newUserParams -ErrorAction Stop

            if ($EnableAccount) {
                Enable-ADAccount -Identity $adUser -ErrorAction Stop
                if ($ChangePasswordAtNextLogon) {
                    try { Set-ADUser -Identity $adUser -ChangePasswordAtLogon $true -ErrorAction SilentlyContinue } catch {}
                }
            }
            $created = $true
            break
        } catch {
            Log ("Error creating AD user attempt " + $attempt + ": " + ($_ | Out-String)) "ERROR"
            Start-Sleep -Seconds 5
        }
    }
    if (-not $created) { Log "Failed to create user after retries."; return $false }

    # --------- Copy attributes from template (post-creation) ----------
    # General tab
    $description = if ($jobTitle) { $jobTitle } else { $null }  #Description = Job Title
    $officeName  = if ($office) { $office } else { $templateUser.physicalDeliveryOfficeName }

    # Organization tab values (prefer template, but keep payload job title)
    $titleVal      = if ($jobTitle) { $jobTitle } else { $templateUser.title }
    $deptVal       = $templateUser.department
    $companyVal    = $templateUser.company
    $managerDn     = $templateUser.Manager  # DN if set

    # Address tab
    $street   = $templateUser.streetAddress
    $city     = $templateUser.l
    $state    = $templateUser.st
    $zip      = $templateUser.postalCode
    $country  = $templateUser.co

    # Telephones/Web
    $phone    = $templateUser.telephoneNumber
    $www      = $templateUser.wWWHomePage

   
    try {
        # Named params (title/department/company/manager)
        $named = @{
            Identity = $adUser
        }
        if ($titleVal)   { $named['Title']      = $titleVal }
        if ($deptVal)    { $named['Department'] = $deptVal }
        if ($companyVal) { $named['Company']    = $companyVal }
        if ($managerDn)  { $named['Manager']    = $managerDn }

        if ($named.Keys.Count -gt 1) { Set-ADUser @named -ErrorAction SilentlyContinue }

        # LDAP replace block (General, Address, contact, mail/web)
        $replace = @{}
        if ($description)  { $replace['description']                = $description }
        if ($officeName)   { $replace['physicalDeliveryOfficeName'] = $officeName }
        if ($phone)        { $replace['telephoneNumber']            = $phone }
        if ($street)       { $replace['streetAddress']              = $street }
        if ($city)         { $replace['l']                          = $city }
        if ($state)        { $replace['st']                         = $state }
        if ($zip)          { $replace['postalCode']                 = $zip }
        if ($country)      { $replace['co']                         = $country }
        if ($www)          { $replace['wWWHomePage']                = $www }

        # Always set mail to UPN 
        $replace['mail'] = $upn

        if ($replace.Keys.Count -gt 0) {
            Set-ADUser -Identity $adUser -Replace $replace -ErrorAction SilentlyContinue
        }
    } catch {
        Log ("Post-create Set-ADUser failed: " + ($_ | Out-String)) "WARN"
    }

    Log ("Created AD user: " + $upn)

    # --------- Groups ----------
    $groupsToAdd = @()
    if ($memberOf) {
        if ($memberOf -is [System.Array]) { $groupsToAdd = $memberOf }
        else {
            $groupsToAdd = ($memberOf -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
    } else {
        try {
            $groupsToAdd = Get-ADPrincipalGroupMembership -Identity $templateUser -ErrorAction Stop |
                           Select-Object -ExpandProperty Name
        } catch {
            Log ("Could not read template groups: " + ($_ | Out-String)) "WARN"
        }
    }

    foreach ($g in $groupsToAdd) {
        if (-not $g) { continue }
        $added = $false
        for ($ga = 1; $ga -le $MaxAddGroupRetries; $ga++) {
            try {
                $adGroup = Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue
                if (-not $adGroup) { Log ("Group '" + $g + "' not found; skipping.") "WARN"; break }
                Add-ADGroupMember -Identity $adGroup -Members $adUser -ErrorAction Stop
                Log ("Added " + $upn + " to on-prem group '" + $g + "'")
                $added = $true
                break
            } catch {
                Log ("Attempt " + $ga + ": Failed to add " + $upn + " to group '" + $g + "': " + ($_ | Out-String)) "WARN"
                Start-Sleep -Seconds 3
            }
        }
        if (-not $added) { Log ("Failed to add " + $upn + " to group '" + $g + "' after retries.") "ERROR" }
    }

    # CSV
    try { Append-NewHireCsv -Upn $upn -JobTitle (if ($jobTitle) { $jobTitle } else { "UNKNOWN" }) } catch {}

    return $true
}

# ------------------- MAIN RECEIVE/DRAIN LOOP (single run) --------------------
try {
    Log ("Starting poll of SQS: " + $SqsQueueUrl)

    try {
        $attrs = Get-SQSQueueAttribute -QueueUrl $SqsQueueUrl `
            -AttributeName ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible `
            -Region $AwsRegion
        Log ("Queue approx visible: " + $attrs.ApproximateNumberOfMessages + "; in-flight: " + $attrs.ApproximateNumberOfMessagesNotVisible)
    } catch {
        Log ("Failed to read queue attributes: " + ($_ | Out-String)) "WARN"
    }

    $receiveParams = @{
        QueueUrl            = $SqsQueueUrl
        MaxNumberOfMessages = $MaxPerReceive
        WaitTimeSeconds     = $WaitTimeSeconds
        VisibilityTimeout   = $VisibilitySec
    }

    while ($true) {
        # AWS.Tools.SQS returns an array of Message objects
        $msgs = Receive-SQSMessage @receiveParams -Region $AwsRegion

        if (-not $msgs) {
            Log "No messages received."
            break
        }

        foreach ($m in $msgs) {
            try {
                Log ("Received SQS message Id: " + $m.MessageId + " Size: " + $m.Body.Length)
                $payloadObj = $m.Body | ConvertFrom-Json
                $payload = @{}
                $payloadObj.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }

                $ok = Process-Message -Payload $payload
                if ($ok) {
                    Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $m.ReceiptHandle -Region $AwsRegion -ErrorAction Stop
                    Log ("Deleted SQS message Id: " + $m.MessageId)
                } else {
                    Log ("Processing failed; leaving message " + $m.MessageId + " for retry.") "WARN"
                }
            } catch {
                Log ("Error processing message " + $m.MessageId + ": " + ($_ | Out-String)) "ERROR"
                
            }
        }

        Start-Sleep -Seconds $SleepBetweenDrainsSec
    }
} catch {
    Log ("Unhandled error in poller main: " + ($_ | Out-String)) "ERROR"
}

Log "Poller run complete."
