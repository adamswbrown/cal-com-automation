@description('Resource ID of the Application Insights component to query.')
param appInsightsResourceId string

@description('Email address that receives fallback alerts.')
param alertEmailAddress string

@description('Prefix for the alert resources.')
param namePrefix string = 'cal-automation'

@description('Hours of silence before the dead-man switch fires. The reconciler runs hourly, so this absorbs two missed runs before alerting.')
param heartbeatWindowHours int = 3

// Fallback notification path.
//
// The Notion row plus comment is the primary alert, but it cannot report on
// Notion being unavailable, and it cannot report on the function not running at
// all -- which looks identical to everything being fine. These rules read
// Application Insights, which the functions write to before touching Notion, so
// they share no failure domain with the primary path.

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-alerts'
  location: 'global'
  properties: {
    groupShortName: 'calauto'
    enabled: true
    emailReceivers: [
      {
        name: 'owner'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// Tier 2: something failed loudly enough to log at Error.
resource errorAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-errors'
  location: resourceGroup().location
  properties: {
    displayName: 'Cal automation errors'
    description: 'Fires when the webhook or reconciler logs an error, including falling back to built-in guest rules.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    scopes: [appInsightsResourceId]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where severityLevel >= 3
    or message has "RulesFellBack"
    or message has "ReconcileFailed"
    or message has "GuestAddFailed"
| project timestamp, message
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// Tier 3: the dead-man switch.
//
// The only alert that catches total failure -- a broken deploy, a disabled
// timer, a stopped app. Silence from the other paths is indistinguishable from
// health, so this one alerts on the absence of a completed run rather than on
// the presence of an error.
resource heartbeatAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-reconciler-silent'
  location: resourceGroup().location
  properties: {
    displayName: 'Cal reconciler has not completed recently'
    description: 'Fires when no ReconcileCompleted event has been logged within the heartbeat window. The reconciler runs hourly.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT${heartbeatWindowHours}H'
    scopes: [appInsightsResourceId]
    criteria: {
      allOf: [
        {
          query: '''
traces
| where message has "ReconcileCompleted"
| summarize completedRuns = count()
| project completedRuns
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'completedRuns'
          operator: 'LessThanOrEqual'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

output actionGroupId string = actionGroup.id
output errorAlertId string = errorAlert.id
output heartbeatAlertId string = heartbeatAlert.id
