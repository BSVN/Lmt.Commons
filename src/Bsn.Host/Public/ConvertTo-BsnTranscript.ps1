<#
.SYNOPSIS
    Converts an asciicast (.cast) recording into a Start-Transcript-style
    text transcript.

.DESCRIPTION
    Renders the human-readable, auditor-facing artifact of a recording:
    a plain-text transcript that mimics the structure PowerShell's
    built-in Start-Transcript writes - a header block, everything the
    session wrote (echoed commands interleaved with output), and a
    footer. The .cast file stays the bit-exact, replayable evidence; the
    transcript is its readable rendering, produced purely from the cast
    timeline (the same Get-BsnCastTimeline parser every consumer shares;
    no console replay and no engine involvement).

    Rendering fidelity ('Strip' tier):

    Concatenates the output ('o') events in timeline order, strips
    CSI/OSC/VT escape sequences, and resolves carriage-return overtype
    and backspace. Line-oriented shell sessions convert cleanly because
    ConPTY/PTY echo puts the typed input into the output stream - exactly
    what Start-Transcript captures. Full-screen TUI applications (vim,
    htop, ...) redraw the screen with cursor addressing and produce
    columnar residue - documented limitation; replay the cast for those.

    Start-Transcript compatibility:

    The header carries the transcript wording, start time and the
    'Transcript started, output file is ...' line; the footer the
    'PowerShell transcript end' block. Fields Start-Transcript fills from
    the engine (Username, RunAs User, Machine, Process ID, PSVersion,
    PSEdition) are not recorded in a cast: they are written blank - real
    transcripts emit blank fields too - unless supplied via parameters.
    Host Application is derived from the cast header (command / env.SHELL)
    and can be overridden.

    -HeaderMode controls the frame:
    - Standard (default): Start-Transcript-like, unknown fields blank.
    - Bsn: audit-framed - adds session id, recorded-by version, terminal
      size, cast file path and the SHA-256 hash of the cast the transcript
      was rendered from (plus the exit code for v3 recordings), proving
      which evidence produced the text. The session id defaults to a
      deterministic value derived from the cast hash and can be supplied.

    Encoding: real Start-Transcript files are UTF-16LE on Windows
    PowerShell 5.1 and UTF-8 on PowerShell 7; the export standardizes on
    UTF-8 without BOM with CRLF line endings on every edition. -Encoding
    selects ASCII, UTF-8 (no BOM), Unicode/BigEndianUnicode/UTF-32 (with
    BOM) instead.

    Privacy note: echoed input in a recording contains whatever was typed,
    including secrets at prompts that do not suppress echo. The transcript
    inherits that property - handle the txt like the cast itself.
    -AnnotateCommands additionally reveals input recorded with
    -RecordInput: intended for sessions where echo is absent (password
    prompts, Read-Host -AsSecureString); on echoing sessions commands then
    appear twice.

.PARAMETER Path
    The asciicast v2 or v3 (.cast) file to convert. Accepts pipeline
    input (also by the FullName property, so Get-ChildItem output binds
    directly).

.PARAMETER OutPath
    Writes the transcript to this file instead of returning it on the
    pipeline. Accepts one cast at a time (a terminating error stops a
    pipeline that would overwrite the file repeatedly).

.PARAMETER HeaderMode
    Standard (default) renders a Start-Transcript-like frame; Bsn adds
    the audit extension fields (session id, recorded-by, terminal size,
    cast file, cast SHA-256, exit code).

.PARAMETER RenderMode
    Strip (default) is the line-oriented plain-text rendering described
    above. A full VT emulation tier (screen-buffer capture) may follow in
    a later release for TUI-heavy recordings.

.PARAMETER AnnotateCommands
    Inserts recorded input ('i') events into the transcript as
    'prefix typed-text' lines at their timeline position. Use for
    sessions recorded with -RecordInput where the input was NOT echoed
    (password prompts, hidden input); echoed sessions duplicate their
    commands.

