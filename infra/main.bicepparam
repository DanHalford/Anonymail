using './main.bicep'

// Example values — scripts/2-Deploy-Infrastructure.ps1 passes real values from scripts/deploy.config.psd1.
param apiClientId = '00000000-0000-0000-0000-000000000000'
param exchangeOrganization = 'contoso.onmicrosoft.com'
param aliasDomains = 'alias.contoso.com'
param eligibleGroupIds = ''
param budgetContactEmails = [ 'it-admin@contoso.com' ]
