<#
polling SQS for onboarding messages -- create on-prem AD users by cloning a template and then add to on-prem groups,
and append new hires to NewHires.csv for post-sync cloud group processing

assumptions to be made prior to script run(if not do not run) -- 
 - EC2 is domain joined and runs with an account that can create AD users and modify groups
 - AWS.Tools.SQS module is installed and instance profile / credentials are present
 - ActiveDirectory PowerShell module is available (RSAT)
#>

#region Configuration
# SQS -- set queue url 
$SqsQueueUrl = "https://sqs.us-east-1.........." 

# Paths
$BasePath       = "C:\Onboarding"
$NewUsersFile   = Join-Path $BasePath "PostSync\NewHires.csv"  
$LogFile        = Join-Path $BasePath "Logs\Poller.log"

# AD defaults

# OU where new users will be created if not copying DN -- customize(change once i check ad)
$OUPath         = "OU=Users,DC=company,DC=com"   
$PasswordLength = 16
$EnableAccount  = $true
$ChangePasswordAtNextLogon = $true

# poll behavior
$MaxMessagesPerPoll = 5
$WaitTimeSeconds    = 10   

# seconds to process message before it becomes visible again
$VisibilityTimeout  = 300 

# retry tuning
$MaxCreateRetries = 2

function Log {
    param([string]$Message, [string]$Level="INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# ensure folders exist
if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }
if (-not (Test-Path (Split-Path $NewUsersFile))) { New-Item -ItemType Directory -Path (Split-Path $NewUsersFile) -Force | Out-Null }

# import modules
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Log "ERROR: ActiveDirectory module not available: $_" "ERROR"
    throw
}
try {
    Import-Module AWS.Tools.SQS -ErrorAction Stop
} catch {
    Log "ERROR: AWS.Tools.SQS module not available. Install-Module -Name AWS.Tools.SQS" "ERROR"
    throw
}

# password generation (may remove due to company requirements but may leave so we can reset anywho)
function New-RandomPassword {
    param([int]$Length = 16)
    
    # generating a complex password with upper/lower/digits/special
    $upper = 48..57 + 65..90 + 97..122 | Get-Random -Count 0  # placeholder
    Add-Type -AssemblyName System.Web
    $pw = [System.Web.Security.Membership]::GeneratePassword($Length, 4)
    return $pw
}

# helper that safely appends the new hire to CSV (creates file if missing)
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

