<#
AD Onboarding Poller Script - Hardened Version
- Polls SQS for onboarding messages
- Creates on-prem AD users by cloning a template
- Adds users to on-prem groups
- Appends new hires to NewHires.csv for post-sync cloud group processing

Prereqs:
- EC2 is domain joined, running account can create AD users and modify groups
- AWS.Tools.SQS module installed, instance profile / credentials present
- ActiveDirectory PowerShell module (RSAT) available
#>

#region Configuration
$SqsQueueUrl = "https://sqs.us-east-1.........."  # Replace with your SQS queue

# Paths
$BasePath       = "C:\Onboarding"
$NewUsersFile   = Join-Path $BasePath "PostSync\NewHires.csv"
$LogFile        = Join-Path $BasePath "Logs\Poller.log"

# AD defaults
$OUPath         = "OU=Users,DC=company,DC=com"
$PasswordLength = 16
$EnableAccount  = $true
$ChangePasswordAtNextLogon = $true

# poll behavior
$MaxMessagesPerPoll = 5
$WaitTimeSeconds    = 10
$VisibilityTimeout  = 300

# retry tuning
$MaxCreateRetries = 2
$MaxUserLookupRetries = 6
$UserLookupDelaySec = 30
$MaxAddGroupRetries = 2
#endregion