.PARAMETER Encoding
    Output encoding: UTF8 (default, without BOM), ASCII, Unicode
    (UTF-16LE), BigEndianUnicode or UTF32. The Unicode variants carry a
    BOM; UTF8 deliberately does not.

.PARAMETER Username
    Fills the header Username field (blank by default).

.PARAMETER RunAsUser
    Fills the header RunAs User field (blank by default).

.PARAMETER Machine
    Fills the header Machine field (blank by default).

.PARAMETER HostApplication
    Overrides the header Host Application field. Derived from the cast
    header (command, else env.SHELL) when omitted.

.PARAMETER ProcessId
    Fills the header Process ID field (blank by default).

.PARAMETER PSVersion
    Fills the header PSVersion field (blank by default).

.PARAMETER Edition
    Fills the header PSEdition field (blank by default).

.PARAMETER SessionId
    Overrides the Bsn header session id. Derived from the cast hash
    ('bsn-' plus its first twelve hex characters) when omitted.

.INPUTS
    System.String
        The cast file path from the pipeline.

.OUTPUTS
    None
        When -OutPath is used.

    System.String
        The transcript text when no -OutPath is given (one string per
        cast, lines joined with CRLF).

.EXAMPLE
    ConvertTo-BsnTranscript session01.cast -OutPath session01.txt

    Writes the classic Start-Transcript-style txt file.

.EXAMPLE
    ConvertTo-BsnTranscript session01.cast | Set-Content audit\session01.txt

    Converts to the pipeline (no file side effect) and saves it.

.EXAMPLE
    Get-ChildItem .\audit -Filter *.cast | ConvertTo-BsnTranscript

    Converts every recording in a folder, emitting one transcript per
    cast on the pipeline.

.EXAMPLE
    ConvertTo-BsnTranscript session01.cast -HeaderMode Bsn -OutPath audit\session01.txt

    Writes the audit-framed transcript: session id, terminal size and the
    SHA-256 of the cast the text was rendered from are embedded in the
    header.

.EXAMPLE
    ConvertTo-BsnTranscript keyentry.cast -AnnotateCommands

    Adds the recorded keystrokes (i events) as typed-command lines - for
    recordings where the input was not echoed.

.EXAMPLE
    ConvertTo-BsnTranscript session01.cast -Username 'CONTOSO\jdoe' -Machine 'WS01' -ProcessId 12345 -PSVersion 7.4.0 -Edition Core

    Produces a fully populated Standard header (for example when a
    wrapper script knows the session context a cast cannot carry).