# main polling loop — one run (call from scheduled task or wrap in while loop for continuous)
try {
    Log "Starting poll of SQS: $SqsQueueUrl"
    $receiveParams = @{
        QueueUrl         = $SqsQueueUrl
        MaxNumberOfMessage = $MaxMessagesPerPoll
        WaitTimeSeconds  = $WaitTimeSeconds
        VisibilityTimeout = $VisibilityTimeout
    }

    $resp = Receive-SQSMessage @receiveParams
    if (-not $resp.Messages) {
        Log "No messages received."
    } else {
        foreach ($msg in $resp.Messages) {
            $receipt = $msg.ReceiptHandle
            $body = $msg.Body
            Log "Received SQS message Id: $($msg.MessageId)"

            # parse the JSON body
            try {
                $payload = $body | ConvertFrom-Json
            } catch {
                Log "ERROR parsing message body JSON: $_" "ERROR"
                
                # delete bad message to avoid poison queue or move to DLQ in prod
                try { Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt } catch { Log "Failed delete bad message: $_" "ERROR" }
                continue
            }

            # basic required fields
            $reqId = $payload.requestId
            $templateOnPremId = $payload.templateUserId
            $memberOf = $payload.memberOf
            $upn = $payload.userPrincipalName
            $givenName = $payload.givenName
            $sn = $payload.sn
            $displayName = $payload.displayName

            if (-not $templateOnPremId) {
                Log "Message $($msg.MessageId) missing templateUserId; moving on." "WARN"
                
                # delete or move to DLQ — for now it will delete to avoid repeat
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt
                continue
            }

            # idempotency checks if a user already exists with this UPN or samAccountName
            $existingUser = $null
            if ($upn) {
                try {
                    $existingUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue
                } catch {
                    $existingUser = $null
                }
            }

            if ($existingUser) {
                Log "User with UPN $upn already exists (sAMAccountName: $($existingUser.sAMAccountName)). Deleting message."
                
                # appends to NewHires.csv if not present (safe guard)
                Append-NewHireCsv -Upn $upn -JobTitle ($payload.positionTemplate -or $payload.title -or "UNKNOWN")
                try { Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt } catch { Log "Failed delete message for existing user: $_" "WARN" }
                continue
            }

            # Fetch the template user from AD -- templateUserId expected to be DN or SAM or GUID(*** we can try multiple lookups here ***)
            $templateUser = $null
            try {
                # try GUID (objectGUID) if looks like GUID
                if ($templateOnPremId -match '^[0-9a-fA-F\-]{36}$') {
                    $templateUser = Get-ADUser -Identity $templateOnPremId -Properties * -ErrorAction SilentlyContinue
                }
                if (-not $templateUser) {
                    # try samAccountName
                    $templateUser = Get-ADUser -Filter "SamAccountName -eq '$templateOnPremId'" -Properties * -ErrorAction SilentlyContinue
                }
                if (-not $templateUser) {
                    # try userprincipalname
                    $templateUser = Get-ADUser -Filter "UserPrincipalName -eq '$templateOnPremId'" -Properties * -ErrorAction SilentlyContinue
                }
                if (-not $templateUser) {
                    # try distinguishedName
                    $templateUser = Get-ADUser -Identity $templateOnPremId -Properties * -ErrorAction SilentlyContinue
                }
            } catch {
                Log "Error fetching template user $templateOnPremId: $_" "ERROR"
            }

            if (-not $templateUser) {
                Log "Template user $templateOnPremId not found. Skipping message $($msg.MessageId)." "ERROR"
                
                # optionally move to DLQ; delete here to avoid endless retries
                try { Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt } catch { Log "Failed deleting message for missing template: $_" "ERROR" }
                continue
            }

            # build the object for new user by cloning the desired attributes from template and applying payload overrides
            $newUserProps = @{}
            # common attributes to clone - extend as needed
            $attrsToClone = @('department','company','physicalDeliveryOfficeName','telephoneNumber','streetAddress','l','st','postalCode','co','employeeID','manager')
            foreach ($a in $attrsToClone) {
                if ($templateUser.$a) { $newUserProps[$a] = $templateUser.$a }
            }

            # apply overrides from payload if present
            if ($givenName) { $newUserProps['GivenName'] = $givenName }
            if ($sn) { $newUserProps['Surname'] = $sn }
            if ($displayName) { $newUserProps['DisplayName'] = $displayName }
            if ($payload.mailNickname) { $mailNick = $payload.mailNickname } else {
                $mailNick = $payload.emailAlias -or ($givenName.Substring(0,1) + $sn) -replace '\s',''
            }
            if ($upn) { $newUserProps['UserPrincipalName'] = $upn }

            # samAccountName generation (simple): take mailNickname truncated to 20 chars; ensure uniqueness
            $sam = $mailNick
            if ($sam.Length -gt 20) { $sam = $sam.Substring(0,20) }
            # ensure not already used
            $i = 0
            while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                $i++; $sam = $mailNick + $i
                if ($sam.Length -gt 20) { $sam = $sam.Substring(0,20) }
            }

            # prep the New-ADUser parameters
            $newUserParams = @{
                Name = $newUserProps['DisplayName'] ?: ($givenName + " " + $sn)
                SamAccountName = $sam
                UserPrincipalName = $newUserProps['UserPrincipalName'] ?: ($sam + "@" + "company.com")
                GivenName = $newUserProps['GivenName']
                Surname = $newUserProps['Surname']
                DisplayName = $newUserProps['DisplayName']
                Enabled = $false  # enable after password set
                Path = $OUPath
                AccountPassword = (ConvertTo-SecureString (New-RandomPassword -Length $PasswordLength) -AsPlainText -Force)
                PasswordNeverExpires = $false
            }

            # add other optional attributes if present
            foreach ($k in $newUserProps.Keys) {
                if ($k -in @('GivenName','Surname','DisplayName','UserPrincipalName')) { continue }
                $newUserParams[$k] = $newUserProps[$k]
            }

            # attempt create user with retries
            $created = $false
            for ($attempt = 1; $attempt -le $MaxCreateRetries; $attempt++) {
                try {
                    Log "Attempting to create AD user: $($newUserParams.Name) (sAM: $($newUserParams.SamAccountName)) (UPN: $($newUserParams.UserPrincipalName)) attempt $attempt"
                    $adUser = New-ADUser @newUserParams -ErrorAction Stop
                    # enable account if configured
                    if ($EnableAccount) {
                        Enable-ADAccount -Identity $adUser -ErrorAction Stop
                        if ($ChangePasswordAtNextLogon) {
                            Set-ADUser -Identity $adUser -ChangePasswordAtLogon $true
                        }
                    }
                    $created = $true
                    Log "Created AD user: $($newUserParams.UserPrincipalName)"
                    break
                } catch {
                    Log "Error creating AD user attempt $attempt: $_" "ERROR"
                    Start-Sleep -Seconds 5
                }
            }

            if (-not $created) {
                Log "Failed to create user after $MaxCreateRetries attempts. Skipping and leaving message in queue for retry." "ERROR"
                continue  # do not delete the message so it can be retried
            }

            # add to on-prem groups from payload.memberOf (if present) or template groups
            $groupsToAdd = @()
            if ($memberOf) {
                # payload.memberOf expected to be array or comma-separated string
                if ($memberOf -is [System.Array]) { $groupsToAdd = $memberOf } else { $groupsToAdd = ($memberOf -split ',') | ForEach-Object { $_.Trim() } }
            } else {
                # optionally get group membership from template user in AD
                try {
                    $templateGroups = Get-ADPrincipalGroupMembership -Identity $templateUser | Select-Object -ExpandProperty Name
                    $groupsToAdd = $templateGroups
                } catch {
                    Log "Warning: failed to enumerate groups from template user: $_" "WARN"
                }
            }

            foreach ($g in $groupsToAdd) {
                if (-not $g) { continue }
                try {
                    # resolve AD group object by name, then Add-ADGroupMember
                    $adGroup = Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue
                    if (-not $adGroup) {
                        Log "Group $g not found in AD. Skipping."
                        continue
                    }
                    Add-ADGroupMember -Identity $adGroup -Members $adUser -ErrorAction Stop
                    Log "Added $($newUserParams.UserPrincipalName) to on-prem group $g"
                } catch {
                    Log "Failed to add $($newUserParams.UserPrincipalName) to group $g: $_" "ERROR"
                }
            }

            # append to NewHires.csv for post-sync processing (UPN, JobTitle)
            try {
                $jobTitle = $payload.positionTemplate -or $payload.title -or $payload.position -or "UNKNOWN"
                Append-NewHireCsv -Upn $newUserParams.UserPrincipalName -JobTitle $jobTitle
            } catch {
                Log "Failed to append new hire to CSV: $_" "ERROR"
                # don't delete SQS message; allow retry on next poll
                continue
            }

            try {
                Remove-SQSMessage -QueueUrl $SqsQueueUrl -ReceiptHandle $receipt
                Log "Deleted SQS message Id: $($msg.MessageId) after successful processing."
            } catch {
                Log "Warning: Failed to delete message $($msg.MessageId): $_" "WARN"
            }
        } # end foreach msg
    } # end else messages
} catch {
    Log "Unhandled error in poller main: $_" "ERROR"
}
Log "Poller run complete."
