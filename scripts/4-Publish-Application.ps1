<#
.SYNOPSIS  Builds and publishes the API, the Exchange worker runbook and the web frontend.
#>
param([string]$ConfigPath, [switch]$SkipApi, [switch]$SkipWorker, [switch]$SkipWeb)
. "$PSScriptRoot/_common.ps1"
$cfg = if ($ConfigPath) { Get-DeployConfig $ConfigPath } else { Get-DeployConfig }
$state = Get-DeployState
if (-not $state.functionAppName) { throw 'Run 2-Deploy-Infrastructure.ps1 first.' }
Use-Subscription $cfg
$rg = $cfg.ResourceGroup

if (-not $SkipApi) {
    Write-Step "API -> $($state.functionAppName)"
    Push-Location (Join-Path $RepoRoot 'api')
    try {
        npm ci --no-audit --no-fund; if ($LASTEXITCODE) { throw 'npm ci failed' }
        npm run build; if ($LASTEXITCODE) { throw 'build failed' }
        npm test; if ($LASTEXITCODE) { throw 'tests failed' }
        # Language is explicit because local.settings.json (git-ignored) is normally absent; the
        # TypeScript is already compiled to dist/ above.
        func azure functionapp publish $state.functionAppName --javascript; if ($LASTEXITCODE) { throw 'publish failed' }
    } finally { Pop-Location }
    Write-Ok 'API published'
}

if (-not $SkipWorker) {
    Write-Step "Worker runbook -> $($state.automationAccountName)/$($state.runbookName)"
    Invoke-Az extension add --name automation --upgrade --yes | Out-Null
    $runbook = Join-Path $RepoRoot 'worker/Invoke-AnonymailWorker.ps1'
    Invoke-Az automation runbook replace-content -g $rg --automation-account-name $state.automationAccountName `
        --name $state.runbookName --content "@$runbook" | Out-Null
    Invoke-Az automation runbook publish -g $rg --automation-account-name $state.automationAccountName --name $state.runbookName | Out-Null
    Write-Ok 'Runbook published'
}

if (-not $SkipWeb) {
    Write-Step "Web -> $($state.staticWebAppName)"
    Push-Location (Join-Path $RepoRoot 'web')
    try {
        npm ci --no-audit --no-fund; if ($LASTEXITCODE) { throw 'npm ci failed' }
        npm run build; if ($LASTEXITCODE) { throw 'build failed' }
        @{
            tenantId   = $cfg.TenantId
            clientId   = $state.appId
            apiBaseUrl = "https://$($state.functionAppHostname)/api"
            apiScope   = "api://$($state.appId)/Aliases.Manage"
        } | ConvertTo-Json | Set-Content 'dist/config.json' -Encoding utf8
        $token = Invoke-Az staticwebapp secrets list --name $state.staticWebAppName -g $rg --query properties.apiKey -o tsv
        npx --yes @azure/static-web-apps-cli@2 deploy ./dist --deployment-token $token --env production
        if ($LASTEXITCODE) { throw 'SWA deploy failed' }
    } finally { Pop-Location }
    Write-Ok "Web published: https://$($state.staticWebAppHostname)"
}
