<#####################
assigning cloud-only groups to new hires after successful AD connect sync
prereqs:
 - azureAD module installed (Install-Module -Name AzureAD) OR Microsoft.Graph modules (adjust commands if using Graph)
 - run Connect-AzureAD (or Connect-MgGraph) prior to executing, or run this script as a scheduled task using a service account with consented permissions
 - files:
    C:\Onboarding\PostSync\CloudGroups.csv   (TemplateTitle,CloudGroups) -- cloud groups per user 
    C:\Onboarding\PostSync\NewHires.csv      (UserPrincipalName,JobTitle) -- upn + job title 
 - this script will create backups of NewHires.csv before modifying
#####################>

#region configuration
# Paths - adjust to suit your environment
$BasePath        = "C:\Onboarding\PostSync"
$MappingFile     = Join-Path $BasePath "CloudGroups.csv"
$NewUsersFile    = Join-Path $BasePath "NewHires.csv"
$LogFile         = "C:\Onboarding\Logs\PostSync.log"

# Behavior tuning
# how many times to wait for the synced user to appear
$MaxUserLookupRetries = 6   

# seconds between retries
$UserLookupDelaySec    = 30      

# retry adding to group on intermittent failures
$MaxAddGroupRetries    = 2   

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# Ensure directories exist
if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }
if (-not (Test-Path $BasePath)) { Log "ERROR: Base path $BasePath does not exist." "ERROR"; exit 1 }

# Backup NewHires.csv before changing
if (Test-Path $NewUsersFile) {
    try {
        $backupFile = Join-Path $BasePath ("NewHires_backup_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        Copy-Item -Path $NewUsersFile -Destination $backupFile -Force
        Log "Backed up NewHires.csv to $backupFile"
    } catch {
        Log "Failed to backup NewHires.csv: $_" "ERROR"
        exit 1
    }
} else {
    Log "No NewHires.csv found at $NewUsersFile — nothing to do." "INFO"
    exit 0
}

# Import CSVs
try {
    $mapping = Import-Csv -Path $MappingFile -ErrorAction Stop
} catch {
    Log "Failed to read mapping file $MappingFile: $_" "ERROR"
    exit 1
}

try {
    $newUsers = Import-Csv -Path $NewUsersFile -ErrorAction Stop
} catch {
    Log "Failed to read NewHires file $NewUsersFile: $_" "ERROR"
    exit 1
}

# connect to azure AD if not connected (attempt)
try {
    if (-not (Get-Module -ListAvailable -Name AzureAD)) {
        Log "AzureAD module not present. Please install the AzureAD module (Install-Module AzureAD) or run with Graph module and update script." "WARN"
    }
    # if session not connected, try to connect interactively
    $connected = $false
    try {
        $me = Get-AzureADUser -Top 1 -ErrorAction Stop
        $connected = $true
    } catch {
        Log "Not currently connected to AzureAD. Attempting Connect-AzureAD (interactive)." "INFO"
        try {
            Connect-AzureAD -ErrorAction Stop
            $connected = $true
            Log "Connected to AzureAD."
        } catch {
            Log "Failed to connect to AzureAD: $_" "ERROR"
            exit 1
        }
    }
} catch {
    Log "Azure AD connectivity check failed: $_" "ERROR"
    exit 1
}

# process each new user
foreach ($user in $newUsers) {
    $upn = $user.UserPrincipalName.Trim()
    $jobTitle = $user.JobTitle.Trim()
    if (-not $upn) {
        Log "Skipping row with empty UserPrincipalName." "WARN"
        continue
    }
    Log "Processing $upn (Template: $jobTitle)"

    # find template groups from mapping
    $templateRow = $mapping | Where-Object { $_.TemplateTitle -eq $jobTitle } | Select-Object -First 1
    if (-not $templateRow) {
        Log "No mapping found for template '$jobTitle'. Skipping $upn." "WARN"
        # optionally remove or move to a 'failed' CSV 
        continue
    }
    $groupListRaw = $templateRow.CloudGroups
    $groupNames = @()
    if ($groupListRaw) {
        $groupNames = $groupListRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }

    # resolve the user's Azure AD object id (with retries)
    $userObj = $null
    for ($attempt = 1; $attempt -le $MaxUserLookupRetries; $attempt++) {
        try {
            # use exact filter by UPN
            $userObj = Get-AzureADUser -Filter "UserPrincipalName eq '$upn'" -ErrorAction Stop
        } catch {
            # fallback to SearchString
            try {
                $userObj = Get-AzureADUser -SearchString $upn -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $upn } | Select-Object -First 1
            } catch {
                $userObj = $null
            }
        }

        if ($userObj) {
            break
        } else {
            Log "User $upn not found in Azure AD yet. Attempt $attempt/$MaxUserLookupRetries. Waiting $UserLookupDelaySec sec."
            Start-Sleep -Seconds $UserLookupDelaySec
        }
    }

    if (-not $userObj) {
        Log "User $upn still not found after $MaxUserLookupRetries attempts. Will skip for now; it stays in NewHires.csv." "WARN"
        continue
    }

    $userObjectId = $userObj.ObjectId
    Log "Resolved $upn to ObjectId $userObjectId"

    # for each cloud group, resolve and add membership
    foreach ($groupName in $groupNames) {
        if (-not $groupName) { continue }
        Log "Processing group '$groupName' for $upn"

        # resolve group object
        try {
            # try exact match using filter
            $groupObj = $null
            try {
                $groupObj = Get-AzureADGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
            } catch {
                # fallback to search
                $groupObj = Get-AzureADGroup -SearchString $groupName -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $groupName } | Select-Object -First 1
            }

            if (-not $groupObj) {
                Log "Group '$groupName' not found in Azure AD. Skipping group for $upn." "WARN"
                continue
            }
            $groupId = $groupObj.ObjectId
        } catch {
            Log "Error resolving group '$groupName': $_" "ERROR"
            continue
        }

        # attempt to add user to group with a couple retries if transient error
        $added = $false
        for ($gAttempt = 1; $gAttempt -le $MaxAddGroupRetries; $gAttempt++) {
            try {
                # note: Add-AzureADGroupMember will throw if already a member
                Add-AzureADGroupMember -ObjectId $groupId -RefObjectId $userObjectId -ErrorAction Stop
                Log "Added $upn to group $groupName (ObjectId: $groupId)"
                $added = $true
                break
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "One or more added object references already exist") {
                    Log "$upn is already a member of $groupName. Skipping." "INFO"
                    $added = $true
                    break
                } else {
                    Log "Attempt $gAttempt: Failed to add $upn to $groupName: $errMsg" "WARN"
                    Start-Sleep -Seconds 5
                }
            }
        }

        if (-not $added) {
            Log "Failed to add $upn to $groupName after $MaxAddGroupRetries attempts. Continuing to next group." "ERROR"
        }
    }

    # if we reached here we consider the user processed (even if some group adds failed)
    try {
        # reload current newUsers (in-memory) and remove this user, then write back file
        $allUsersOnDisk = Import-Csv -Path $NewUsersFile
        $remaining = $allUsersOnDisk | Where-Object { $_.UserPrincipalName -ne $upn }
        $remaining | Export-Csv -Path $NewUsersFile -NoTypeInformation
        Log "Processed $upn and removed from NewHires.csv"
        # Update in-memory collection so we don't re-process in same run
        $newUsers = $newUsers | Where-Object { $_.UserPrincipalName -ne $upn }
    } catch {
        Log "ERROR removing $upn from NewHires.csv: $_" "ERROR"
        
    }
}

Log "PostSync run completed."
