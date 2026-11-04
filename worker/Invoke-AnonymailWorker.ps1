<#
.SYNOPSIS
    Anonymail Exchange worker (Azure Automation runbook, Windows PowerShell 5.1).

.DESCRIPTION
    Started on demand by the Functions dispatcher ONLY when the exchange-ops queue has visible work.
    One job:
      * holds the single worker lock (concurrency = 1),
      * drains the queue in batches, connecting to Exchange Online at most once (lazily, only if
        a message was actually received),
      * groups operations per mailbox and applies them with one Set-Mailbox call where possible,
      * bounds itself by MaxRuntimeMinutes and MaxAttempts per operation,
      * keeps ONE inbox rule per (mailbox, destination folder) whose conditions list every live
        alias for that folder, so rule count grows with folders rather than aliases and stays
        inside the mailbox's inbox-rule quota. Rule problems never fail the alias operation.

    Aliases are plain secondary SMTP proxy addresses on the owner's mailbox, so mail delivery to
    existing aliases is handled natively by Exchange and does not depend on this service running.

    Identity: the Automation account's system-assigned managed identity, which needs
      * Exchange.ManageAsApp (Office 365 Exchange Online application permission), and
      * an Exchange role (scoped "Anonymail Worker" role group, or Exchange Recipient Administrator),
      * Storage Queue Data Message Processor + Storage Table Data Contributor on the storage account.
    See scripts/3-Grant-WorkerPermissions.ps1.
