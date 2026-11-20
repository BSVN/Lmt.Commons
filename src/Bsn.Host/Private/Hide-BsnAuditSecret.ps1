<#
.SYNOPSIS
    Masks secret-looking values in recorded input text.

.DESCRIPTION
    Pure helper (no console interaction) used by the audit export
    (Export-BsnAuditLog / ConvertTo-BsnAuditRecord). Applies a heuristic
    that replaces the value of key-like words commonly carrying secrets
    (password, token, api key, authorization, credential, ...) with '***'
    while keeping the key itself, so SIEM events remain searchable by
    field name without leaking the value.

    THIS IS A HEURISTIC AND NEVER A GUARANTEE: secrets typed at hidden
    prompts (password: prompts, Read-Host -AsSecureString, sudo) carry no
    key-like marker in the recorded input and cannot be detected. The
    full-fidelity evidence always remains the cast file itself, which the
    audit log deliberately never carries.
#>
function Hide-BsnAuditSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $pattern = '(?i)((password|passwd|passphrase|pwd|token|secret|api[-_]?key|authorization|credential)s?\s*[:=]\s*)(\S+)'
    return [regex]::Replace($Text, $pattern, '$1***')
}
