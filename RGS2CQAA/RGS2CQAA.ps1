param(
    [Parameter(Mandatory= $true)]
    [string]
    $RGSExportPath,
    
    [Parameter(Mandatory= $true)]
    [string]
    $SipDomain,

    [bool]
    $GenerateAccountsOnline = $false,

    # OU for hybrid object creation
    [string]
    $ResourceOU,

    # Default Usage Location
    [string]
    $UsageLocation = "US"
)

# TODO: add lines for required modules
#       need: Get-AzureADUser
#       need: MicrosoftTeams
#       need: SfBServer if -not $GenerateAccountsOnline
# TODO: add session refresh scripts?

# TODO: Add switch for phone number assignment
# TODO: how to handle DR vs Service Number in addition to Hybrid vs Online accounts

$GeneratedScriptsPath = [IO.Path]::Combine($RGSExportPath, 'GeneratedScripts')
if (!(Test-Path -Path $GeneratedScriptsPath)) {
    New-Item -Path $GeneratedScriptsPath -ItemType Directory | Out-Null
}

$Files = Get-ChildItem -Path $RGSExportPath -Filter *.zip
$i = 0
$CreatedVariables = @()
foreach ($file in $Files.Name) {
    $Source = [IO.Path]::Combine($RGSExportPath, $File)
    $Destination = [IO.Path]::Combine($RGSExportPath, [IO.Path]::GetFileNameWithoutExtension($File))
    if (!(Test-Path -Path $Destination)) {
        Expand-Archive -Path $Source -DestinationPath $Destination -Force
    }

    $RgsFilesPath = [IO.Path]::Combine($Destination, "RgsImportExport")
    $RgsFiles = Get-ChildItem -Path $RgsFilesPath -Filter *.xml -File
    foreach ($RgsFile in $RgsFiles) {
        $FileName = $RgsFile.BaseName
        if ($CreatedVariables -notcontains $FileName) { $CreatedVariables += $FileName }
        $FileContent = Import-Clixml -Path $RgsFile.FullName
        if ($FileContent -isnot [Object[]]) {
            $FileContent = @($FileContent)
        }
        if ($i -eq 0 -and (Test-Path Variable:$FileName)) {
            Remove-Variable -Name $FileName -Force -ErrorAction SilentlyContinue
        }
        $CurrentValue = if ((Test-Path Variable:$FileName)) {
            Get-Variable -Name $FileName -ValueOnly -ErrorAction SilentlyContinue
        }
        New-Variable -Name $FileName -Value ($FileContent + $CurrentValue) -Force
    }
    $i++
}

function RoundValue {
    param (
        [int]$InputTime,
        [int]$MinimumTime = 30,
        [int]$RoundTo = 15,
        [int]$MaximumTime = 180
    )
    if ([string]::IsNullOrEmpty($InputTime) -or $InputTime -lt $MinimumTime) { 
        [int]$MinimumTime
    }
    else { 
        [int][Math]::Min(([Math]::Ceiling($InputTime / $RoundTo) * $RoundTo), $MaximumTime)
    }
}

