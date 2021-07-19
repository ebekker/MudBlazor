
[CmdletBinding()]
param (
    $Out=$PWD #"$PWD/../src/MudBlazor/Icons/Material"
)

## Based on:
##    * https://github.com/google/material-design-icons/issues/241#issuecomment-783804620
##    * https://fonts.google.com/icons
##      (look at the network resources being pulled)
$iconsMetaUrl = 'https://fonts.google.com/metadata/icons'
$iconsHost = 'fonts.gstatic.com'
$iconsPath = '/s/i/{family}/{icon}/v{version}/{asset}'

$iconsMetaJson = Invoke-RestMethod $iconsMetaUrl

## Record for posterity
Set-Content "$PWD/icons-metadata.json" $iconsMetaJson

## Some weirdness, the meta data is JSON with a prefix of `)]}'\n`
$iconsMetaJson = $iconsMetaJson.Substring(5)
$iconsMeta = ConvertFrom-Json -AsHashtable $iconsMetaJson


## Confirm some assumptions
if ($iconsHost -ne $iconsMeta.host) {
    Write-Error "Icons host [$($iconsMeta.host)] is not expected [$iconsHost]"
    exit
}
if ($iconsPath -ne $iconsMeta.asset_url_pattern) {
    Write-Error "Icons path [$($iconsMeta.asset_url_pattern)] is not expected [$iconsPath]"
    exit
}

## We'll generate a grouping of icons for each family, these are the ones we currently expect
$familyMap = @{
    Filled   = 'materialicons'
    Outlined = 'materialiconsoutlined'
    Rounded  = 'materialiconsround'
    Sharp    = 'materialiconssharp'
    TwoTone  = 'materialiconstwotone'
}

## Keep track of icons we generate for
## comparison to previous ones later on
$nextIcons = @{}

## Sanity check the families we get with what we expect
$iconsFamilies = $iconsMeta.families | % { $_.ToLower().Replace(' ', '') }
if ($iconsFamilies.Count -ne $familyMap.Count) {
    Write-Warning "Unexpected family count $($iconsFamilies.Count) -ne $($familyMap.Count)"
}
foreach ($fam in $familyMap.GetEnumerator()) {
    $famName   = $fam.Key
    $famPath   = $fam.Value
    if ($famPath -notin $iconsFamilies) {
        Write-Error "Family [$($famName)] is missing from meta data [$($famPath)]"
        exit
    }

    ## All icons under this family will be recorded here
    $nextIcons[$famName] = @{}
}

## Split the names on spaces and underscores
## to convert from snake-case to Pascal-case
$varSplitters = " _".ToCharArray()
$familyCount = 0
$allStartTime = [datetime]::Now