#>
param(
    [Parameter(Mandatory = $true)][string]$StorageAccountName,
    [Parameter(Mandatory = $true)][string]$Organization,
    [string]$QueueName = 'exchange-ops',
    [string]$LockJobId = '',
    [int]$MaxRuntimeMinutes = 5,
    [int]$MaxAttempts = 3,
    [int]$BatchSize = 32
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date
$script:ExoConnected = $false
$stats = @{ received = 0; succeeded = 0; failed = 0; retried = 0 }

# ------------------------------------------------------------------ managed identity + REST helpers
function Get-MiToken([string]$Resource) {
    $uri = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' }).access_token
}
$script:StorageToken = Get-MiToken 'https://storage.azure.com/'

$QueueBase = "https://$StorageAccountName.queue.core.windows.net/$QueueName/messages"
$TableBase = "https://$StorageAccountName.table.core.windows.net"

function Get-StorageHeaders([string]$Version) {
    @{ Authorization = "Bearer $script:StorageToken"; 'x-ms-version' = $Version; 'x-ms-date' = [DateTime]::UtcNow.ToString('R') }
}

function ConvertFrom-QueueXml($Resp) {
    # The queue service sends UTF-8 with a BOM and no charset, so Windows PowerShell's .Content decodes it
    # as Latin-1 ("ï»¿<?xml…"). Decode the raw bytes ourselves.
    $text = [Text.Encoding]::UTF8.GetString($Resp.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    [xml]$xml = $text
    @($xml.QueueMessagesList.QueueMessage | Where-Object { $_ })
}

function Receive-QueueBatch {
    # 300 s visibility: a message we fail to finish reappears for a later attempt.
    $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Headers (Get-StorageHeaders '2023-11-03') `
        -Uri "${QueueBase}?numofmessages=$BatchSize&visibilitytimeout=300"
    ConvertFrom-QueueXml $resp
}

function Test-QueueHasVisible {
    $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Headers (Get-StorageHeaders '2023-11-03') `
        -Uri "${QueueBase}?peekonly=true&numofmessages=1"
    @(ConvertFrom-QueueXml $resp).Count -gt 0
}

function Remove-QueueMessage($Msg) {
    $pop = [uri]::EscapeDataString($Msg.PopReceipt)
    Invoke-RestMethod -Method Delete -Headers (Get-StorageHeaders '2023-11-03') -Uri "${QueueBase}/$($Msg.MessageId)?popreceipt=$pop" | Out-Null
}

function Get-EntityUri([string]$Table, [string]$Pk, [string]$Rk) {
    $e = { param($k) [uri]::EscapeDataString($k.Replace("'", "''")) }
    "$TableBase/$Table(PartitionKey='$(& $e $Pk)',RowKey='$(& $e $Rk)')"
}

function Get-TableHeaders {
    $h = Get-StorageHeaders '2020-12-06'
    $h['Accept'] = 'application/json;odata=nometadata'
    $h['DataServiceVersion'] = '3.0;NetFx'
    $h
}

# Merge = update existing (If-Match *); -Upsert = insert-or-merge; -ETag = conditional.
function Set-Entity([string]$Table, [string]$Pk, [string]$Rk, [hashtable]$Props, [switch]$Upsert, [string]$ETag) {
    $h = Get-TableHeaders
    if ($ETag) { $h['If-Match'] = $ETag } elseif (-not $Upsert) { $h['If-Match'] = '*' }
    $body = $Props | ConvertTo-Json -Compress
    Invoke-WebRequest -UseBasicParsing -Method Merge -Uri (Get-EntityUri $Table $Pk $Rk) -Headers $h `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
}

function Get-Entity([string]$Table, [string]$Pk, [string]$Rk) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri (Get-EntityUri $Table $Pk $Rk) -Headers (Get-TableHeaders)
        $obj = $r.Content | ConvertFrom-Json
        $obj | Add-Member -NotePropertyName '__etag' -NotePropertyValue $r.Headers['ETag'] -PassThru
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

# Returns every entity matching an OData filter, following continuation tokens.
function Get-Entities([string]$Table, [string]$Filter, [string]$Select) {
    $base = "$TableBase/$Table()?`$filter=$([uri]::EscapeDataString($Filter))"
    if ($Select) { $base += "&`$select=$Select" }
    $rows = @(); $next = ''
    do {
        $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri "$base$next" -Headers (Get-TableHeaders)
        $rows += @(($r.Content | ConvertFrom-Json).value)
        $npk = $r.Headers['x-ms-continuation-NextPartitionKey']
        $nrk = $r.Headers['x-ms-continuation-NextRowKey']
        $next = if ($npk) { "&NextPartitionKey=$([uri]::EscapeDataString("$npk"))&NextRowKey=$([uri]::EscapeDataString("$nrk"))" } else { '' }
    } while ($next)
    $rows
}

function Remove-Entity([string]$Table, [string]$Pk, [string]$Rk) {
    $h = Get-TableHeaders; $h['If-Match'] = '*'
    try { Invoke-WebRequest -UseBasicParsing -Method Delete -Uri (Get-EntityUri $Table $Pk $Rk) -Headers $h | Out-Null } catch { }
}

function Now { [DateTime]::UtcNow.ToString('o') }

function Write-Audit([string]$Action, [string]$Target, [string]$Outcome, [string]$Detail) {
    $d = [DateTime]::UtcNow
    $rk = '{0:D16}-{1}' -f ([int64](8640000000000000 - [DateTimeOffset]::new($d).ToUnixTimeMilliseconds())), ([guid]::NewGuid().ToString().Substring(0, 8))
    $props = @{ at = (Now); actor = 'system:worker'; action = $Action; target = $Target; outcome = $Outcome }
    if ($Detail) { $props.detail = $Detail.Substring(0, [Math]::Min(1024, $Detail.Length)) }
    try { Set-Entity 'audit' $d.ToString('yyyyMM') $rk $props -Upsert } catch { Write-Warning "Audit write failed: $_" }
}

# ------------------------------------------------------------------ worker lock (concurrency = 1)
function Set-Lock([string]$Status) {
    Set-Entity 'state' 'worker' 'lock' @{ status = $Status; jobId = $LockJobId; updatedAt = (Now) } -Upsert
}

function Request-Lock {
    # Re-acquire only if nobody else has started a job since we released it.
    $lock = Get-Entity 'state' 'worker' 'lock'
    if ($lock -and $lock.status -ne 'Idle') { return $false }
    try {
        if ($lock) { Set-Entity 'state' 'worker' 'lock' @{ status = 'Running'; jobId = $LockJobId; updatedAt = (Now) } -ETag $lock.__etag }
        else { Set-Lock 'Running' }
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------------ Exchange
function Connect-Exo {
    if ($script:ExoConnected) { return }
    Import-Module ExchangeOnlineManagement
    Connect-ExchangeOnline -ManagedIdentity -Organization $Organization -ShowBanner:$false `
        -CommandName 'Get-Recipient', 'Set-Mailbox', 'Get-InboxRule', 'New-InboxRule', 'Set-InboxRule', 'Remove-InboxRule' | Out-Null
    $script:ExoConnected = $true
}

function Test-AddressInUse([string]$Address) {
    try {
        $null = Get-Recipient -Identity $Address -ErrorAction Stop
        return $true
    } catch {
        if ("$_" -match "couldn't be found|could not be found|not found") { return $false }
        throw # transient: let the caller retry
    }
}

# ------------------------------------------------------------------ folder rules (one per folder)
# Aliases whose address is still on the mailbox, so their mail still needs sorting.
$RuleLiveStatuses = @('Active', 'Removing', 'RemoveFailed')

# Brings the folder's rule in line with $Desired (sorted, lower-case addresses). Returns the
# ruleStatus to record on the folder's aliases.
function Sync-FolderRule([string]$UserId, $Mbx, [string]$Key, [string]$Path, [string[]]$Desired, [bool]$NewAlias) {
    $state = Get-Entity 'inboxrules' $UserId $Key
    $rules = @(Get-InboxRule -Mailbox $UserId -ErrorAction Stop)
    $rule = $null
    if ($state) { $rule = $rules | Where-Object { "$($_.RuleIdentity)" -eq "$($state.ruleIdentity)" } | Select-Object -First 1 }

    if ($Desired.Count -eq 0) {
        # Last alias for this folder has gone: remove the rule rather than leave it behind.
        if ($rule) { Remove-InboxRule -Mailbox $UserId -Identity "$($rule.RuleIdentity)" -Confirm:$false -ErrorAction Stop }
        if ($state) { Remove-Entity 'inboxrules' $UserId $Key }
        return 'Applied'
    }
    if ($rule) {
        $current = @($rule.HeaderContainsWords | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object)
        if (($current -join ',') -ne ($Desired -join ',')) {
            Set-InboxRule -Mailbox $UserId -Identity "$($rule.RuleIdentity)" -HeaderContainsWords $Desired -Force -ErrorAction Stop
        }
        return 'Applied'
    }
    # We created a rule before and it's gone: the user deleted it in Outlook. Respect that until
    # they create another alias for this folder, which is a fresh request to sort mail there.
    if ($state -and -not $NewAlias) { return 'Missing' }

    $leaf = ($Path -split '\\')[-1] # -split takes a regex: this splits on a single backslash
    $base = "Anonymail - Move to $leaf"
    $name = $base; $n = 2
    $names = @($rules | ForEach-Object { "$($_.Name)" })
    while ($names -contains $name) { $name = "$base ($n)"; $n++ }
    $new = New-InboxRule -Mailbox $UserId -Name $name -HeaderContainsWords $Desired `
        -MoveToFolder "$($Mbx.PrimarySmtpAddress):\$Path" -Force -ErrorAction Stop
    Set-Entity 'inboxrules' $UserId $Key @{ ruleIdentity = "$($new.RuleIdentity)"; ruleName = $name; folderPath = $Path; createdAt = (Now) } -Upsert
    Write-Audit 'rule.create' $Path 'succeeded' $name
    'Applied'
}

# Re-syncs the rule of every folder touched by this batch from the aliases table (the source of
# truth), so retries and partial failures converge instead of drifting.
function Sync-FolderRules([string]$UserId, $Mbx, [object[]]$Items) {
    $rows = @(Get-Entities 'aliases' "PartitionKey eq '$($UserId.Replace("'", "''"))'" 'RowKey,status,folderPath,folderKey,ruleStatus,ruleError')
    $byAddress = @{}
    foreach ($r in $rows) { $byAddress[$r.RowKey] = $r }
    $touched = @{} # folderKey -> whether a newly activated alias targets it
    foreach ($i in $Items) {
        $row = $byAddress[$i.Op.address.ToLowerInvariant()]
        if (-not $row -or -not $row.folderKey) { continue }
        $isNew = $i.Op.type -eq 'add' -and $row.status -eq 'Active'
        $touched[$row.folderKey] = [bool]$touched[$row.folderKey] -or $isNew
    }
    foreach ($key in @($touched.Keys)) {
        $members = @($rows | Where-Object { $_.folderKey -eq $key })
        $live = @($members | Where-Object { $RuleLiveStatuses -contains $_.status })
        $desired = [string[]]@($live | ForEach-Object { "$($_.RowKey)".ToLowerInvariant() } | Sort-Object)
        $path = "$(($members | Select-Object -First 1).folderPath)"
        try {
            $result = Sync-FolderRule $UserId $Mbx $key $path $desired $touched[$key]
            $outcome = if ($result -eq 'Missing') {
                @{ ruleStatus = 'Missing'; ruleError = 'The folder rule was deleted in Outlook, so mail stays in the Inbox.' }
            } else { @{ ruleStatus = 'Applied'; ruleError = '' } }
        } catch {
            $msg = "Folder rule failed: $_"
            $outcome = @{ ruleStatus = 'Failed'; ruleError = $msg.Substring(0, [Math]::Min(512, $msg.Length)) }
            Write-Audit 'rule.sync' $path 'failed' "$_"
        }
        foreach ($m in $live) {
            if ("$($m.ruleStatus)" -ne $outcome.ruleStatus -or "$($m.ruleError)" -ne $outcome.ruleError) {
                try { Set-Entity 'aliases' $UserId $m.RowKey $outcome } catch { Write-Warning "Rule status write failed for $($m.RowKey): $_" }
            }
        }
    }
}

# ------------------------------------------------------------------ operation outcome
function Complete-Op($Item) {
    $op = $Item.Op
    Set-Entity 'operations' $op.userId $op.opId @{ status = 'Succeeded'; completedAt = (Now); attempts = [int]$Item.Msg.DequeueCount }
    if ($op.type -eq 'add') {
        Set-Entity 'aliases' $op.userId $op.address @{ status = 'Active'; activatedAt = (Now); lastError = '' }
    } else {
        # The aliasindex reservation is kept on purpose: removed addresses are never re-issued.
        Set-Entity 'aliases' $op.userId $op.address @{ status = 'Removed'; removedAt = (Now) }
    }
    Remove-QueueMessage $Item.Msg
    Write-Audit "alias.$($op.type)" $op.address 'succeeded' $op.reason
    $stats.succeeded++
}

function Fail-Op($Item, [string]$Reason, [switch]$Permanent) {
    $op = $Item.Op
    $attempts = [int]$Item.Msg.DequeueCount
    if (-not $Permanent -and $attempts -lt $MaxAttempts) {
        # Leave the message invisible; it reappears after the visibility timeout for another attempt.
        Set-Entity 'operations' $op.userId $op.opId @{ status = 'Retrying'; attempts = $attempts; error = $Reason }
        $stats.retried++
        return
    }
    Set-Entity 'operations' $op.userId $op.opId @{ status = 'Failed'; attempts = $attempts; error = $Reason; completedAt = (Now) }
    if ($op.type -eq 'add') {
        Set-Entity 'aliases' $op.userId $op.address @{ status = 'Failed'; lastError = $Reason }
        $local, $domain = $op.address.Split('@')
        Remove-Entity 'aliasindex' $domain $local # never reached Exchange: release the reservation
    } else {
        Set-Entity 'aliases' $op.userId $op.address @{ status = 'RemoveFailed'; lastError = $Reason }
    }
    Remove-QueueMessage $Item.Msg
    Write-Audit "alias.$($op.type)" $op.address 'failed' $Reason
    $stats.failed++
}

# ------------------------------------------------------------------ batch processing
function Invoke-MailboxBatch([string]$UserId, [object[]]$Items) {
    try {
        $mbx = Get-EXOMailbox -Identity $UserId -Properties EmailAddresses, RecipientTypeDetails, ExternalDirectoryObjectId, PrimarySmtpAddress -ErrorAction Stop
    } catch {
        if ("$_" -match "couldn't be found|could not be found|not found") {
            foreach ($i in $Items) { Fail-Op $i 'Mailbox not found' -Permanent }
        } else {
            foreach ($i in $Items) { Fail-Op $i "Mailbox lookup failed: $_" }
        }
        return
    }
    # Ownership defence: the mailbox must be the caller's own user mailbox.
    if ($mbx.RecipientTypeDetails -ne 'UserMailbox' -or $mbx.ExternalDirectoryObjectId -ne $UserId) {
        foreach ($i in $Items) { Fail-Op $i 'Not an eligible user mailbox' -Permanent }
        return
    }
    Set-Entity 'mailboxes' 'mbx' $UserId @{ exchangeVerifiedAt = (Now); primarySmtp = "$($mbx.PrimarySmtpAddress)".ToLowerInvariant() } -Upsert

    $existing = @($mbx.EmailAddresses | ForEach-Object { "$_".ToLowerInvariant() })
    $pending = @()
    foreach ($i in $Items) {
        $addr = $i.Op.address.ToLowerInvariant()
        $proxy = "smtp:$addr"
        if ($i.Op.type -eq 'add') {
            if ($existing -contains $proxy) { Complete-Op $i; continue } # idempotent retry
            try { $inUse = Test-AddressInUse $addr } catch { Fail-Op $i "Recipient check failed: $_"; continue }
            if ($inUse) { Fail-Op $i 'Address already in use in the organisation' -Permanent; continue }
        } else {
            if ($addr -eq "$($mbx.PrimarySmtpAddress)".ToLowerInvariant()) { Fail-Op $i 'Refusing to remove a primary address' -Permanent; continue }
            if ($existing -notcontains $proxy) { Complete-Op $i; continue } # already gone
        }
        $i | Add-Member -NotePropertyName Proxy -NotePropertyValue $proxy
        $pending += $i
    }
    if ($pending.Count -gt 0) { Set-MailboxAliases $UserId $pending }

    # After the operations have settled, so the aliases table reflects what's on the mailbox.
    try { Sync-FolderRules $UserId $mbx $Items } catch { Write-Warning "Folder rules skipped for ${UserId}: $_" }
}

function Set-MailboxAliases([string]$UserId, [object[]]$pending) {
    $adds = @($pending | Where-Object { $_.Op.type -eq 'add' } | ForEach-Object { $_.Proxy })
    $removes = @($pending | Where-Object { $_.Op.type -eq 'remove' } | ForEach-Object { $_.Proxy })
    try {
        $change = @{}
        if ($adds.Count) { $change.Add = $adds }
        if ($removes.Count) { $change.Remove = $removes }
        Set-Mailbox -Identity $UserId -EmailAddresses $change -ErrorAction Stop
        foreach ($i in $pending) { Complete-Op $i }
    } catch {
        # Isolate the failing operation(s) instead of failing the whole batch.
        foreach ($i in $pending) {
            $key = if ($i.Op.type -eq 'add') { 'Add' } else { 'Remove' }
            try {
                Set-Mailbox -Identity $UserId -EmailAddresses @{ $key = $i.Proxy } -ErrorAction Stop
                Complete-Op $i
            } catch { Fail-Op $i "Set-Mailbox failed: $_" }
        }
    }
}

# ------------------------------------------------------------------ main loop
try {
    Set-Lock 'Running'
    while (((Get-Date) - $started).TotalMinutes -lt $MaxRuntimeMinutes) {
        $messages = @(Receive-QueueBatch)
        if ($messages.Count -eq 0) {
            # Release, then re-check once to close the race with a message enqueued just now.
            Set-Lock 'Idle'
            if ((Test-QueueHasVisible) -and (Request-Lock)) { continue }
            break
        }
        Set-Lock 'Running' # heartbeat
        $stats.received += $messages.Count

        $items = @()
        foreach ($m in $messages) {
            try {
                $op = $m.MessageText | ConvertFrom-Json
                if (-not ($op.opId -and $op.userId -and $op.address -and $op.type -in @('add', 'remove'))) { throw 'missing fields' }
                $items += [pscustomobject]@{ Msg = $m; Op = $op }
            } catch {
                Write-Audit 'queue.poison' $m.MessageId 'failed' "Unreadable message removed: $_"
                Remove-QueueMessage $m
            }
        }
        if ($items.Count -eq 0) { continue }

        Connect-Exo
        foreach ($g in ($items | Group-Object { $_.Op.userId })) {
            Invoke-MailboxBatch $g.Name @($g.Group)
        }
    }
} finally {
    try { Set-Lock 'Idle' } catch { }
    if ($script:ExoConnected) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    $secs = [int]((Get-Date) - $started).TotalSeconds
    Write-Audit 'worker.run' $LockJobId 'succeeded' ("received={0} succeeded={1} failed={2} retried={3} seconds={4}" -f $stats.received, $stats.succeeded, $stats.failed, $stats.retried, $secs)
    Write-Output ("Anonymail worker done: {0} received, {1} succeeded, {2} failed, {3} retrying, {4}s" -f $stats.received, $stats.succeeded, $stats.failed, $stats.retried, $secs)
}