.NOTES
    The Start-Transcript wording follows PowerShell 7 ("PowerShell
    transcript start"/"end") on every edition, so identical casts convert
    to identical files regardless of the converting edition - the
    determinism auditors rely on.

.LINK
    https://github.com/BSVN/Lmt.Commons
#>
function ConvertTo-BsnTranscript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path,

        [string]$OutPath,

        [ValidateSet('Standard', 'Bsn')]
        [string]$HeaderMode = 'Standard',

        [ValidateSet('Strip')]
        [string]$RenderMode = 'Strip',

        [switch]$AnnotateCommands,

        [ValidateSet('UTF8', 'ASCII', 'Unicode', 'BigEndianUnicode', 'UTF32')]
        [string]$Encoding = 'UTF8',

        [string]$Username = '',

        [string]$RunAsUser = '',

        [string]$Machine = '',

        [string]$HostApplication = '',

        [string]$ProcessId = '',

        [string]$PSVersion = '',

        [string]$Edition = '',

        [string]$SessionId = ''
    )

    begin {
        # UTF8 is mapped to a BOM-less UTF8Encoding explicitly: real 5.1
        # transcripts are UTF-16LE and PS 7 transcripts UTF-8, and the
        # export standardizes on UTF-8 without BOM on every edition.
        $encodingObject = switch ($Encoding) {
            'ASCII' { [System.Text.Encoding]::ASCII }
            'Unicode' { [System.Text.Encoding]::Unicode }
            'BigEndianUnicode' { [System.Text.Encoding]::BigEndianUnicode }
            'UTF32' { [System.Text.Encoding]::UTF32 }
            default { [System.Text.UTF8Encoding]::new($false) }
        }
        $inputCount = 0
    }

    process {
        $inputCount++
        if (($inputCount -gt 1) -and $OutPath) {
            throw ('-OutPath converts a single cast file, but the pipeline supplied another one. Drop -OutPath to emit every transcript on the pipeline instead.')
        }

        # -RenderMode reserves the API surface: 'Strip' is the only implemented
        # rendering tier (a full VT emulation tier may follow for TUI casts);
        # the ValidateSet already restricts the value to 'Strip'.
        Write-Verbose -Message ('Rendering with render mode: {0}' -f $RenderMode)

        # Same pure parser every cast consumer shares - no re-parsing here.
        $timeline = Get-BsnCastTimeline -Path $Path
        $resolvedCastPath = (Resolve-Path -LiteralPath $Path).ProviderPath

        # Evidence chain: the header hash proves which cast the transcript
        # was rendered from (mirrors the cast_sha256 carried by the audit
        # records of the SIEM export).
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($resolvedCastPath))
        }
        finally {
            $sha256.Dispose()
        }
        $castHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()

        # --- cast header fields -------------------------------------------------
        # Every key except 'version' is optional; probe instead of referencing
        # so recorder-side metadata additions cannot break the conversion.
        $timestampValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'timestamp'
        $startEpoch = if ($null -ne $timestampValue) { [long]$timestampValue } else { 0 }
        $epochStart = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $startLocal = $epochStart.AddSeconds($startEpoch).ToLocalTime()

        $commandValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'command'
        $environmentValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'env'
        $headerShell = ''
        if ($null -ne $environmentValue) {
            $shellValue = Get-BsnObjectProperty -Object $environmentValue -Name 'SHELL'
            if ($null -ne $shellValue) {
                $headerShell = [string]$shellValue
            }
        }

        # Terminal size: v2 carries width/height, v3 a term object.
        $widthValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'width'
        $heightValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'height'
        $terminalSizeText = 'unknown'
        if (($null -ne $widthValue) -and ($null -ne $heightValue)) {
            $terminalSizeText = '{0}x{1}' -f $widthValue, $heightValue
        }
        else {
            $termValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'term'
            if ($null -ne $termValue) {
                $colsValue = Get-BsnObjectProperty -Object $termValue -Name 'cols'
                $rowsValue = Get-BsnObjectProperty -Object $termValue -Name 'rows'
                if (($null -ne $colsValue) -and ($null -ne $rowsValue)) {
                    $terminalSizeText = '{0}x{1}' -f $colsValue, $rowsValue
                }
            }
        }

        # --- render the body from the timeline ----------------------------------
        $bodyBuilder = [System.Text.StringBuilder]::new()
        $pendingInput = [System.Text.StringBuilder]::new()
        $lastOutputSeconds = 0.0
        $exitCode = $null

        foreach ($timelineEvent in $timeline.Events) {
            $eventType = [string]$timelineEvent[1]

            if ($eventType -eq 'o') {
                # Flush pending typed-input annotations at their timeline
                # position: the input happened just before this output.
                if ($pendingInput.Length -gt 0) {
                    [void]$bodyBuilder.Append($pendingInput.ToString())
                    [void]$pendingInput.Clear()
                }

                $lastOutputSeconds = [double]$timelineEvent[0]
                [void]$bodyBuilder.Append([string]$timelineEvent[2])
            }
            elseif ($eventType -eq 'i') {
                if (-not $AnnotateCommands) { continue }

                # Keystrokes arrive raw (arrow keys, control characters).
                # Escape sequences and controls are stripped; each CR/LF
                # starts a new annotated line.
                $inputText = Remove-BsnTerminalSequence -Text ([string]$timelineEvent[2])
                if (-not $inputText) { continue }

                $inputText = $inputText.Replace([char]13, [char]10)
                $inputText = [regex]::Replace($inputText, '[\x00-\x08\x0B-\x1F\x7F]', '')
                foreach ($inputSegment in $inputText.Split([char]10)) {
                    $trimmedSegment = $inputSegment.TrimEnd()
                    if ($trimmedSegment.Trim().Length -gt 0) {
                        [void]$pendingInput.Append('> ').Append($trimmedSegment).Append("`n")
                    }
                }
            }
            elseif ($eventType -eq 'x') {
                # v3 exit-status event: surfaced in the Bsn header frame.
                $exitCode = [string]$timelineEvent[2]
            }
        }

        if ($pendingInput.Length -gt 0) {
            [void]$bodyBuilder.Append($pendingInput.ToString())
            [void]$pendingInput.Clear()
        }

        $plainBody = ConvertTo-BsnPlainText -Text $bodyBuilder.ToString()
        $bodyLines = $plainBody.Split([char]10)

        # --- frame --------------------------------------------------------------
        $separator = '*' * 22
        $startTimeText = $startLocal.ToString('yyyyMMddHHmmss')
        $endTimeText = $startLocal.AddSeconds($lastOutputSeconds).ToString('yyyyMMddHHmmss')

        $hostApplicationText = $HostApplication
        if (-not $hostApplicationText) {
            $hostApplicationText = [string]$commandValue
        }
        if (-not $hostApplicationText) {
            $hostApplicationText = $headerShell
        }

        $sessionIdText = if ($SessionId) { $SessionId } else { 'bsn-' + $castHash.Substring(0, 12) }

        $owningModule = $MyInvocation.MyCommand.ScriptBlock.Module
        $recordedByText = 'Bsn.Host'
        if ($owningModule -and $owningModule.Version) {
            $recordedByText = 'Bsn.Host {0}' -f $owningModule.Version
        }

        $transcriptLines = [System.Collections.Generic.List[string]]::new()
        $transcriptLines.Add($separator)
        $transcriptLines.Add('PowerShell transcript start')
        $transcriptLines.Add('Start time: ' + $startTimeText)
        $transcriptLines.Add('Username: ' + $Username)
        $transcriptLines.Add('RunAs User: ' + $RunAsUser)
        $transcriptLines.Add('Machine: ' + $Machine)
        $transcriptLines.Add('Host Application: ' + $hostApplicationText)
        $transcriptLines.Add('Process ID: ' + $ProcessId)
        $transcriptLines.Add('PSVersion: ' + $PSVersion)
        $transcriptLines.Add('PSEdition: ' + $Edition)

        if ($HeaderMode -eq 'Bsn') {
            $transcriptLines.Add('Session Id: ' + $sessionIdText)
            $transcriptLines.Add('Recorded By: ' + $recordedByText)
            $transcriptLines.Add('Terminal Size: ' + $terminalSizeText)
            $transcriptLines.Add('Cast File: ' + $resolvedCastPath)
            $transcriptLines.Add('Cast SHA256: ' + $castHash)
            if ($null -ne $exitCode) {
                $transcriptLines.Add('Exit Code: ' + $exitCode)
            }
        }

        $transcriptLines.Add($separator)

        if ($OutPath) {
            $resolvedOutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
            $transcriptLines.Add('Transcript started, output file is ' + $resolvedOutPath)
            $transcriptLines.Add('')
        }

        foreach ($bodyLine in $bodyLines) {
            $transcriptLines.Add($bodyLine)
        }

        $transcriptLines.Add($separator)
        $transcriptLines.Add('PowerShell transcript end')
        $transcriptLines.Add('End time: ' + $endTimeText)
        $transcriptLines.Add($separator)

        $transcriptText = [string]::Join("`r`n", $transcriptLines)

        if ($OutPath) {
            $targetDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutPath)
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                throw ("The output directory '{0}' does not exist." -f $targetDirectory)
            }

            [System.IO.File]::WriteAllText($resolvedOutPath, $transcriptText + "`r`n", $encodingObject)
        }
        else {
            return $transcriptText
        }
    }
}