## We run each family in parallel to speed up the whole process
$familyMap.GetEnumerator() | ForEach-Object -ThrottleLimit 5 -Parallel {
    $fam = $_
    $famName   = $fam.Key
    $famPath   = $fam.Value
    $csFile    = "$PWD/$famName.cs"
    $iconCount = 0
    $startTime = [datetime]::Now

    $iconsMetaUrl   = $using:iconsMetaUrl
    $iconsHost      = $using:iconsHost
    $iconsPath      = $using:iconsPath
    $varSplitters   = $using:varSplitters
    $iconsMeta      = $using:iconsMeta

    ## Define the start and end of each CS file

    ## The START includes USINGs, NAMESPACE decl and CLASS decl
    $csFilePrologue = { @"
/*
 * This file was auto-generated by Update-MudIcons.ps1
 * $([datetime]::Now.ToString('yyyy/MM/dd_hh:mm:ss'))
 */

using System.Diagnostics.CodeAnalysis;

namespace MudBlazor
{
    [ExcludeFromCodeCoverage]
    public class $($famName)
    {

"@.Replace("`r`n", "`n") }

    ## The END just closes up braces for now
    $csFileEpilogue = { @"
    }
}

"@.Replace("`r`n", "`n") }

    ## Pull into scope
    $nextIcons = $using:nextIcons

    Write-Host "Generating icon family [$famName] to [$csFile]"
    Set-Content -Encoding utf8BOM $csFile $csFilePrologue.Invoke() -NoNewline

    ## Unfortunately, parallelizing this loop doesn't speed things up because
    ## there is more coordination and synchronization that has to take place
    ## (preserving order of generated icons in the file, synchronizing writes
    ## to the same file, etc.) so the overhead actually doubles the total time
    foreach ($icon in $iconsMeta.icons.GetEnumerator()) {
        $iconName = $icon.name
        $iconVers = $icon.version

        ## This should pull the SVG down as an XML document
        $iconUrl = "https://$iconsHost/s/i/$famPath/$iconName/v$iconVers/24px.svg"
        $iconSvg = Invoke-RestMethod $iconUrl

        ## Convert the name to a valid C# identifier
        $iconVar = $iconName.Trim()
        $iconVarParts = $iconVar.Split($varSplitters) | % { $_[0].ToString().ToUpper() + $_.Substring(1) }
        $iconVar = [string]::Join("", $iconVarParts)
        ## In case it doesn't start with a letter
        ## (i.e. number) prefix with an underscore
        if (![char]::IsLetter($iconVar[0])) {
            $iconVar = "_$iconVar"
        }

        ## Sanitize the SVG to conform to existing conventions
        $iconSvg = $iconSvg.DocumentElement.InnerXml
        $iconSvg = $iconSvg.Replace(' xmlns="http://www.w3.org/2000/svg"', '')
        $iconSvg = $iconSvg.Replace(' />', '/>')
        $iconSvg = $iconSvg.Replace("`"", "\`"")

        ## Keep track for comparison purposes
        $nextIcons[$famName][$iconVar] = $iconSvg

        Add-Content -Encoding utf8BOM $csFile -NoNewline @"
        public string $iconVar { get; } = "$($iconSvg)";

"@.Replace("`r`n", "`n")
        $iconCount++


        ## For testing on smaller samples
        # if ($iconCount -ge 100) {
        #    break
        # }
    }

    Add-Content -Encoding utf8BOM $csFile $csFileEpilogue.Invoke() -NoNewline
    $totalTime = [datetime]::Now - $startTime
    Write-Host "  ...generated [$global:iconCount] icons for [$famName] in [$($totalTime.TotalSeconds)] seconds."
}

$allTotalTime = [datetime]::Now - $allStartTime
Write-Host "Generated [$familyCount] families of icons in [$($allTotalTime.TotalSeconds)] seconds."

## Again, for posterity
Set-Content "$PWD/next-icons.json" (ConvertTo-Json $nextIcons)

## For reference, we'll compare to previous snapshot of icons
$prevIconsFile = "$PWD/prev-icons.json"
if (Test-Path $prevIconsFile) {
    $prevIconsJson = Get-Content -Raw $prevIconsFile
    $prevIcons = ConvertFrom-Json -AsHashtable $prevIconsJson

    $missingIcons = @{}
    Write-Host "Comparing OLD to NEW"
    foreach ($famName in $prevIcons.Keys) {
        $prevFamIcons = $prevIcons[$famName]
        $nextFamIcons = $nextIcons[$famName]
        $missingIcons[$famName] = [System.Collections.Generic.List[string]]::new()
        if (!$nextFamIcons) {
            Write-Warning "Missing Icon Family [$famName]"
            continue
        }

        foreach ($iconVar in $prevFamIcons.Keys) {
            if (!$nextFamIcons[$iconVar]) {
                $missingIcons[$famName].Add($iconVar)
            }
        }

        if ($missingIcons[$famName].Count) {
            Write-Warning "Found [$($missingIcons[$famName].Count)] missing icons in [$famName]"
        }
    }

    Set-Content "$PWD/prev-icons-missing.json" (ConvertTo-Json $missingIcons)
}
