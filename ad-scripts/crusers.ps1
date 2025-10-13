# Domain Controller
$DC = ""

# Correct nested OU path for the second location ;)
$OU = "LDAP://$DC/OU="

# Connect to the OU
$Directory = [ADSI]$OU

# Prepare output array
$Output = @()

# LDAP search for users
$Searcher = New-Object System.DirectoryServices.DirectorySearcher($Directory)
$Searcher.Filter = "(objectCategory=person)"
$Searcher.PropertiesToLoad.Add("title") | Out-Null
$Searcher.PropertiesToLoad.Add("mail") | Out-Null
$Searcher.PropertiesToLoad.Add("memberOf") | Out-Null

$Results = $Searcher.FindAll()

foreach ($Result in $Results) {
    $User = $Result.Properties

    # Get group CNs
    $Groups = @()
    if ($User.memberof) {
        foreach ($GroupDN in $User.memberof) {
            if ($GroupDN -match "^CN=([^,]+),") {
                $Groups += $matches[1]
            }
        }
    }

    $Output += [PSCustomObject]@{
        TemplateTitle     = if ($User.title) { $User.title[0] } else { "" }
        OnPremTemplateId  = if ($User.mail) { ($User.mail[0] -split "@")[0] } else { "" }
        CloudTemplateUPN  = if ($User.mail) { $User.mail[0] } else { "" }
        OnPremGroups      = $Groups -join ","
    }
}

# Sort output alphabetically by job title
$Output = $Output | Sort-Object TemplateTitle

# Export CSV to Downloads
$CsvPath = "$env:USERPROFILE\Downloads\AD_CRUsers.csv"
$Output | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

Write-Host "CSV exported to $CsvPath"