function WriteDisconnectAction {
    param (
        [Text.StringBuilder]
        $CommandText,
        [string]
        $CommandHashName,
        [string]
        $ActionName,
        [switch]
        $AAMenuOption,
        [int]
        $NumTabs = 0
    )
    $Tabs = [string]::new("`t", $NumTabs)
    if ($AAMenuOption) {
        $CommandText.AppendLine("$Tabs`$$CommandHashName[`"Action`"] = `"DisconnectCall`"") | Out-Null
    }
    else {
        $CommandText.AppendLine("$Tabs`$$CommandHashName[`"$ActionName`"] = `"Disconnect`"") | Out-Null
    }
}

function ConvertNonQuestionAction {
    [cmdletbinding()]
    param (
        $FlowName,
        $URI,
        $Action,
        $QueueId,
        [Text.StringBuilder]
        $CommandText,
        [string]
        $CommandHashName,
        [string]
        $ActionName,
        [string]
        $ActionTargetName,
        [Parameter(ParameterSetName = "AA")]
        [switch]
        $AAMenuOption,
        [Parameter(ParameterSetName = "CQ")]
        [string]
        $AudioFilePromptLocation,
        [Parameter(ParameterSetName = "CQ")]
        [string]
        $AudioFilePromptOriginalName,
        [Parameter(ParameterSetName = "CQ")]
        [string]
        $TextPrompt,
        [Parameter(ParameterSetName = "CQ")]
        [string]
        $AudioPromptParamName,
        [Parameter(ParameterSetName = "CQ")]
        [string]
        $TextPromptParamName
    )
    <#
        AudioFilePromptLocation     = $DefaultQueue.OverflowAudioStoredLocation
        AudioFilePromptOriginalName = $DefaultQueue.OverflowAudioOriginalName
        TextPrompt                  = $DefaultQueue.OverflowTextPrompt
        AudioPromptParamName        = "OverflowSharedVoicemailAudioFilePrompt"
        TextPromptParamName         = "OverflowSharedVoicemailTextToSpeechPrompt"
    #>
    $WarningStrings = [Text.StringBuilder]::new()
    switch ($Action) {
        "Terminate" {
            WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption
        }
        "TransferToPstn" {
            if ([string]::IsNullOrEmpty($URI)) {
                WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption
            }
            else {
                $URI = [regex]::Replace($URI, '[Xx]', '')
                $URI = [regex]::Replace($URI, ';[Ee][Tt]=', 'x')
                $URI = 'tel:+' + [regex]::Replace($URI, '[^0-9x]', '')
                $URI = [regex]::Replace($URI, 'x', ';ext=')
                if ($AAMenuOption) {
                    $CommandText.AppendLine("`$CallableEntity = New-CsAutoAttendantCallableEntity -Identity `"$URI`" -Type ExternalPstn") | Out-Null
                    $CommandText.AppendLine("`$$CommandHashName[`"Action`"] = `"TransferCallToTarget`"") | Out-Null
                    $CommandText.AppendLine("`$$CommandHashName[`"CallTarget`"] = `$CallableEntity") | Out-Null

                }
                else {
                    $CommandText.AppendLine("`$$CommandHashName[`"$ActionName`"] = `"Forward`"") | Out-Null
                    $CommandText.AppendLine("`$$CommandHashName[`"$ActionTargetName`"] = `"$URI`"") | Out-Null
                }
            }
        }
        "TransferToQueue" {
            $Queue = $ProcessedQueues.Where( { $_.Identity -eq $QueueId })[0]
            if ($null -eq $Queue) {
                $WarningStrings.AppendLine("$FlowName will to transfer to the queue with ID: $QueueId. This queue was not found, the $ActionName will be set to disconnect") | Out-Null
                $CommandText.AppendLine("Write-Warning `"Queue not found, set to Disconnect`"") | Out-Null
                WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption
            }
            else {
                $QueueName = "CQ " + (CleanName $Queue.Name)
                $WarningStrings.AppendLine("$FlowName will to transfer to the $QueueName queue. Ensure queue exists online, otherwise, the $ActionName will be set to disconnect") | Out-Null
                $CommandText.AppendLine("`$Queue = try {") | Out-Null
                $CommandText.AppendLine("`t@(Get-CsCallQueue -NameFilter `"$QueueName`" -First 1)[0].Identity") | Out-Null
                $CommandText.AppendLine("} catch {") | Out-Null
                $CommandText.AppendLine("`t`$null") | Out-Null
                $CommandText.AppendLine("}") | Out-Null

                $CommandText.AppendLine("if ([string]::IsNullOrEmpty(`$Queue)) {") | Out-Null
                $CommandText.AppendLine("`tWrite-Warning `"TransferToQueue could not find valid object for $QueueName, $ActionName set to Disconnect`"") | Out-Null
                WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption 1
                $CommandText.AppendLine("} else {") | Out-Null
                if ($AAMenuOption) {
                    $CommandText.AppendLine("`t`$CallableEntity = New-CsAutoAttendantCallableEntity -Identity `$Queue -Type HuntGroup") | Out-Null
                    $CommandText.AppendLine("`t`$$CommandHashName[`"Action`"] = `"TransferCallToTarget`"") | Out-Null
                    $CommandText.AppendLine("`t`$$CommandHashName[`"CallTarget`"] = `$CallableEntity") | Out-Null

                }
                else {
                    $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionName`"] = `"Forward`"") | Out-Null
                    $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionTargetName`"] = `$Queue") | Out-Null
                }
                $CommandText.AppendLine("}") | Out-Null
            }
        }
        "TransferToUri" {
            $WarningStrings.AppendLine("$FlowName will to transfer to $URI. Ensure user/object exists online, otherwise, the $ActionName will be set to disconnect") | Out-Null
            $CommandText.AppendLine("`$Target = try {") | Out-Null
            $CommandText.AppendLine("`t(Get-CsOnlineUser -Identity `"$URI`").ObjectID.Guid") | Out-Null
            $CommandText.AppendLine("} catch {") | Out-Null
            $CommandText.AppendLine("`t`$null") | Out-Null
            $CommandText.AppendLine("}") | Out-Null
            $CommandText.AppendLine("if ([string]::IsNullOrEmpty(`$Target)) {") | Out-Null
            $CommandText.AppendLine("`tWrite-Warning `"TransferToUri could not find valid object for $URI, $ActionName set to Disconnect`"") | Out-Null
            WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption 1
            $CommandText.AppendLine("} else {") | Out-Null
            if ($AAMenuOption) {
                $CommandText.AppendLine("`t`$CallableEntity = New-CsAutoAttendantCallableEntity -Identity `$Target -Type User") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"Action`"] = `"TransferCallToTarget`"") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"CallTarget`"] = `$CallableEntity") | Out-Null

            }
            else {
                $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionName`"] = `"Forward`"") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionTargetName`"] = `"`$Target`"") | Out-Null
            }
            $CommandText.AppendLine("}") | Out-Null
        }
        "TransferToVoicemailUri" {
            $WarningStrings.AppendLine("$FlowName will to transfer to $([regex]::replace($URI,'^[Ss][Ii][Pp]:','')). Ensure Microsoft 365 Mail Enabled group exists, otherwise, the $ActionName will be set to disconnect") | Out-Null
            $CommandText.AppendLine("`$Target = try {") | Out-Null
            $CommandText.AppendLine("`t(Find-CsGroup -SearchQuery `"$([regex]::replace($URI,'^[Ss][Ii][Pp]:',''))`" -ExactMatchOnly `$true -MaxResults 1 -MailEnabledOnly `$true).Id.Guid") | Out-Null
            $CommandText.AppendLine("} catch {") | Out-Null
            $CommandText.AppendLine("`t`$null") | Out-Null
            $CommandText.AppendLine("}") | Out-Null
            $CommandText.AppendLine("if ([string]::IsNullOrEmpty(`$Target)) {") | Out-Null
            $CommandText.AppendLine("`tWrite-Warning `"TransferToVoicemailUri could not find valid object for $([regex]::replace($URI,'^[Ss][Ii][Pp]:','')), $ActionName set to Disconnect`"") | Out-Null
            WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption 1
            $CommandText.AppendLine("} else {") | Out-Null
            if ($AAMenuOption) {
                $CommandText.AppendLine("`t`$CallableEntity = New-CsAutoAttendantCallableEntity -Identity `$Target -Type SharedVoicemail -EnableTranscription") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"Action`"] = `"TransferCallToTarget`"") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"CallTarget`"] = `$CallableEntity") | Out-Null

            }
            else {
                if (![string]::IsNullOrEmpty($TextPrompt)) {
                    $CommandText.AppendLine("`t`$$CommandHashName[`"$TextPromptParamName`"] = `"$TextPrompt`"") | Out-Null
                } elseif (![string]::IsNullOrEmpty($AudioFilePromptLocation)) {
                    AddFileImportScript -ApplicationId HuntGroup -StoredLocation $AudioFilePromptLocation -FileName $AudioFilePromptOriginalName -CommandText $CommandText -WarningStrings $WarningStrings
                    $CommandText.AppendLine("`t`$$CommandHashName[`"$AudioPromptParamName`"] = `"`$(`$FileId.Id)`"") | Out-Null
                } else {
                    $WarningStrings.AppendLine("$FlowName will to transfer to $([regex]::replace($URI,'^[Ss][Ii][Pp]:','')) on $ActionName. No Prompt information was found, so a sample Text-To-Speech prompt was generated.") | Out-Null
                    $CommandText.AppendLine("`t`$$CommandHashName[`"$TextPromptParamName`"] = `"Please leave a message.`"") | Out-Null
                }
                $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionName`"] = `"Voicemail`"") | Out-Null
                $CommandText.AppendLine("`t`$$CommandHashName[`"$ActionTargetName`"] = `"`$Target`"") | Out-Null
            }
            $CommandText.AppendLine("}") | Out-Null
        }
        default {
            if ([string]::IsNullOrEmpty($Action)) {
                $WarningStrings.AppendLine("$FlowName had no action assigned. The $ActionName will be set to disconnect") | Out-Null
            }
            else {
                $WarningStrings.AppendLine("$FlowName attempted to $Action. This is not supported in this script, the $ActionName will be set to disconnect") | Out-Null
            }
            WriteDisconnectAction -CommandText $CommandText -CommandHashName $CommandHashName -ActionName $ActionName -AAMenuOption:$AAMenuOption
        }
    }
    $WarningStrings.ToString()
}

function AddFileImportScript {
    param (
        [ValidateSet("HuntGroup", "OrgAutoAttendant")]
        [string] 
        $ApplicationId = "HuntGroup",
        $StoredLocation,
        $FileName,
        [Text.StringBuilder]
        $CommandText,
        [Text.StringBuilder]
        $WarningStrings
    )
    $FilePath = Get-ChildItem -Path $StoredLocation
    $AudioFilePath = [IO.Path]::Combine($GeneratedScriptsPath, "AudioFiles")
    $SavedFile = [IO.Path]::Combine($AudioFilePath, $FilePath.Name)
    if (!(Test-Path -Path $SavedFile)) {
        if (!(Test-Path -Path $AudioFilePath)) {
            New-Item -Path $AudioFilePath -ItemType Directory | Out-Null
        }
        Copy-Item -Path $FilePath.FullName -Destination $AudioFilePath
    }
    $WarningStrings.AppendLine("Ensure this file exists in this relative path prior to execution: .\AudioFiles\$([IO.Path]::GetFileName($SavedFile))") | Out-Null
    $CommandText.AppendLine("`$FilePath = [IO.Path]::Combine(`$PSScriptRoot, `"AudioFiles`", `"$([IO.Path]::GetFileName($SavedFile))`")") | Out-Null
    $CommandText.AppendLine("`$FileBytes = Get-Content -Path `$FilePath -Encoding Byte -ReadCount 0") | Out-Null
    $CommandText.AppendLine("`$FileId = Import-CsOnlineAudioFile -ApplicationId $ApplicationId -FileName `"$FileName`" -Content `$FileBytes") | Out-Null
}

function RoundTimeSpan ([TimeSpan] $ts) {
    $Days = $ts.Days
    $Hours = $ts.Hours
    $Minutes = $ts.Minutes

    $Minutes = 15 * [int][Math]::Round($Minutes / 15.0)
    if ($Minutes -eq 60) {
        $Hours += 1
        $Minutes = 0
    }
    if ($Hours -eq 24) {
        $Days += 1
        $Hours = 0
    }

    [TimeSpan]::new($Days, $Hours, $Minutes, 0).ToString()
}

function ConvertFrom-BusinessHoursToTimeRange {
    param (
        $Hours1,
        $Hours2
    )
    $ConfigString = "@("
    if ($null -ne $Hours1) {
        $ConfigString += "(New-CsOnlineTimeRange -Start `"$(RoundTimeSpan $Hours1.OpenTime)`" -End `"$(RoundTimeSpan $Hours1.CloseTime)`")"
    }
    if ($null -ne $Hours2) {
        if ($ConfigString.Length -gt 2) {
            $ConfigString += ",$([Environment]::NewLine)"
        }
        $ConfigString += "(New-CsOnlineTimeRange -Start `"$(RoundTimeSpan $Hours2.OpenTime)`" -End `"$(RoundTimeSpan $Hours2.CloseTime)`")"
    }
    $ConfigString += ")"
    $ConfigString
}

function CleanName ($Name, $LineURI) {
    $Name = $Name.Trim()
    $Name = [regex]::Replace($Name, 'RGS', '')
    $Name = [regex]::Replace($Name, '[^a-zA-Z0-9\-\(\)\s_]', '')
    $Name = [regex]::Replace($Name, '[\-_]', ' ')
    # delete extra spaces
    $Name = [regex]::Replace($Name, '\s+', ' ')
    $Name = [regex]::Replace($Name, 'queue$', '', 'IgnoreCase')
    # shorten longer names
    $MaxLength = 64 - 3
    if ([string]::IsNullOrWhiteSpace($LineURI)) { $MaxLength -= ($LineURI.Length + 3) }
    $Name = $Name.substring(0, [System.Math]::Min($MaxLength, $Name.Length))

    # Remove spaces at beginning and end and Add LineURI to the end to be used for the DisplayName
    if (![string]::IsNullOrWhiteSpace($LineURI)) {
        $Name.Trim() + " (" + $LineURI + ")"
    }
    else {
        $Name.Trim()
    }
}
function HashTableToDeclareString ([hashtable]$Hashtable, $VariableName = 'HashTable') {
    # only handles string, int or bool types, or collections of those
    $MaxLength = $Hashtable.Keys.Length | Sort-Object -Descending | Select-Object -First 1
    if ($null -eq $MaxLength) { $MaxLength = 1 }
    $sb = [Text.StringBuilder]::new()
    foreach ($kv in $Hashtable.GetEnumerator()) {
        $Value = if ($null -eq $kv.Value) {
            "`$null"
        }
        else {
            switch -regex ($kv.Value.GetType().ToString().ToLower()) {
                "^system\.object\[\]$" {
                    $Nested = @("@(")
                    $Nested += foreach ($v in $kv.Value) {
                        switch -regex ($v.GetType().ToString().ToLower()) {
                            "int\d*$" {
                                $v
                                break
                            }
                            "bool" {
                                "`$$($v.ToString().ToLower())"
                            }
                            default {
                                "`"$($v)`""
                                break
                            }
                        }
                    }
                    $Nested += ")"
                    [string]::Join([Environment]::NewLine, $Nested)
                    break
                }
                "int\d*$" {
                    $kv.Value
                    break
                }
                "bool" {
                    "`$$($kv.Value.ToString().ToLower())"
                }
                default {
                    "`"$($kv.Value)`""
                    break
                }
            }
        }
        $sb.AppendLine("`$$VariableName[`"$($kv.Key)`"] = $Value") | Out-Null
    }
    $sb.ToString()
}
function GetSoundPath($AudioFilePrompt, $InstanceId) {
    if ($null -ne $AudioFilePrompt) {
        $SoundUnique = $AudioFilePrompt.UniqueName
        $SoundFile = $AudioFilePrompt.OriginalFileName
        $actualFileName = $SoundUnique + [IO.Path]::GetExtension($SoundFile)
        $SoundPath = $RGSExportPath + "\*\RgsImportExport\RGS\Instances\" + $instanceID + "\"
        $SoundPath = (Resolve-Path $SoundPath).Path

        $FilePath = Get-ChildItem -Path $SoundPath -Recurse -Filter $actualFileName
        $SoundPath = if ($null -eq $FilePath) {
            $actualFileName = $SoundUnique + ".wav"
            $FilePath = Get-ChildItem -Path $SoundPath -Recurse -Filter $actualFileName
            if ($null -eq $FilePath) {
                Write-Warning "Instance ID: $instanceID, Sound File: $SoundFile, or Sound Unique: $SoundUnique not found! Unable to locate file"
                ""
            }
            else {
                $FilePath.FullName
            }
        }
        else {
            $FilePath.FullName
        }
        $SoundPath
    }
    else {
        ""
    }
}
function ProcessAnswer {
    param(
        $Answer,
        $Prefix
    )
    switch ($Tier2_DefaultAnswer.DtmfResponse) {
        "#" {
            $Option = ($Prefix + "Pound")
        }
        "*" {
            $Option = ($Prefix + "Star")
        }
        default {
            $Option = ($Prefix + $Answer.DtmfResponse)
        }
    }

    switch ($Answer.Action.Action) {
        "Terminate" {
            $InsertHash["$Option"] = $null
        }
        "TransferToQueue" {
            $TransferToQueue = $Answer.Action.QueueID.InstanceID.Guid
            $InsertHash["$Option"] = $(if ([string]::IsNullOrEmpty($Answer.Action.QueueID)) { $null } else { $TransferToQueue })
        }
        "TransferToQuestion" {
            $InsertHash["$Option"] = $(if ([string]::IsNullOrEmpty($Answer.Action.Question)) { $null } else { "TransferToQuestion" })
        }
        "TransferToUri" {
            $InsertHash["$Option"] = $(if ([string]::IsNullOrEmpty($Answer.Action.URI)) { $null } else { $Answer.Action.URI })
        }
        "TransferToVoicemailUri" {
            $InsertHash["$Option"] = $(if ([string]::IsNullOrEmpty($Answer.Action.URI)) { $null } else { $Answer.Action.URI })
        }
        "TransferToPstn" {
            $InsertHash["$Option"] = $(if ([string]::IsNullOrEmpty($Answer.Action.URI)) { $null } else { $Answer.Action.URI })
        }
        default {
            $InsertHash["$Option"] = $null
        }
    }
}

$ProcessedWorkflows = @(foreach ($ThisFlow in $WorkFlows) {
        $InsertHash = @{}
        $InsertHash['Identity'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Identity)) { $null } else { $ThisFlow.Identity.InstanceId.Guid })

        $SoundPath = GetSoundPath ($ThisFlow).NonBusinessHoursAction.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['NonBusinessHoursActionPromptAudioFilePromptStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['NonBusinessHoursActionPromptAudioFilePromptOriginalFileName'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.Prompt.AudioFilePrompt.OriginalFileName)) { $null } else { ($ThisFlow).NonBusinessHoursAction.Prompt.AudioFilePrompt.OriginalFileName })
        $InsertHash['NonBusinessHoursActionPromptTextToSpeechPrompt'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.Prompt.TextToSpeechPrompt)) { $null } else { ($ThisFlow).NonBusinessHoursAction.Prompt.TextToSpeechPrompt })
        $InsertHash['NonBusinessHoursActionQuestion'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.Question)) { $null } else { ($ThisFlow).NonBusinessHoursAction.Question })
        $InsertHash['NonBusinessHoursActionAction'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.Action)) { $null } else { ($ThisFlow).NonBusinessHoursAction.Action })
        $InsertHash['NonBusinessHoursActionQueueID'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.QueueID)) { $null } else { ($ThisFlow).NonBusinessHoursAction.QueueID.InstanceID.Guid })
        $InsertHash['NonBusinessHoursActionURI'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).NonBusinessHoursAction.URI)) { $null } else { ($ThisFlow).NonBusinessHoursAction.URI })

        $SoundPath = GetSoundPath ($ThisFlow).HolidayAction.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['HolidayActionPromptAudioFilePromptStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['HolidayActionPromptAudioFilePromptOriginalFileName'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.Prompt.AudioFilePrompt.OriginalFileName)) { $null } else { ($ThisFlow).HolidayAction.Prompt.AudioFilePrompt.OriginalFileName })
        $InsertHash['HolidayActionPromptTextToSpeechPrompt'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.Prompt.TextToSpeechPrompt)) { $null } else { ($ThisFlow).HolidayAction.Prompt.TextToSpeechPrompt })
        $InsertHash['HolidayActionQuestion'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.Question)) { $null } else { ($ThisFlow).HolidayAction.Question })
        $InsertHash['HolidayActionAction'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.Action)) { $null } else { ($ThisFlow).HolidayAction.Action })
        $InsertHash['HolidayActionQueueID'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.QueueID)) { $null } else { ($ThisFlow).HolidayAction.QueueID.InstanceID.Guid })
        $InsertHash['HolidayActionURI'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidayAction.URI)) { $null } else { ($ThisFlow).HolidayAction.URI })

        $SoundPath = GetSoundPath ($ThisFlow).DefaultAction.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['DefaultActionPromptAudioFilePromptStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['DefaultActionPromptAudioFilePromptOriginalFileName'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.Prompt.AudioFilePrompt.OriginalFileName)) { $null } else { ($ThisFlow).DefaultAction.Prompt.AudioFilePrompt.OriginalFileName })
        $InsertHash['DefaultActionPromptTextToSpeechPrompt'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.Prompt.TextToSpeechPrompt)) { $null } else { ($ThisFlow).DefaultAction.Prompt.TextToSpeechPrompt })
        $InsertHash['DefaultActionQuestion'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.Question)) { $null } else { ($ThisFlow).DefaultAction.Question })
        $InsertHash['DefaultActionAction'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.Action)) { $null } else { ($ThisFlow).DefaultAction.Action })
        $InsertHash['DefaultActionQueueID'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.QueueID)) { $null } else { ($ThisFlow).DefaultAction.QueueID.InstanceID.Guid })
        $InsertHash['DefaultActionURI'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).DefaultAction.URI)) { $null } else { ($ThisFlow).DefaultAction.URI })
        
        $SoundPath = GetSoundPath ($ThisFlow).CustomMusicOnHoldFile $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['CustomMusicOnHoldStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['CustomMusicOnHoldFileName'] = $(if ([string]::IsNullOrEmpty($ThisFlow.CustomMusicOnHoldFile.OriginalFileName)) { $null } else { $ThisFlow.CustomMusicOnHoldFile.OriginalFileName })
        
        $InsertHash['Name'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Name)) { $null } else { $ThisFlow.Name })
        $InsertHash['Description'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Description)) { $null } else { $ThisFlow.Description })
        $InsertHash['PrimaryUri'] = $(if ([string]::IsNullOrEmpty($ThisFlow.PrimaryUri)) { $null } else { $ThisFlow.PrimaryUri })
        $InsertHash['Active'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Active)) { $null } else { $ThisFlow.Active })
        $InsertHash['Language'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Language)) { $null } else { $ThisFlow.Language })
        $InsertHash['TimeZone'] = $(if ([string]::IsNullOrEmpty($ThisFlow.TimeZone)) { $null } else { $ThisFlow.TimeZone })
        $InsertHash['Anonymous'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Anonymous)) { $null } else { $ThisFlow.Anonymous })
        $InsertHash['Managed'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Managed)) { $null } else { $ThisFlow.Managed })
        $InsertHash['OwnerPool'] = $(if ([string]::IsNullOrEmpty($ThisFlow.OwnerPool)) { $null } else { $ThisFlow.OwnerPool })
        $InsertHash['DisplayNumber'] = $(if ([string]::IsNullOrEmpty($ThisFlow.DisplayNumber)) { $null } else { $ThisFlow.DisplayNumber })
        $InsertHash['EnabledForFederation'] = $(if ([string]::IsNullOrEmpty($ThisFlow.EnabledForFederation)) { $null } else { $ThisFlow.EnabledForFederation })
        $InsertHash['LineUri'] = $(if ([string]::IsNullOrEmpty($ThisFlow.LineUri)) { $null } else { $ThisFlow.LineUri })
        $InsertHash['BusinessHoursID'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).BusinessHoursID)) { $null } else { ($ThisFlow).BusinessHoursID.InstanceID.Guid })
        $InsertHash['HolidayHoursIDs'] = $(if ([string]::IsNullOrEmpty(($ThisFlow).HolidaySetIDList)) { $null } else { ($ThisFlow).HolidaySetIDList.InstanceID.Guid })
        $InsertHash['ManagersByUri'] = $(if ([string]::IsNullOrEmpty($ThisFlow.ManagersByUri)) { $null } else { $ThisFlow.ManagersByUri })

        [PSCustomObject]$InsertHash
    })