function Log {
    param([string]$Message, [string]$Level="INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# Ensure directories exist
if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }
if (-not (Test-Path (Split-Path $NewUsersFile))) { New-Item -ItemType Directory -Path (Split-Path $NewUsersFile) -Force | Out-Null }

# Import modules
try { Import-Module ActiveDirectory -ErrorAction Stop } catch { Log "ActiveDirectory module not available: $_" "ERROR"; throw }
try { Import-Module AWS.Tools.SQS -ErrorAction Stop } catch { Log "AWS.Tools.SQS module not available: $_" "ERROR"; throw }

# Generate secure random password
function New-RandomPassword {
    param([int]$Length = 16)
    Add-Type -AssemblyName System.Web
    return [System.Web.Security.Membership]::GeneratePassword($Length, 4)
}

# Append new hire to CSV
function Append-NewHireCsv {
    param($Upn, $JobTitle)
    $record = [PSCustomObject]@{
        UserPrincipalName = $Upn
        JobTitle = $JobTitle
    }
    if (-not (Test-Path $NewUsersFile)) {
        $record | Export-Csv -Path $NewUsersFile -NoTypeInformation
    } else {
        $record | Export-Csv -Path $NewUsersFile -NoTypeInformation -Append
    }
    Log "Appended $Upn,$JobTitle to NewHires.csv"
}

# --- Main Polling Loop ---
try {
    Log "Starting poll of SQS: $SqsQueueUrl"
    $receiveParams = @{
        QueueUrl = $SqsQueueUrl
        MaxNumberOfMessage = $MaxMessagesPerPoll
        WaitTimeSeconds = $WaitTimeSeconds
        VisibilityTimeout = $VisibilityTimeout
    }

    $resp = Receive-SQSMessage @receiveParams
    if (-not $resp.Messages) { Log "No messages received." } else {

        foreach ($msg in $resp.Messages) {
            $receipt = $msg.ReceiptHandle
            $body = $msg.Body
            Log "Received SQS message Id: $($msg.MessageId)"

            # Parse JSON payload
            try { $payload = $body | ConvertFrom-Json } catch {
                Log "ERROR parsing message JSON: $_" "ERROR"
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt -ErrorAction SilentlyContinue
                continue
            }

            $reqId = $payload.requestId
            $templateOnPremId = $payload.templateUserId
            $memberOf = $payload.memberOf
            $upn = $payload.userPrincipalName
            $givenName = $payload.givenName
            $sn = $payload.sn
            $displayName = $payload.displayName

            if (-not $templateOnPremId) {
                Log "Message $($msg.MessageId) missing templateUserId; skipping." "WARN"
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt -ErrorAction SilentlyContinue
                continue
            }

            # Check if user already exists
            $existingUser = $null
            if ($upn) {
                try { $existingUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue } catch { $existingUser = $null }
            }

            if ($existingUser) {
                Log "User $upn already exists. Appending to NewHires.csv and deleting message."
                Append-NewHireCsv -Upn $upn -JobTitle ($payload.positionTemplate -or $payload.title -or "UNKNOWN")
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt -ErrorAction SilentlyContinue
                continue
            }

            # Resolve template user
            $templateUser = $null
            try {
                if ($templateOnPremId -match '^[0-9a-fA-F\-]{36}$') { $templateUser = Get-ADUser -Identity $templateOnPremId -Properties * -ErrorAction SilentlyContinue }
                if (-not $templateUser) { $templateUser = Get-ADUser -Filter "SamAccountName -eq '$templateOnPremId'" -Properties * -ErrorAction SilentlyContinue }
                if (-not $templateUser) { $templateUser = Get-ADUser -Filter "UserPrincipalName -eq '$templateOnPremId'" -Properties * -ErrorAction SilentlyContinue }
                if (-not $templateUser) { $templateUser = Get-ADUser -Identity $templateOnPremId -Properties * -ErrorAction SilentlyContinue }
            } catch { Log "Error fetching template user: $_" "ERROR" }

            if (-not $templateUser) {
                Log "Template user $templateOnPremId not found. Skipping message." "ERROR"
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt -ErrorAction SilentlyContinue
                continue
            }

            # Clone attributes from template
            $newUserProps = @{}
            $attrsToClone = @('department','company','physicalDeliveryOfficeName','telephoneNumber','streetAddress','l','st','postalCode','co','employeeID','manager')
            foreach ($a in $attrsToClone) { if ($templateUser.$a) { $newUserProps[$a] = $templateUser.$a } }

            # Apply overrides from payload
            if ($givenName) { $newUserProps['GivenName'] = $givenName }
            if ($sn) { $newUserProps['Surname'] = $sn }
            if ($displayName) { $newUserProps['DisplayName'] = $displayName }
            if ($upn) { $newUserProps['UserPrincipalName'] = $upn }

            # --- Generate sAMAccountName from UPN ---
            $sam = ($upn -split '@')[0]
            Log "Using sAMAccountName: $sam"
            # Ensure uniqueness
            if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                $i = 1
                $originalSam = $sam
                while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                    $sam = "$originalSam$i"
                    $i++
                    if ($i -gt 100) { Log "ERROR: Too many duplicates for $originalSam. Aborting user creation." "ERROR"; continue 2 }
                }
                Log "Adjusted sAMAccountName to: $sam"
            }

            # --- Extract OU from template ---
            try {
                $dn = $templateUser.DistinguishedName
                $ouStart = $dn.IndexOf("OU=")
                if ($ouStart -ge 0) { $targetOUPath = $dn.Substring($ouStart) } else { $targetOUPath = $OUPath; Log "Falling back to default OU path" "WARN" }
            } catch { $targetOUPath = $OUPath; Log "Failed to extract OU from template. Using default: $OUPath" "WARN" }

            # Prepare New-ADUser parameters
            $newUserParams = @{
                Name = $newUserProps['DisplayName'] ?: ($givenName + " " + $sn)
                SamAccountName = $sam
                UserPrincipalName = $newUserProps['UserPrincipalName'] ?: ($sam + "@company.com")
                GivenName = $newUserProps['GivenName']
                Surname = $newUserProps['Surname']
                DisplayName = $newUserProps['DisplayName']
                Enabled = $false
                Path = $targetOUPath
                AccountPassword = (ConvertTo-SecureString (New-RandomPassword -Length $PasswordLength) -AsPlainText -Force)
                PasswordNeverExpires = $false
            }

            foreach ($k in $newUserProps.Keys) { if ($k -notin @('GivenName','Surname','DisplayName','UserPrincipalName')) { $newUserParams[$k] = $newUserProps[$k] } }

            # --- Create user with retries ---
            $created = $false
            for ($attempt=1; $attempt -le $MaxCreateRetries; $attempt++) {
                try {
                    Log "Creating AD user: $($newUserParams.Name) (sAM: $($newUserParams.SamAccountName)) attempt $attempt"
                    $adUser = New-ADUser @newUserParams -ErrorAction Stop
                    if ($EnableAccount) { Enable-ADAccount -Identity $adUser; if ($ChangePasswordAtNextLogon) { Set-ADUser -Identity $adUser -ChangePasswordAtLogon $true } }
                    $created = $true
                    Log "Created AD user: $($newUserParams.UserPrincipalName)"
                    break
                } catch { Log "Error creating AD user attempt $attempt: $_" "ERROR"; Start-Sleep -Seconds 5 }
            }
            if (-not $created) { Log "Failed to create user after $MaxCreateRetries attempts." "ERROR"; continue }

            # --- Add user to on-prem groups ---
            $groupsToAdd = @()
            if ($memberOf) { $groupsToAdd = if ($memberOf -is [System.Array]) { $memberOf } else { ($memberOf -split ',') | ForEach-Object { $_.Trim() } } } 
            else { try { $groupsToAdd = Get-ADPrincipalGroupMembership -Identity $templateUser | Select-Object -ExpandProperty Name } catch { Log "Failed to enumerate template groups: $_" "WARN" } }

            foreach ($g in $groupsToAdd) {
                if (-not $g) { continue }
                try {
                    $adGroup = Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue
                    if ($adGroup) { Add-ADGroupMember -Identity $adGroup -Members $adUser -ErrorAction Stop; Log "Added $($newUserParams.UserPrincipalName) to group $g" } 
                    else { Log "Group $g not found in AD. Skipping." "WARN" }
                } catch { Log "Failed to add $($newUserParams.UserPrincipalName) to group $g: $_" "ERROR" }
            }

            # --- Append to NewHires.csv ---
            try { Append-NewHireCsv -Upn $newUserParams.UserPrincipalName -JobTitle ($payload.positionTemplate -or $payload.title -or $payload.position -or "UNKNOWN") } 
            catch { Log "Failed to append new hire to CSV: $_" "ERROR"; continue }

            # --- Remove message from SQS ---
            try { Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt; Log "Deleted SQS message Id: $($msg.MessageId)" } 
            catch { Log "Failed to delete SQS message $($msg.MessageId): $_" "WARN" }
        }
    }
} catch { Log "Unhandled error in poller main: $_" "ERROR" }

Log "Poller run complete."
