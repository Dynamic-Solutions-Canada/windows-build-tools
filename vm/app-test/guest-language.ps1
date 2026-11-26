<#
.SYNOPSIS
Switch the test guest's user to another Windows language as a set, or back to en-US.

.DESCRIPTION
Sets, for the signed-in user, together:
  - the display language (Windows' own text: Start, taskbar, Explorer, Settings, dialogs);
  - the input language and its one keyboard (the user's language list holds only this language);
  - the home location (the country or region);
  - the regional format (dates, times, numbers and the culture apps read).
`-Language en-US` restores the guest's usual settings. The language's pack must be installed first
(Install-Language, see the README); the script refuses a language that is not.

Windows applies the display language at the next sign-in, so cold-cycle the guest after this (on the
home server, vm/remote.sh down then up: about 80 s to the new desktop). Run it over SSH (app_test_ps,
or app_test_language on the host, which does both); it changes per-user settings, and SSH signs in as
the same user as the desktop session. Leaves the system locale, the welcome screen and the time zone
alone.

Keyboards: a language whose default keyboard is an input method editor (IME), such as ja-JP and
zh-CN, gets a plain keyboard layout instead (see $PlainKeyboards). An IME turns typed text into
composition that waits for confirmation, so automated typing would be held or converted, and it shows
an input-mode indicator ("A" or a character) in the taskbar's notification area, which would appear
in every Store capture. With one language and one plain keyboard, Windows shows no input indicator.
Pass -Keyboard to choose another input method tip ("<language id>:<layout>", as Get-WinUserLanguageList
shows them).

Run with -Show to print the current settings without changing anything.

.PARAMETER Language A language tag whose pack is installed: en-US, de-DE, es-ES, fr-FR, ja-JP, pt-BR
or zh-CN.
.PARAMETER Keyboard An input method tip to use instead of the default for the language.
.PARAMETER Show Print the current display language, language list, home location and format.
#>
param(
    [string]$Language,
    [string]$Keyboard,
    [switch]$Show
)
$ErrorActionPreference = 'Stop'

# Home location (GeoId) for each listing language: the country whose format and Store the listing serves.
$HomeLocations = @{
    'en-US' = 244   # United States
    'de-DE' = 94    # Germany
    'es-ES' = 217   # Spain
    'fr-FR' = 84    # France
    'ja-JP' = 122   # Japan
    'pt-BR' = 32    # Brazil
    'zh-CN' = 45    # China
}

# Plain keyboard layouts for languages whose default keyboard is an IME (see the description):
# Japanese with the Japanese keyboard layout and no IME, and Chinese (Simplified) with the US layout.
$PlainKeyboards = @{
    'ja-JP' = '0411:00000411'
    'zh-CN' = '0804:00000409'
}

<#
The tags of the installed language packs. Get-InstalledLanguage writes its whole list as one object,
which a pipeline does not unroll, so the tags are read through member access.
#>
function Get-InstalledLanguageIds {
    (Get-InstalledLanguage).LanguageId
}

<# Print the user's current language settings. #>
function Show-LanguageSettings {
    $override = Get-WinUILanguageOverride
    [pscustomobject]@{
        DisplayLanguage = if ($override) { $override.Name } else { '(not overridden)' }
        Languages       = (Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag) [$($_.InputMethodTips -join ', ')]" }) -join '; '
        HomeLocation    = "$((Get-WinHomeLocation).GeoId) $((Get-WinHomeLocation).HomeLocation)"
        Format          = (Get-Culture).Name
        Installed       = (Get-InstalledLanguageIds) -join ' '
    } | Format-List | Out-String -Width 200
}

if ($Show) {
    Show-LanguageSettings
    return
}
if (-not $Language) { throw 'Pass -Language <tag> (en-US to restore), or -Show' }
if (-not $HomeLocations.ContainsKey($Language)) {
    throw "No home location is set up for $Language; add it to `$HomeLocations ($($HomeLocations.Keys -join ', '))"
}
$installed = @(Get-InstalledLanguageIds)
if ($installed -notcontains $Language) {
    throw "The $Language language pack is not installed (installed: $($installed -join ', ')); install it first: Install-Language $Language -ExcludeFeatures"
}

# The language list: this language alone, with one keyboard, so no input indicator shows.
$list = New-WinUserLanguageList $Language
$tip = if ($Keyboard) { $Keyboard } elseif ($PlainKeyboards.ContainsKey($Language)) { $PlainKeyboards[$Language] } else { $null }
if ($tip) {
    $list[0].InputMethodTips.Clear()
    $list[0].InputMethodTips.Add($tip)
}
Set-WinUserLanguageList $list -Force

# The display language, set explicitly even for en-US: clearing the override with $null fails
# ("Object reference not set to an instance of an object").
Set-WinUILanguageOverride -Language $Language
Set-WinDefaultInputMethodOverride -InputTip $list[0].InputMethodTips[0]
Set-WinHomeLocation -GeoId $HomeLocations[$Language]
Set-Culture $Language

Write-Output "switched to $Language; it applies at the next sign-in (cold-cycle the guest)"
Show-LanguageSettings