$ProcessedQueues = @(foreach ($ThisQueue in $Queues) {
        $InsertHash = @{}
        $WarningStrings = [Text.StringBuilder]::new()
        $ThisQueueID = $ThisQueue.Identity.InstanceID.Guid
        $ThisQueueIDList = if ($null -ne $ThisQueue.AgentGroupIDList[0]) {
            $ThisQueue.AgentGroupIDList[0].InstanceID.Guid
        }
        else {
            ""
        }
        if ($ThisQueue.AgentGroupIDList.Count -gt 1) {
            $WarningStrings.AppendLine("$($ThisQueue.Name) has multiple agent groups, only the first group will be included") | Out-Null
        }

        $TimeOut = ($ThisQueue).TimeoutAction
        $Overflow = ($ThisQueue).OverflowAction

        $InsertHash['Identity'] = $(if ([string]::IsNullOrEmpty($ThisQueueID)) { $null } else { $ThisQueueID })
        $InsertHash['Name'] = $(if ([string]::IsNullOrEmpty($ThisQueue.Name)) { $null } else { $ThisQueue.Name })
        $InsertHash['Description'] = $(if ([string]::IsNullOrEmpty($ThisQueue.Description)) { $null } else { $ThisQueue.Description })
        $InsertHash['TimeoutThreshold'] = $(if ([string]::IsNullOrEmpty($ThisQueue.TimeoutThreshold)) { $null } else { $ThisQueue.TimeoutThreshold })
        $InsertHash['OverflowThreshold'] = $(if ([string]::IsNullOrEmpty($ThisQueue.OverflowThreshold)) { $null } else { $ThisQueue.OverflowThreshold })
        $InsertHash['OverflowCandidate'] = $(if ([string]::IsNullOrEmpty($ThisQueue.OverflowCandidate)) { $null } else { $ThisQueue.OverflowCandidate })
        $InsertHash['OwnerPool'] = $(if ([string]::IsNullOrEmpty($ThisQueue.OwnerPool)) { $null } else { $ThisQueue.OwnerPool })
        $InsertHash['AgentGroupIDList'] = $(if ([string]::IsNullOrEmpty($ThisQueueIDList)) { $null } else { $ThisQueueIDList })
    
        $SoundPath = GetSoundPath $TimeOut.Prompt.AudioFilePrompt $ThisQueue.Identity.InstanceID.Guid
        if (![string]::IsNullOrEmpty($SoundPath)) { Write-Host "CQ $($ThisFlow.Name) TimeoutPrompt $SoundPath" }
        $InsertHash['TimeoutAudioStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['TimeoutAudioOriginalName'] = $(if ([string]::IsNullOrEmpty($TimeOut.Prompt.AudioFilePrompt.OriginalName)) { $null } else { $TimeOut.prompt.AudioFilePrompt.OriginalName })

        $InsertHash['TimeoutTextPrompt'] = $(if ([string]::IsNullOrEmpty($TimeOut.Prompt.TextFilePrompt)) { $null } else { $TimeOut.Prompt.TextFilePrompt })   
        $InsertHash['TimeoutQuestion'] = $(if ([string]::IsNullOrEmpty($TimeOut.Question)) { $null } else { $TimeOut.Question })
        $InsertHash['TimeoutAction'] = $(if ([string]::IsNullOrEmpty($TimeOut.Action)) { $null } else { $TimeOut.Action })
        $InsertHash['TimeoutQueueID'] = $(if ([string]::IsNullOrEmpty($TimeOut.QueueID)) { $null } else { $TimeOut.QueueID.InstanceID.Guid })
        $InsertHash['TimeoutUri'] = $(if ([string]::IsNullOrEmpty($TimeOut.Uri)) { $null } else { $TimeOut.Uri })    
    

        $SoundPath = GetSoundPath $Overflow.Prompt.AudioFilePrompt $ThisQueue.Identity.InstanceID.Guid
        if (![string]::IsNullOrEmpty($SoundPath)) { Write-Host "CQ $($ThisFlow.Name) OverflowPrompt $SoundPath" }
        $InsertHash['OverflowAudioStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })
        $InsertHash['OverflowAudioOriginalName'] = $(if ([string]::IsNullOrEmpty($Overflow.prompt.AudioFilePrompt.OriginalName)) { $null } else { $Overflow.prompt.AudioFilePrompt.OriginalName })

        $InsertHash['OverflowTextPrompt'] = $(if ([string]::IsNullOrEmpty($Overflow.Prompt.TextFilePrompt)) { $null } else { $Overflow.Prompt.TextFilePrompt })
        $InsertHash['OverflowQuestion'] = $(if ([string]::IsNullOrEmpty($Overflow.Question)) { $null } else { $Overflow.Question })
        $InsertHash['OverflowAction'] = $(if ([string]::IsNullOrEmpty($Overflow.Action)) { $null } else { $Overflow.Action })
        $InsertHash['OverflowQueueID'] = $(if ([string]::IsNullOrEmpty($Overflow.QueueID)) { $null } else { $Overflow.QueueID.InstanceID.Guid })
        $InsertHash['OverflowUri'] = $(if ([string]::IsNullOrEmpty($Overflow.URI)) { $null } else { $Overflow.URI })
        $InsertHash['Warnings'] = $WarningStrings.ToString()
        [PSCustomObject]$InsertHash
    })

$IVRs = $ProcessedWorkflows.Where( { $_.PSObject.Properties.Value.Contains('TransferToQuestion') }).ForEach('Identity')
$ProcessedIVRs = @(foreach ($RGS in $IVRs) {
        $ThisFlow = $WorkFlows.Where( { $_.Identity.InstanceID.Guid -eq $RGS })[0]

        $InsertHash = @{}
        $ThisFlowID = $RGS
        $ThisFlowName = $ThisFlow.Name
        ##### Generic write back
        $InsertHash['Identity'] = $(if ([string]::IsNullOrEmpty($ThisFlowID)) { $null } else { $ThisFlowID })
        $InsertHash['Name'] = $(if ([string]::IsNullOrEmpty($ThisFlowName)) { $null } else { $ThisFlowName })
        ##### Default write-backs

        $SoundPath = GetSoundPath $ThisFlow.DefaultAction.Question.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['DefaultAudioStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })

        $ThisFlowDefaultAudioOriginalName = $ThisFlow.DefaultAction.Question.Prompt.AudioFilePrompt.OriginalFileName
        $InsertHash['DefaultAudioOriginalName'] = $(if ([string]::IsNullOrEmpty($ThisFlowDefaultAudioOriginalName)) { $null } else { $ThisFlowDefaultAudioOriginalName })
        $ThisFlowDefaultTextToSpeech = $ThisFlow.DefaultAction.Question.Prompt.TextToSpeechPrompt
        $InsertHash['DefaultTextToSpeech'] = $(if ([string]::IsNullOrEmpty($ThisFlowDefaultTextToSpeech)) { $null } else { $ThisFlowDefaultTextToSpeech })
        $ThisFlowDefaultInvalidAnswer = $ThisFlow.DefaultAction.Question.InvalidAnswerPrompt
        $InsertHash['DefaultInvalidAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowDefaultInvalidAnswer)) { $null } else { $ThisFlowDefaultInvalidAnswer })
        $ThisFlowDefaultNoAnswer = $ThisFlow.DefaultAction.Question.NoAnswerPrompt
        $InsertHash['DefaultNoAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowDefaultNoAnswer)) { $null } else { $ThisFlowDefaultNoAnswer })
        $ThisFlowDefaultName = $ThisFlow.DefaultAction.Question.Name
        $InsertHash['DefaultName'] = $(if ([string]::IsNullOrEmpty($ThisFlowDefaultName)) { $null } else { $ThisFlowDefaultName })
    
        ##### Nulling out the options for write back
        $InsertHash['DefaultOpt0'] = $null
        $InsertHash['DefaultOpt1'] = $null
        $InsertHash['DefaultOpt2'] = $null
        $InsertHash['DefaultOpt3'] = $null
        $InsertHash['DefaultOpt4'] = $null
        $InsertHash['DefaultOpt5'] = $null
        $InsertHash['DefaultOpt6'] = $null
        $InsertHash['DefaultOpt7'] = $null
        $InsertHash['DefaultOpt8'] = $null
        $InsertHash['DefaultOpt9'] = $null
        $InsertHash['DefaultOptPound'] = $null
        $InsertHash['DefaultOptStar'] = $null

        ##### Go through the answer list in case it exists and overwriting the above nulled default values
        if (![string]::IsNullOrEmpty($ThisFlow.DefaultAction.Question.AnswerList)) {
            foreach ($DefaultAnswer in $ThisFlow.DefaultAction.Question.AnswerList) {
                ProcessAnswer $DefaultAnswer "DefaultOpt"
            } 
        }

        ##### NonBus write-backs
        $SoundPath = GetSoundPath $ThisFlow.NonBusinessHoursAction.Question.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['NonBusAudioStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })

        $ThisFlowNonBusAudioOriginalName = $ThisFlow.NonBusinessHoursAction.Question.Prompt.AudioFilePrompt.OriginalFileName
        $InsertHash['NonBusAudioOriginalName'] = $(if ([string]::IsNullOrEmpty($ThisFlowNonBusAudioOriginalName)) { $null } else { $ThisFlowNonBusAudioOriginalName })
        $ThisFlowNonBusTextToSpeech = $ThisFlow.NonBusinessHoursAction.Question.Prompt.TextToSpeechPrompt
        $InsertHash['NonBusTextToSpeech'] = $(if ([string]::IsNullOrEmpty($ThisFlowNonBusTextToSpeech)) { $null } else { $ThisFlowNonBusTextToSpeech })
        $ThisFlowNonBusInvalidAnswer = $ThisFlow.NonBusinessHoursAction.Question.InvalidAnswerPrompt
        $InsertHash['NonBusInvalidAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowNonBusInvalidAnswer)) { $null } else { $ThisFlowNonBusInvalidAnswer })
        $ThisFlowNonBusNoAnswer = $ThisFlow.NonBusinessHoursAction.Question.NoAnswerPrompt
        $InsertHash['NonBusNoAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowNonBusNoAnswer)) { $null } else { $ThisFlowNonBusNoAnswer })
        $ThisFlowNonBusName = $ThisFlow.NonBusinessHoursAction.Question.Name
        $InsertHash['NonBusName'] = $(if ([string]::IsNullOrEmpty($ThisFlowNonBusName)) { $null } else { $ThisFlowNonBusName })

        ##### Nulling out the options for write back
        $InsertHash['NonBusOpt0'] = $null
        $InsertHash['NonBusOpt1'] = $null
        $InsertHash['NonBusOpt2'] = $null
        $InsertHash['NonBusOpt3'] = $null
        $InsertHash['NonBusOpt4'] = $null
        $InsertHash['NonBusOpt5'] = $null
        $InsertHash['NonBusOpt6'] = $null
        $InsertHash['NonBusOpt7'] = $null
        $InsertHash['NonBusOpt8'] = $null
        $InsertHash['NonBusOpt9'] = $null
        $InsertHash['NonBusOptPound'] = $null
        $InsertHash['NonBusOptStar'] = $null

        ##### Go through the answer list in case it exists and overwriting the above nulled default values
        if (![string]::IsNullOrEmpty($ThisFlow.NonBusinessHoursAction.Question.AnswerList)) {
            foreach ($NonBusAnswer in $ThisFlow.NonBusinessHoursAction.Question.AnswerList) {
                ProcessAnswer $NonBusAnswer "NonBusOpt"
            }
        }

        ##### Holiday write-backs
        $SoundPath = GetSoundPath $ThisFlow.HolidayAction.Question.Prompt.AudioFilePrompt $ThisFlow.Identity.InstanceID.Guid
        $InsertHash['HolidayAudioStoredLocation'] = $(if ([string]::IsNullOrEmpty($SoundPath)) { $null } else { $SoundPath })

        $ThisFlowHolidayAudioOriginalName = $ThisFlow.HolidayAction.Question.Prompt.AudioFilePrompt.OriginalFileName
        $InsertHash['HolidayAudioOriginalName'] = $(if ([string]::IsNullOrEmpty($ThisFlowHolidayAudioOriginalName)) { $null } else { $ThisFlowHolidayAudioOriginalName })
        $ThisFlowHolidayTextToSpeech = $ThisFlow.HolidayAction.Question.Prompt.TextToSpeechPrompt
        $InsertHash['HolidayTextToSpeech'] = $(if ([string]::IsNullOrEmpty($ThisFlowHolidayTextToSpeech)) { $null } else { $ThisFlowHolidayTextToSpeech })
        $ThisFlowHolidayInvalidAnswer = $ThisFlow.HolidayAction.Question.InvalidAnswerPrompt
        $InsertHash['HolidayInvalidAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowHolidayInvalidAnswer)) { $null } else { $ThisFlowHolidayInvalidAnswer })
        $ThisFlowHolidayNoAnswer = $ThisFlow.HolidayAction.Question.NoAnswerPrompt
        $InsertHash['HolidayNoAnswer'] = $(if ([string]::IsNullOrEmpty($ThisFlowHolidayNoAnswer)) { $null } else { $ThisFlowHolidayNoAnswer })
        $ThisFlowHolidayName = $ThisFlow.HolidayAction.Question.Name
        $InsertHash['HolidayName'] = $(if ([string]::IsNullOrEmpty($ThisFlowHolidayName)) { $null } else { $ThisFlowHolidayName })

        ##### Nulling out the options for write back
        $InsertHash['HolidayOpt0'] = $null
        $InsertHash['HolidayOpt1'] = $null
        $InsertHash['HolidayOpt2'] = $null
        $InsertHash['HolidayOpt3'] = $null
        $InsertHash['HolidayOpt4'] = $null
        $InsertHash['HolidayOpt5'] = $null
        $InsertHash['HolidayOpt6'] = $null
        $InsertHash['HolidayOpt7'] = $null
        $InsertHash['HolidayOpt8'] = $null
        $InsertHash['HolidayOpt9'] = $null
        $InsertHash['HolidayOptPound'] = $null
        $InsertHash['HolidayOptStar'] = $null

        ##### Go through the answer list in case it exists and overwriting the above nulled default values
        if (![string]::IsNullOrEmpty($ThisFlow.HolidayAction.Question.AnswerList)) {
            foreach ($HolidayAnswer in $ThisFlow.HolidayAction.Question.AnswerList) {
                ProcessAnswer $HolidayAnswer "HolidayOpt"
            }
        }

        [PSCustomObject]$InsertHash
    })

$Tier2IVRs = $ProcessedIVRs.Where( { $_.PSObject.Properties.Value.Contains('TransferToQuestion') }).ForEach('Identity')
$Tier2ProcessedIVRs = @(foreach ($RGS in $Tier2IVRs) {
        $InsertHash = @{}

        $ThisFlow = $WorkFlows | Where-Object { $_.Identity.InstanceID.Guid -eq $RGS }

        $InsertHash['Identity'] = $(if ([string]::IsNullOrEmpty($RGS)) { $null } else { $RGS })
        $InsertHash['Name'] = $(if ([string]::IsNullOrEmpty($ThisFlow.Name)) { $null } else { $ThisFlow.Name })
        $PrimaryAnswerLists = $ThisFlow.DefaultAction.Question.AnswerList.Where( { $_.Action.Action -eq "TransferToQuestion" })

        if (![string]::IsNullOrEmpty($PrimaryAnswerLists)) {
            foreach ($AnswerList in $PrimaryAnswerLists) {
                ##### Nulling out the options for write back
                $InsertHash["Tier2_DefaultOpt0"] = $null
                $InsertHash["Tier2_DefaultOpt1"] = $null
                $InsertHash["Tier2_DefaultOpt2"] = $null
                $InsertHash["Tier2_DefaultOpt3"] = $null
                $InsertHash["Tier2_DefaultOpt4"] = $null
                $InsertHash["Tier2_DefaultOpt5"] = $null
                $InsertHash["Tier2_DefaultOpt6"] = $null
                $InsertHash["Tier2_DefaultOpt7"] = $null
                $InsertHash["Tier2_DefaultOpt8"] = $null
                $InsertHash["Tier2_DefaultOpt9"] = $null
                $InsertHash["Tier2_DefaultOptPound"] = $null
                $InsertHash["Tier2_DefaultOptStar"] = $null

                ##### write back which Primary DTMFResponse we need to dig into further
                $PrimaryDTMFResponse = "DefaultAction_" + $AnswerList.DtmfResponse
                $InsertHash["OriginatorOption"] = $(if ([string]::IsNullOrEmpty($PrimaryDTMFResponse)) { $null } else { $PrimaryDTMFResponse })
            
                ##### getting second tier info for write back
                $SecondAnswerList = $AnswerList.Action.Question.AnswerList
            
                foreach ($Tier2_DefaultAnswer in $SecondAnswerList) {
                    ProcessAnswer $Tier2_DefaultAnswer "Tier2_DefaultOpt"
                }
            }
        }
        [PSCustomObject]$InsertHash
    })

$ProcessedAgentGroups = @(foreach ($AgentGroup in $AgentGroups) {
        $InsertHash = @{}
        $WarningStrings = [Text.StringBuilder]::new()
        $InsertHash['Identity'] = $AgentGroup.Identity.InstanceID.Guid
        $InsertHash['Name'] = $AgentGroup.Name
        $InsertHash['Description'] = $AgentGroup.Description
        $InsertHash['ParticipationPolicy'] = $AgentGroup.ParticipationPolicy
        $InsertHash['AgentAlertTime'] = $AgentGroup.AgentAlertTime
        $InsertHash['RoutingMethod'] = $AgentGroup.RoutingMethod
        $InsertHash['DistributionGroupAddress'] = $AgentGroup.DistributionGroupAddress
        $InsertHash['OwnerPool'] = $AgentGroup.OwnerPool
        $InsertHash['AgentsByUri'] = $AgentGroup.AgentsByUri.AbsolutePath
        if ($null -ne $AgentGroup.DistributionGroupAddress) {
            $WarningStrings.AppendLine("$($AgentGroup.Name) uses DistributionGroup $($AgentGroup.DistributionGroupAddress -join ',')") | Out-Null
            $WarningStrings.AppendLine("Ensure the following commands return valid values:") | Out-Null
            foreach ($dg in $AgentGroup.DistributionGroupAddress) {
                $WarningStrings.AppendLine("`tFind-CsGroup -SearchQuery `"$dg`" -ExactMatchOnly `$true") | Out-Null
            }
        }
        $InsertHash['Warnings'] = $WarningStrings.ToString()
        [PSCustomObject]$InsertHash
    })

$CallQueues = $ProcessedWorkflows.Where( { $_.Identity -notin $ProcessedIVRs.Identity })
foreach ($Workflow in $CallQueues) {
    $CommandText = [Text.StringBuilder]::new()
    $DefaultQueue = $ProcessedQueues.Where( { $_.Identity -eq $Workflow.DefaultActionQueueID }, 'First')[0]
    $WarningStrings = [Text.StringBuilder]::new()
    if (![string]::IsNullOrEmpty($Workflow.Warnings)) {
        $WarningStrings.AppendLine($Workflow.Warnings) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($DefaultQueue.Name)) {
        $WarningStrings.AppendLine("Default Queue: $($Workflow.DefaultActionQueueID) for $($Workflow.Name) has no valid name assigned") | Out-Null
    }
    if (![string]::IsNullOrEmpty($DefaultQueue.Warnings)) {
        $WarningStrings.AppendLine($DefaultQueue.Warnings) | Out-Null
    }

    # Define the name based on the available data in the row if on-prem Queue Name fails use the workflow name
    $AAName = if ([string]::IsNullOrEmpty($Workflow.Name)) {
        if ([string]::IsNullOrEmpty($DefaultQueue.Name)) {
            Write-Warning "Workflow has no valid name"
            continue
        }
        else {
            $DefaultQueue.Name
        }
    }
    else {
        $Workflow.Name
    }
    $CQName = if ([string]::IsNullOrEmpty($DefaultQueue.Name)) {
        if ([string]::IsNullOrEmpty($Workflow.Name)) {
            Write-Warning "Workflow has no valid name"
            continue
        }
        else {
            $Workflow.Name
        }
    }
    else {
        $DefaultQueue.Name
    }
    $LineURI = [regex]::Replace($Workflow.LineURI, '[Xx]', '')
    $LineURI = [regex]::Replace($LineURI, ';[Ee][Tt]=', 'x')
    $LineURI = [regex]::Replace($LineURI, '[^0-9x]', '')

    $NameLURI = CleanName $CQName $LineURI
    $CQNameLURI = "CQ " + $NameLURI
    $NameLURI = CleanName $AAName $LineURI
    $AANameLURI = "AA " + $NameLURI
    $AADispName = $NameLURI
    $CQDispName = $CQNameLURI

    $FileName = [IO.Path]::Combine($GeneratedScriptsPath, ($AADispName + ".ps1"))

    $CallQueueParams = @{}
    # Add name to param list
    $CallQueueParams["Name"] = "`$CQName"

    # TODO: Need to add module logic to a given script, also any imports as needed for session reconnection

    $CommandText.AppendLine("# Original HuntGroup Name: $($Workflow.Name)") | Out-Null
    $CommandText.AppendLine("#     Original Queue Name: $($DefaultQueue.Name)") | Out-Null
    $CommandText.AppendLine("#             New AA Name: $AADispName") | Out-Null
    $CommandText.AppendLine("#             New CQ Name: $CQDispName") | Out-Null
    $CommandText.AppendLine("#                 LineUri: $LineURI") | Out-Null
    $CommandText.AppendLine() | Out-Null
    $CommandText.AppendLine("# OVERRIDE AUTOMATIC NAMING HERE") | Out-Null
    $CommandText.AppendLine("# these will be the display names used for the created AA and CQ objects") | Out-Null
    $CommandText.AppendLine("`$AAName = `"$AADispName`"") | Out-Null
    $CommandText.AppendLine("`$CQName = `"$CQDispName`"") | Out-Null
    $CommandText.AppendLine("# these strings will be used to generate the UPN for the objects in AAD/AD. Only A-Z, a-z, 0-9, - and _ characters will be kept. Also, all strings will be shortened to the first 17 characters") | Out-Null
    $CommandText.AppendLine("# if there is a conflict found with another account, the string will be shortened to 13 characters and 4 random letters will be added to the end of the string") | Out-Null
    $CommandText.AppendLine("`$CQAccountName = `"$CQName`"`t# this will be prefixed with `"CQ-`"") | Out-Null
    $CommandText.AppendLine("`$AAAccountName = `"$AAName`"`t# this will be prefixed with `"AA-`"") | Out-Null
    $CommandText.AppendLine() | Out-Null
    $CommandText.AppendLine() | Out-Null
    $CommandText.AppendLine("# Building the Call Queue") | Out-Null
    $CommandText.AppendLine() | Out-Null
    $CommandText.AppendLine("`$CallQueueParams = @{}") | Out-Null

    $DefaultQueueAgentGroup = $ProcessedAgentGroups.Where( { $_.Identity -eq $DefaultQueue.AgentGroupIDList })[0]
    if (![string]::IsNullOrEmpty($DefaultQueueAgentGroup.Warnings)) {
        $WarningStrings.AppendLine($DefaultQueueAgentGroup.Warnings) | Out-Null
    }

    if ($null -eq $DefaultQueueAgentGroup) {
        Write-Warning "$($DefaultQueue.Name) has no assigned Agent Groups, this will not be processed further."
        continue
        # Write-Warning "$FileName has no assigned Agent Groups"
        # $WarningStrings.AppendLine("$($DefaultQueue.Name) has no assigned Agent Groups") | Out-Null
    }
    $CallQueueParams["AllowOptOut"] = $DefaultQueueAgentGroup.ParticipationPolicy -eq 'Informal'     # AllowOptOut: Informal -> true, Formal -> false

    $RoundValueParams = @{
        InputTime   = $DefaultQueueAgentGroup.AgentAlertTime
        MinimumTime = 30
        RoundTo     = 15
        MaximumTime = 180
    }
    $CallQueueParams["AgentAlertTime"] = RoundValue @RoundValueParams

    if ($DefaultQueueAgentGroup.DistributionGroupAddress.Count -gt 0) {
        $CommandText.AppendLine("# Adding Distribution Groups from AgentGroup to the Queue") | Out-Null
        $CommandText.AppendLine("`$DGroups = [Collections.Generic.List[object]]::new()") | Out-Null
        $CommandText.AppendLine("`$DGs = @(") | Out-Null
        foreach ($DList in $DefaultQueueAgentGroup.DistributionGroupAddress) {
            $CommandText.AppendLine("`t`"$DList`"") | Out-Null
        }
        $CommandText.AppendLine(")") | Out-Null
        $CommandText.AppendLine("foreach (`$Dlist in `$DGs) {") | Out-Null
        $CommandText.AppendLine("`t`$GroupId = try {") | Out-Null
        $CommandText.AppendLine("`t(Find-CsGroup -SearchQuery `$Dlist -ExactMatchOnly `$true -MaxResults 1).Id.Guid") | Out-Null
        $CommandText.AppendLine("`t} catch {") | Out-Null
        $CommandText.AppendLine("`t`t`$null") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null
        $CommandText.AppendLine("`tif (`$null -ne `$GroupId) {") | Out-Null
        $CommandText.AppendLine("`t`t`$DGroups.Add(`$GroupId) | Out-Null") | Out-Null
        $CommandText.AppendLine("`t} else {") | Out-Null
        $CommandText.AppendLine("`t`tWrite-Warning `"Could not find valid object for `$DList, skipping`"") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null
        $CommandText.AppendLine("}") | Out-Null

        $CommandText.AppendLine("if (`$DGroups.Count -gt 0) {") | Out-Null
        $CommandText.AppendLine("`t`$CallQueueParams[`"DistributionLists`"] = `$DGroups") | Out-Null
        $CommandText.AppendLine("}") | Out-Null
        $CommandText.AppendLine() | Out-Null
    }

    if ($DefaultQueueAgentGroup.AgentsByUri.Count -gt 0) {
        $CommandText.AppendLine("# Adding Agent Uris from AgentGroup to the Queue") | Out-Null
        $CommandText.AppendLine("`$AgentsByUri = [Collections.Generic.List[object]]::new()") | Out-Null
        $CommandText.AppendLine("`$AgentUris = @(") | Out-Null
        foreach ($AgentUri in $DefaultQueueAgentGroup.AgentsByUri) {
            $CommandText.AppendLine("`t`"$AgentUri`"") | Out-Null
        }
        $CommandText.AppendLine(")") | Out-Null
        $CommandText.AppendLine("foreach (`$AgentUri in `$AgentUris) {") | Out-Null
        $CommandText.AppendLine("`t`$Agent = try {") | Out-Null
        $CommandText.AppendLine("`t`t(Get-CsOnlineUser -Identity `$AgentUri).ObjectID.Guid") | Out-Null
        $CommandText.AppendLine("`t} catch {") | Out-Null
        $CommandText.AppendLine("`t`t`$null") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null
        $CommandText.AppendLine("`tif (`$null -ne `$Agent) { ") | Out-Null
        $CommandText.AppendLine("`t`t`$AgentsByUri.Add(`$Agent) | Out-Null") | Out-Null
        $CommandText.AppendLine("`t} else {") | Out-Null
        $CommandText.AppendLine("`t`tWrite-Warning `"Could not find valid object for `$AgentUri, skipping`"") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null
        $CommandText.AppendLine("}") | Out-Null
        $CommandText.AppendLine("if (`$AgentsByUri.Count -gt 0) {") | Out-Null
        $CommandText.AppendLine("`t`$CallQueueParams[`"Users`"] = `$AgentsByUri") | Out-Null
        $CommandText.AppendLine("}") | Out-Null
        $CommandText.AppendLine() | Out-Null
    }
    elseif ( $DefaultQueueAgentGroup.DistributionGroupAddress.Count -eq 0 ) {
        Write-Warning "$($DefaultQueue.Name) has no users or distribution groups in its assigned Agent Groups, this will not be processed further."
        continue

        # Write-Warning "$FileName has no users or distribution groups in its assigned Agent Groups"
        # $WarningStrings.AppendLine("$($DefaultQueue.Name) has no users or distribution groups in its assigned Agent Groups") | Out-Null
    }

    $CallQueueParams["RoutingMethod"] = if ( $DefaultQueueAgentGroup.RoutingMethod -eq "Parallel" ) { 
        "Serial"
    }
    else {
        $DefaultQueueAgentGroup.RoutingMethod 
    }

    $CommandText.AppendLine("# Configuring Overflow Action") | Out-Null
    $ConvertActionParams = @{
        FlowName                    = $DefaultQueue.Name
        URI                         = $DefaultQueue.OverflowUri
        QueueId                     = $DefaultQueue.OverflowQueueID
        Action                      = $DefaultQueue.OverflowAction
        CommandText                 = $CommandText
        CommandHashName             = "CallQueueParams"
        ActionName                  = "OverflowAction"
        ActionTargetName            = "OverflowActionTarget"
        AudioFilePromptLocation     = $DefaultQueue.OverflowAudioStoredLocation
        AudioFilePromptOriginalName = $DefaultQueue.OverflowAudioOriginalName
        TextPrompt                  = $DefaultQueue.OverflowTextPrompt
        AudioPromptParamName        = "OverflowSharedVoicemailAudioFilePrompt"
        TextPromptParamName         = "OverflowSharedVoicemailTextToSpeechPrompt"
    }
    $warn = ConvertNonQuestionAction @ConvertActionParams
    if (![string]::IsNullOrEmpty($warn)) {
        $WarningStrings.AppendLine($warn) | Out-Null
    }
    if ($null -ne $DefaultQueueAgentGroup.OverflowThreshold) {
        $RoundValueParams = @{
            InputTime   = $DefaultQueueAgentGroup.OverflowThreshold
            MinimumTime = 0
            RoundTo     = 1
            MaximumTime = 200
        }
        $CallQueueParams["OverflowThreshold"] = RoundValue @RoundValueParams
    }
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Configuring Timeout Action") | Out-Null
    $ConvertActionParams = @{
        FlowName                    = $DefaultQueue.Name
        URI                         = $DefaultQueue.TimeoutUri
        Action                      = $DefaultQueue.TimeoutAction
        QueueId                     = $DefaultQueue.TimeoutQueueID
        CommandText                 = $CommandText
        CommandHashName             = "CallQueueParams"
        ActionName                  = "TimeoutAction"
        ActionTargetName            = "TimeoutActionTarget"
        AudioFilePromptLocation     = $DefaultQueue.TimeoutAudioStoredLocation
        AudioFilePromptOriginalName = $DefaultQueue.TimeoutAudioOriginalName
        TextPrompt                  = $DefaultQueue.TimeoutTextPrompt
        AudioPromptParamName        = "TimeoutSharedVoicemailAudioFilePrompt"
        TextPromptParamName         = "TimeoutSharedVoicemailTextToSpeechPrompt"
    }
    $warn = ConvertNonQuestionAction @ConvertActionParams
    if (![string]::IsNullOrEmpty($warn)) {
        $WarningStrings.AppendLine($warn) | Out-Null
    }
    if ($null -ne $DefaultQueueAgentGroup.TimeoutThreshold) {
        $RoundValueParams = @{
            InputTime   = $DefaultQueueAgentGroup.TimeoutThreshold
            MinimumTime = 45
            RoundTo     = 15
            MaximumTime = 2700
        }
        $CallQueueParams["TimeoutThreshold"] = RoundValue @RoundValueParams
    }
    $CommandText.AppendLine() | Out-Null

    if (![string]::IsNullOrEmpty($Workflow.CustomMusicOnHoldStoredLocation)) {
        $CommandText.AppendLine("# Importing Custom Hold Music audio file") | Out-Null
        AddFileImportScript -ApplicationId HuntGroup -StoredLocation $Workflow.CustomMusicOnHoldStoredLocation -FileName $Workflow.CustomMusicOnHoldFileName -CommandText $CommandText -WarningStrings $WarningStrings
        $CommandText.AppendLine() | Out-Null
        $CallQueueParams['MusicOnHoldAudioFileId'] = "`$(`$FileId.Id)"
    }
    else {
        $CallQueueParams['UseDefaultMusicOnHold'] = $true
    }

    # PresenceBasedRouting (off by default)
    # $CallQueueParams["PresenceBasedRouting"] = $true
    # ConferenceMode (off by default)
    # $CallQueueParams["ConferenceMode"] = $true

    # LanguageId handling for sharedvoicemail? we can set this regardless
    # OverflowSharedVoicemailAudioFilePrompt
    # 

    $CommandText.AppendLine("# Adding remaining queue configuration information") | Out-Null
    $CommandString = HashTableToDeclareString -Hashtable $CallQueueParams -VariableName "CallQueueParams"
    $CommandText.AppendLine($CommandString) | Out-Null

    $CommandText.AppendLine("# Creating the Call Queue") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`t`$CallQueue = New-CsCallQueue @CallQueueParams") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Error `"Unable to create call queue `$CQAccountName!`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Getting a valid UPN for the Call Queue Application Instance") | Out-Null
    $CommandText.AppendLine("`$CQUPN = `"CQ-`" + (`$CQAccountName.Trim() -replace '[^a-zA-Z0-9_\-]', '').ToLower()") | Out-Null
    $CommandText.AppendLine("`$CQUPN = `$CQUPN.Substring(0, [System.Math]::Min(20, `$CQUPN.Length)) + `"@$SipDomain`"") | Out-Null
    $CommandText.AppendLine("do {") | Out-Null
    $CommandText.AppendLine("`t`$UPNExist = try {") | Out-Null
    $CommandText.AppendLine("`t`t`$GetInst = Get-CsOnlineApplicationInstance -Identity `$CQUPN") | Out-Null
    if (!$GenerateAccountsOnline) {
        $CommandText.AppendLine("`t`t`$HybridEnd = Get-CsHybridApplicationEndpoint -Filter {UserPrincipalName -eq `"`$CQUPN`"}") | Out-Null
        $CommandText.AppendLine("`t`t`$GetInst = if (`$null -ne `$GetInst -or `$null -ne `$HybridEnd) {") | Out-Null
        $CommandText.AppendLine("`t`t`t`"exists`"") | Out-Null
        $CommandText.AppendLine("`t`t} else {") | Out-Null
        $CommandText.AppendLine("`t`t`t`$null") | Out-Null
        $CommandText.AppendLine("`t`t}") | Out-Null
    }
    $CommandText.AppendLine("`t`t`$GetInst") | Out-Null
    $CommandText.AppendLine("`t} catch {") | Out-Null
    $CommandText.AppendLine("`t`t`$null") | Out-Null
    $CommandText.AppendLine("`t}") | Out-Null
    $CommandText.AppendLine("`tif ([string]::IsNullOrEmpty(`$UPNExist)) {") | Out-Null
    $CommandText.AppendLine("`t`t`$valid = `$true") | Out-Null
    $CommandText.AppendLine("`t} else {") | Out-Null
    $CommandText.AppendLine("`t`t`$Random = -join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]`$_ })") | Out-Null
    $CommandText.AppendLine("`t`t`$CQUPN = `"CQ-`" + (`$CQAccountName.Trim() -replace '[^a-zA-Z0-9_\-]', '').ToLower()") | Out-Null
    $CommandText.AppendLine("`t`t`$CQUPN = `$CQUPN.Substring(0, [System.Math]::Min(16, `$CQUPN.Length)) + `$Random + `"@$SipDomain`"") | Out-Null
    $CommandText.AppendLine("`t}") | Out-Null
    $CommandText.AppendLine("} until (`$valid)") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Creating the Call Queue Application Instance") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    if ($GenerateAccountsOnline) {
        $CommandText.AppendLine("`t`$NewInstance = New-CsOnlineApplicationInstance -UserPrincipalName `$CQUPN -ApplicationId `"11cd3e2e-fccb-42ad-ad00-878b93575e07`" -DisplayName `"`$CQName`"") | Out-Null
        $CommandText.AppendLine("`t`$CQInstanceId = `$NewInstance.ObjectID") | Out-Null
        $CommandText.AppendLine("`t`$CQInstanceUpn = `$NewInstance.UserPrincipalName") | Out-Null
    }
    else {
        $CommandText.AppendLine("`t`$NewInstance = New-CsHybridApplicationEndpoint -DisplayName `"`$CQName`" -SipAddress `"sip:`$CQUPN`" -OU `"$ResourceOU`" -ApplicationId `"11cd3e2e-fccb-42ad-ad00-878b93575e07`"") | Out-Null
        $CommandText.AppendLine("`t`$CQInstanceId = [Guid]::new(`$NewInstance.Name).Guid") | Out-Null
        $CommandText.AppendLine("`t`$CQInstanceUpn = `$NewInstance.UserPrincipalName") | Out-Null
    }
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to create application instance/hybrid endpoint for `$CQName ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Getting a valid UPN for the Auto Attendant Application Instance") | Out-Null
    $CommandText.AppendLine("`$AAUPN = `"AA-`" + (`$AAAccountName.Trim() -replace '[^a-zA-Z0-9_\-]', '').ToLower()") | Out-Null
    $CommandText.AppendLine("`$AAUPN = `$AAUPN.Substring(0, [System.Math]::Min(20, `$AAUPN.Length)) + `"@$SipDomain`"") | Out-Null
    $CommandText.AppendLine("do {") | Out-Null
    $CommandText.AppendLine("`t`$UPNExist = try {") | Out-Null
    $CommandText.AppendLine("`t`t`$GetInst = Get-CsOnlineApplicationInstance -Identity `$AAUPN") | Out-Null
    if (!$GenerateAccountsOnline) {
        $CommandText.AppendLine("`t`t`$HybridEnd = Get-CsHybridApplicationEndpoint -Filter {UserPrincipalName -eq `"`$AAUPN`"}") | Out-Null
        $CommandText.AppendLine("`t`t`$GetInst = if (`$null -ne `$GetInst -or `$null -ne `$HybridEnd) {") | Out-Null
        $CommandText.AppendLine("`t`t`t`"exists`"") | Out-Null
        $CommandText.AppendLine("`t`t} else {") | Out-Null
        $CommandText.AppendLine("`t`t`t`$null") | Out-Null
        $CommandText.AppendLine("`t`t}") | Out-Null
    }
    $CommandText.AppendLine("`t`t`$GetInst") | Out-Null
    $CommandText.AppendLine("`t} catch {") | Out-Null
    $CommandText.AppendLine("`t`t`$null") | Out-Null
    $CommandText.AppendLine("`t}") | Out-Null
    $CommandText.AppendLine("`tif ([string]::IsNullOrEmpty(`$UPNExist)) {") | Out-Null
    $CommandText.AppendLine("`t`t`$valid = `$true") | Out-Null
    $CommandText.AppendLine("`t} else {") | Out-Null
    $CommandText.AppendLine("`t`t`$Random = -join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]`$_ })") | Out-Null
    $CommandText.AppendLine("`t`t`$AAUPN = `"AA-`" + (`$AAAccountName.Trim() -replace '[^a-zA-Z0-9_\-]', '').ToLower()") | Out-Null
    $CommandText.AppendLine("`t`t`$AAUPN = `$AAUPN.Substring(0, [System.Math]::Min(16, `$AAUPN.Length)) + `$Random + `"@$SipDomain`"") | Out-Null
    $CommandText.AppendLine("`t}") | Out-Null
    $CommandText.AppendLine("} until (`$valid)") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Creating the Auto Attendant Application Instance") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    if ($GenerateAccountsOnline) {
        $CommandText.AppendLine("`t`$NewInstance = New-CsOnlineApplicationInstance -UserPrincipalName `$AAUPN -ApplicationId `"ce933385-9390-45d1-9512-c8d228074e07`" -DisplayName `"`$AAName`"") | Out-Null
        $CommandText.AppendLine("`t`$AAInstanceId = `$NewInstance.ObjectID") | Out-Null
        $CommandText.AppendLine("`t`$AAInstanceUpn = `$NewInstance.UserPrincipalName") | Out-Null
    }
    else {
        $CommandText.AppendLine("`t`$NewInstance = New-CsHybridApplicationEndpoint -DisplayName `"`$AAName`" -SipAddress `"sip:`$AAUPN`" -OU `"$ResourceOU`" -ApplicationId `"ce933385-9390-45d1-9512-c8d228074e07`"") | Out-Null
        $CommandText.AppendLine("`t`$AAInstanceId = [Guid]::new(`$NewInstance.Name).Guid") | Out-Null
        $CommandText.AppendLine("`t`$AAInstanceUpn = `$NewInstance.UserPrincipalName") | Out-Null
    }
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to create application instance/hybrid endpoint for `$AAName ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    # Create both AA and CQ endpoints so we only have to wait once
    $CommandText.AppendLine("# Waiting the Call Queue and Auto Attendant Application Instances to replicate") | Out-Null
    $CommandText.AppendLine("do {") | Out-Null
    $CommandText.AppendLine("`t`$ExistsOnline = `$false") | Out-Null
    $CommandText.AppendLine("`t`$CQInstance = Get-CsOnlineApplicationInstance -Identity `$CQInstanceUpn") | Out-Null
    $CommandText.AppendLine("`t`$CQEndpoint = Get-CsOnlineApplicationEndpoint -Uri `$CQInstanceUpn") | Out-Null
    $CommandText.AppendLine("`t`$AAInstance = Get-CsOnlineApplicationInstance -Identity `$AAInstanceUpn") | Out-Null
    $CommandText.AppendLine("`t`$AAEndpoint = Get-CsOnlineApplicationEndpoint -Uri `$AAInstanceUpn") | Out-Null
    $CommandText.AppendLine("`tif(`$null -ne `$CQInstance -and `$null -ne `$CQEndpoint -and `$null -ne `$AAInstance -and `$null -ne `$AAEndpoint) {") | Out-Null
    $CommandText.AppendLine("`t`t`$ExistsOnline = `$true") | Out-Null
    $CommandText.AppendLine("`t}") | Out-Null
    $CommandText.AppendLine("} until (`$ExistsOnline)") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Creating Call Queue Application Instance Association") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`t`$CQAssoc = New-CsOnlineApplicationInstanceAssociation -ConfigurationType CallQueue -ConfigurationId `$(`$CallQueue.Identity) -Identities `$CQInstanceId") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to create application association for `$CQName ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Building the Auto Attendant") | Out-Null
    $CommandText.AppendLine() | Out-Null
    $CommandText.AppendLine("# Building the Auto Attendant Default Action") | Out-Null
    $CommandText.AppendLine("`$DefaultAction = New-CsAutoAttendantCallableEntity -Identity `$CQInstanceId -Type ApplicationEndpoint") | Out-Null
    $CommandText.AppendLine("`$DefaultMenuOption = New-CsAutoAttendantMenuOption -Action TransferCallToTarget -DtmfResponse Automatic -CallTarget `$DefaultAction") | Out-Null
    $CommandText.AppendLine("`$DefaultMenu = New-CsAutoAttendantMenu -Name `"Default Menu`" -MenuOptions @(`$DefaultMenuOption)") | Out-Null

    if (![string]::IsNullOrWhiteSpace($Workflow.DefaultActionPromptAudioFilePromptStoredLocation)) {
        AddFileImportScript -ApplicationId OrgAutoAttendant -StoredLocation $Workflow.DefaultActionPromptAudioFilePromptStoredLocation -FileName $Workflow.DefaultActionPromptAudioFilePromptOriginalFileName -CommandText $CommandText -WarningStrings $WarningStrings
        $CommandText.AppendLine("`$DefaultGreetingPrompt = New-CsAutoAttendantPrompt -AudioFilePrompt `$FileId") | Out-Null
        $CommandText.AppendLine("`$DefaultCallFlow = New-CsAutoAttendantCallFlow -Name `"Default Call Flow`" -Greetings @(`$DefaultGreetingPrompt) -Menu `$DefaultMenu") | Out-Null
    }
    elseif (![string]::IsNullOrWhiteSpace($Workflow.DefaultActionPromptTextToSpeechPrompt)) {
        $CommandText.AppendLine("`$DefaultGreetingPrompt = New-CsAutoAttendantPrompt -TextToSpeechPrompt `"$($Workflow.DefaultActionPromptTextToSpeechPrompt)`"") | Out-Null
        $CommandText.AppendLine("`$DefaultCallFlow = New-CsAutoAttendantCallFlow -Name `"Default Call Flow`" -Greetings @(`$DefaultGreetingPrompt) -Menu `$DefaultMenu") | Out-Null
    }
    else {
        $CommandText.AppendLine("`$DefaultCallFlow = New-CsAutoAttendantCallFlow -Name `"Default Call Flow`" -Menu `$DefaultMenu") | Out-Null
    }
    $CommandText.AppendLine() | Out-Null

    # Add logic for business hours here
    if ($null -ne $Workflow.BusinessHoursID) {
        $CommandText.AppendLine() | Out-Null
        $CommandText.AppendLine("# Building the Auto Attendant After Hours Action") | Out-Null
        $BusinessHours = @($HoursOfBusiness).Where( { $_.Identity.InstanceID.Guid -eq $Workflow.BusinessHoursID })[0]
        $HoursName = [regex]::Replace($BusinessHours.Name, '_?[A-Fa-f0-9]{8}(?:-?[A-Fa-f0-9]{4}){3}-?[A-Fa-f0-9]{12}$', '')
        $CommandText.AppendLine("`$AfterHoursSchedule = (Get-CsOnlineSchedule).Where({ `$_.Name -eq `"$HoursName`" })[0]") | Out-Null
        $CommandText.AppendLine("if (`$null -eq `$AfterHoursSchedule) {") | Out-Null
        $CommandText.AppendLine("`t`$OnlineScheduleParams = @{") | Out-Null
        $CommandText.AppendLine("`t`tName = `"$HoursName`"") | Out-Null
        $CommandText.AppendLine("`t`tWeeklyRecurrentSchedule = `$true") | Out-Null
        $CommandText.AppendLine("`t`tComplement = `$true") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null
        if (![string]::IsNullOrEmpty($BusinessHours.MondayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.MondayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['MondayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.MondayHours1 $BusinessHours.MondayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.TuesdayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.TuesdayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['TuesdayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.TuesdayHours1 $BusinessHours.TuesdayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.WednesdayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.WednesdayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['WednesdayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.WednesdayHours1 $BusinessHours.WednesdayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.ThursdayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.ThursdayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['ThursdayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.ThursdayHours1 $BusinessHours.ThursdayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.FridayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.FridayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['FridayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.FridayHours1 $BusinessHours.FridayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.SaturdayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.SaturdayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['SaturdayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.SaturdayHours1 $BusinessHours.SaturdayHours2)") | Out-Null
        }
        if (![string]::IsNullOrEmpty($BusinessHours.SundayHours1) -or ![string]::IsNullOrEmpty($BusinessHours.SundayHours2)) {
            $CommandText.AppendLine("`t`$OnlineScheduleParams['SundayHours'] = $(ConvertFrom-BusinessHoursToTimeRange $BusinessHours.SundayHours1 $BusinessHours.SundayHours2)") | Out-Null
        }
        $CommandText.AppendLine("`t`$AfterHoursSchedule = New-CsOnlineSchedule @OnlineScheduleParams") | Out-Null
        $CommandText.AppendLine("}") | Out-Null

        $CommandText.AppendLine("`$OptionParams = @{}") | Out-Null
        $ConvertActionParams = @{
            FlowName         = $DefaultQueue.Name
            URI              = $Workflow.NonBusinessHoursActionURI
            QueueId          = $DefaultQueue.NonBusinessHoursActionQueueID
            Action           = $DefaultQueue.NonBusinessHoursActionAction
            CommandText      = $CommandText
            CommandHashName  = "OptionParams"
            ActionName       = "Action"
            ActionTargetName = "CallTarget"
            AAMenuOption     = $true
        }
        $warn = ConvertNonQuestionAction @ConvertActionParams
        if (![string]::IsNullOrEmpty($warn)) {
            $WarningStrings.AppendLine($warn) | Out-Null
        }

        $CommandText.AppendLine("`$AutomaticMenuOption = New-CsAutoAttendantMenuOption -DtmfResponse Automatic @OptionParams") | Out-Null
        $CommandText.AppendLine("`$AfterHoursMenu = New-CsAutoAttendantMenu -Name `"After Hours Menu`" -MenuOptions @(`$AutomaticMenuOption)") | Out-Null
        if (![string]::IsNullOrWhiteSpace($Workflow.NonBusinessHoursActionPromptTextToSpeechPrompt)) {
            $CommandText.AppendLine("`$AfterHoursGreetingPrompt = New-CsAutoAttendantPrompt -TextToSpeechPrompt `"$($Workflow.NonBusinessHoursActionPromptTextToSpeechPrompt)`"") | Out-Null
            $CommandText.AppendLine("`$AfterHoursCallFlow = New-CsAutoAttendantCallFlow -Name `"After Hours Call Flow`" -Greetings @(`$AfterHoursGreetingPrompt) -Menu `$AfterHoursMenu") | Out-Null
        }
        elseif (![string]::IsNullOrEmpty($Workflow.NonBusinessHoursActionPromptAudioFilePromptStoredLocation)) {
            AddFileImportScript -ApplicationId OrgAutoAttendant -StoredLocation $Workflow.NonBusinessHoursActionPromptAudioFilePromptStoredLocation -FileName $Workflow.NonBusinessHoursActionPromptAudioFilePromptOriginalFileName -CommandText $CommandText -WarningStrings $WarningStrings
            $CommandText.AppendLine("`$AfterHoursGreetingPrompt = New-CsAutoAttendantPrompt -AudioFilePrompt `$FileId") | Out-Null
            $CommandText.AppendLine("`$AfterHoursCallFlow = New-CsAutoAttendantCallFlow -Name `"After Hours Call Flow`" -Greetings @(`$AfterHoursGreetingPrompt) -Menu `$AfterHoursMenu") | Out-Null
        }
        else {
            $CommandText.AppendLine("`$AfterHoursCallFlow = New-CsAutoAttendantCallFlow -Name `"After Hours Call Flow`" -Menu `$AfterHoursMenu") | Out-Null
        }
        
        $CommandText.AppendLine("`$AfterHoursCallHandlingAssociation = New-CsAutoAttendantCallHandlingAssociation -Type AfterHours -ScheduleId `$AfterHoursSchedule.Id -CallFlowId `$AfterHoursCallFlow.Id") | Out-Null
    }

    $c = 0
    foreach ($HolidayId in $Workflow.HolidayHoursIDs) {
        $c++
        if ($null -eq $HolidayId) {
            continue
        }
        $CommandText.AppendLine() | Out-Null
        $CommandText.AppendLine("# Building the Auto Attendant Holiday Hours Action $c") | Out-Null
        $HolidaySet = @($HolidaySets).Where( { $_.Identity.InstanceID.Guid -eq $HolidayId })[0]
        $HolidayName = [regex]::Replace($HolidaySet.Name, '_?[A-Fa-f0-9]{8}(?:-?[A-Fa-f0-9]{4}){3}-?[A-Fa-f0-9]{12}$', '')
        $CommandText.AppendLine("`$HolidaySchedule = (Get-CsOnlineSchedule).Where({ `$_.Name -eq `"$HolidayName`" })[0]") | Out-Null
        $CommandText.AppendLine("if (`$null -eq `$HolidaySchedule) {") | Out-Null
        $CommandText.AppendLine("`t`$OnlineScheduleParams = @{") | Out-Null
        $CommandText.AppendLine("`t`tName = `"$HolidayName`"") | Out-Null
        $CommandText.AppendLine("`t`tFixedSchedule = `$true") | Out-Null
        $CommandText.AppendLine("`t}") | Out-Null

        $CommandText.AppendLine("`t`$DateTimeRanges = @()") | Out-Null
        foreach ($HolidayRange in $HolidaySet.HolidayList) {
            $StartDate = $HolidayRange.StartDate.ToString('d/M/yyyy H:mm')
            $EndDate = $HolidayRange.EndDate.ToString('d/M/yyyy H:mm')
            $CommandText.AppendLine("`t`$dt = New-CsOnlineDateTimeRange -Start `"$StartDate`" -End `"$EndDate`"") | Out-Null
            $CommandText.AppendLine("`t`$DateTimeRanges += `$dt") | Out-Null
        }
        $CommandText.AppendLine("`t`$OnlineScheduleParams[`"DateTimeRanges`"] = `$DateTimeRanges") | Out-Null
        $CommandText.AppendLine("`t`$HolidaySchedule = New-CsOnlineSchedule @OnlineScheduleParams") | Out-Null
        $CommandText.AppendLine("}") | Out-Null

        $CommandText.AppendLine("`$OptionParams = @{}") | Out-Null
        $ConvertActionParams = @{
            FlowName         = $DefaultQueue.Name
            URI              = $Workflow.HolidayActionURI
            QueueId          = $DefaultQueue.HolidayActionQueueID
            Action           = $DefaultQueue.HolidayActionAction
            CommandText      = $CommandText
            CommandHashName  = "OptionParams"
            ActionName       = "Action"
            ActionTargetName = "CallTarget"
            AAMenuOption     = $true
        }
        $warn = ConvertNonQuestionAction @ConvertActionParams
        if (![string]::IsNullOrEmpty($warn)) {
            $WarningStrings.AppendLine($warn) | Out-Null
        }

        $CommandText.AppendLine("`$HolidayMenuOption = New-CsAutoAttendantMenuOption -DtmfResponse Automatic @OptionParams") | Out-Null
        $CommandText.AppendLine("`$HolidayMenu = New-CsAutoAttendantMenu -Name `"Holiday Menu`" -MenuOptions @(`$HolidayMenuOption)") | Out-Null
        if (![string]::IsNullOrEmpty($Workflow.HolidayActionPromptTextToSpeechPrompt)) {
            $CommandText.AppendLine("`$HolidayGreetingPrompt = New-CsAutoAttendantPrompt -TextToSpeechPrompt `"$($Workflow.HolidayActionPromptTextToSpeechPrompt)`"") | Out-Null
            $CommandText.AppendLine("`$HolidayCallFlow$c = New-CsAutoAttendantCallFlow -Name `"Holiday Call Flow $c`" -Greetings @(`$HolidayGreetingPrompt) -Menu `$HolidayMenu") | Out-Null
        }
        elseif (![string]::IsNullOrEmpty($Workflow.HolidayActionPromptAudioFilePromptStoredLocation)) {
            AddFileImportScript -ApplicationId OrgAutoAttendant -StoredLocation $Workflow.HolidayActionPromptAudioFilePromptStoredLocation -FileName $Workflow.HolidayActionPromptAudioFilePromptOriginalFileName -CommandText $CommandText -WarningStrings $WarningStrings
            $CommandText.AppendLine("`$HolidayGreetingPrompt = New-CsAutoAttendantPrompt -AudioFilePrompt `$FileId") | Out-Null
            $CommandText.AppendLine("`$HolidayCallFlow$c = New-CsAutoAttendantCallFlow -Name `"Holiday Call Flow $c`" -Greetings @(`$HolidayGreetingPrompt) -Menu `$HolidayMenu") | Out-Null
        }
        else {
            $CommandText.AppendLine("`$HolidayCallFlow$c = New-CsAutoAttendantCallFlow -Name `"Holiday Call Flow $c`" -Menu `$HolidayMenu") | Out-Null
        }
        
        $CommandText.AppendLine("`$HolidayCallHandlingAssociation$c = New-CsAutoAttendantCallHandlingAssociation -Type Holiday -ScheduleId `$HolidaySchedule.Id -CallFlowId `$HolidayCallFlow$c.Id") | Out-Null
    }

    $CommandText.AppendLine("# Creating the Auto Attendant") | Out-Null
    $CommandText.AppendLine("`$AAParams = @{") | Out-Null
    $CommandText.AppendLine("`tName            = `"`$AAName`"") | Out-Null
    $CommandText.AppendLine("`tDefaultCallFlow = `$DefaultCallFlow") | Out-Null
    $CommandText.AppendLine("`tLanguage        = `"$($Workflow.Language)`"") | Out-Null
    $CommandText.AppendLine("`tTimeZoneId      = `"$($Workflow.TimeZone)`"") | Out-Null
    $CommandText.AppendLine("}") | Out-Null

    if ($null -ne $Workflow.BusinessHoursID -or $null -ne $Workflow.HolidayHoursIDs) {
        $CommandText.AppendLine("`$CallFlows = @()") | Out-Null
        $CommandText.AppendLine("`$CallHandlingAssociations = @()") | Out-Null
        if ($null -ne $Workflow.BusinessHoursID) {
            $CommandText.AppendLine("`$CallFlows += `$AfterHoursCallFlow") | Out-Null
            $CommandText.AppendLine("`$CallHandlingAssociations += `$AfterHoursCallHandlingAssociation") | Out-Null
        }
        for ($i = 1; $i -le $Workflow.HolidayHoursIDs.Count; $i++) {
            if ($null -ne $Workflow.HolidayHoursIDs[($i - 1)]) {
                $CommandText.AppendLine("`$CallFlows += `$HolidayCallFlow$i") | Out-Null
                $CommandText.AppendLine("`$CallHandlingAssociations += `$HolidayCallHandlingAssociation$i") | Out-Null
            }
        }
        $CommandText.AppendLine("`$AAParams['CallFlows'] = `$CallFlows") | Out-Null
        $CommandText.AppendLine("`$AAParams['CallHandlingAssociations'] = `$CallHandlingAssociations") | Out-Null
    }
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`t`$AutoAttendant = New-CsAutoAttendant @AAParams") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to create new AA for `$AAName ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Creating Auto Attendant Application Instance Association") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`t`$AAAssoc = New-CsOnlineApplicationInstanceAssociation -ConfigurationType AutoAttendant -ConfigurationId `$(`$AutoAttendant.Identity) -Identities `$AAInstanceId") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to create application association for $($CallQueueParams['Name']) ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Assigning Usage Location to the created application instances") | Out-Null
    $CommandText.AppendLine("if (`$null -eq `$AAInstanceId -or `$null -eq `$CQInstanceId) {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Missing Instance ObjectIDs, cannot assign licenses, ending processing.`"") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`tGet-AzureADUser -ObjectId `$AAInstanceId | Set-AzureADUser -UsageLocation `"$UsageLocation`"") | Out-Null
    $CommandText.AppendLine("`tGet-AzureADUser -ObjectId `$CQInstanceId | Set-AzureADUser -UsageLocation `"$UsageLocation`"") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to set Usage Location for objects, ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null
    $CommandText.AppendLine("do {") | Out-Null
    $CommandText.AppendLine("`tStart-Sleep -Seconds 2") | Out-Null
    $CommandText.AppendLine("`t`$AALocation = (Get-CsOnlineUser -Identity `$AAInstanceId).UsageLocation") | Out-Null
    $CommandText.AppendLine("`t`$CQLocation = (Get-CsOnlineUser -Identity `$CQInstanceId).UsageLocation") | Out-Null
    $CommandText.AppendLine("} while ([string]::IsNullOrEmpty(`$AALocation) -or [string]::IsNullOrEmpty(`$CQLocation))") | Out-Null
    $CommandText.AppendLine() | Out-Null

    $CommandText.AppendLine("# Assigning the licenses to the Auto Attendant Instance") | Out-Null
    $CommandText.AppendLine("`$LicenseSkuId = `"440eaaa8-b3e0-484b-a8be-62870b9ba70a`" # this guid is the phone system virtual user by default") | Out-Null
    $CommandText.AppendLine("`$SkuFeaturesToEnable = @(`"TEAMS1`",`"MCOPSTN1`", `"MCOEV`", `"MCOEV_VIRTUALUSER`")") | Out-Null
    $CommandText.AppendLine("`$StandardLicense = (Get-AzureADSubscribedSku).Where({`$_.SkuId -eq `$LicenseSkuId})[0]") | Out-Null
    $CommandText.AppendLine("`$SkuFeaturesToDisable = `$StandardLicense.ServicePlans.Where({`$_.ServicePlanName -notin `$SkuFeaturesToEnable})") | Out-Null
    $CommandText.AppendLine("`$License = [Microsoft.Open.AzureAD.Model.AssignedLicense]::new()") | Out-Null
    $CommandText.AppendLine("`$License.SkuId = `$StandardLicense.SkuId") | Out-Null
    $CommandText.AppendLine("`$License.DisabledPlans = `$SkuFeaturesToDisable.ServicePlanId") | Out-Null
    $CommandText.AppendLine("`$LicensesToAssign = [Microsoft.Open.AzureAD.Model.AssignedLicenses]::new()") | Out-Null
    $CommandText.AppendLine("`$LicensesToAssign.AddLicenses = `$License") | Out-Null
    $CommandText.AppendLine("try {") | Out-Null
    $CommandText.AppendLine("`tSet-AzureADUserLicense -ObjectId `$AAInstanceId -AssignedLicenses `$LicensesToAssign") | Out-Null
    $CommandText.AppendLine("} catch {") | Out-Null
    $CommandText.AppendLine("`tWrite-Warning `"Unable to apply license plan to `$AAInstanceId, ending processing.`"") | Out-Null
    $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
    $CommandText.AppendLine("`texit") | Out-Null
    $CommandText.AppendLine("}") | Out-Null

    if (![string]::IsNullOrEmpty($LineURI)) {
        $LineURI = [regex]::Replace($LineURI, 'x', ';ext=')
        $CommandText.AppendLine() | Out-Null
        $CommandText.AppendLine("# Assigning the phone number Auto Attendant Instance") | Out-Null
        $CommandText.AppendLine("try {") | Out-Null
        if ($GenerateAccountsOnline) {
            $CommandText.AppendLine("`tSet-CsOnlineVoiceApplicationInstance -Identity `$AAInstanceId -TelephoneNumber `"+$LineUri`"") | Out-Null
        }
        else {
            $CommandText.AppendLine("`tSet-CsOnlineApplicationInstance -Identity `$AAInstanceId -OnpremPhoneNumber `"+$LineUri`"") | Out-Null
        }
        $CommandText.AppendLine("} catch {") | Out-Null
        $CommandText.AppendLine("`tWrite-Warning `"Unable to assign LineUri $LineUri to `$AAInstanceId, ending processing.`"") | Out-Null
        $CommandText.AppendLine("`tthrow `$_.Exception") | Out-Null
        $CommandText.AppendLine("`texit") | Out-Null
        $CommandText.AppendLine("}") | Out-Null
    }
    # Remove traling newline
    $CommandText.Remove($CommandText.Length - [Environment]::NewLine.Length, [Environment]::NewLine.Length) | Out-Null

    $Warnings = (($WarningStrings.ToString() -split [Environment]::NewLine) | ForEach-Object { if (![string]::IsNullOrWhiteSpace($_)) { "# $_" } }) -join [Environment]::NewLine
    if ($Warnings.Length -gt 0) {
        $Warnings = "# WARNINGS" + [Environment]::NewLine + $Warnings
        $Warnings += [Environment]::NewLine + [Environment]::NewLine
    }

    $Content = ($Warnings + $CommandText.ToString()) -replace "`t", "    "
    Set-Content -Path $FileName -Value $Content -Encoding UTF8
}