@description('Name of the workbook resource (GUID format). Auto-generated if not provided.')
param workbookName string = newGuid()

@description('Display name shown in Azure Portal.')
param workbookDisplayName string = 'Cal Automation Logs Dashboard'

@description('Resource ID of the Application Insights component to query.')
param appInsightsResourceId string

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: workbookName
  location: resourceGroup().location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    sourceId: 'Azure Monitor'
    category: 'workbook'
    version: '1.0'
    serializedData: string({
      version: 'Notebook/1.0'
      items: [
        {
          type: 1
          content: {
            json: '# Cal Automation Logs Dashboard\nUse this workbook to monitor webhook processing, API failures, and per-booking traces.'
          }
          name: 'title'
        }
        {
          type: 3
          content: {
            version: 'KqlItem/1.0'
            queryType: 0
            resourceType: 'microsoft.insights/components'
            crossComponentResources: [
              appInsightsResourceId
            ]
            title: 'Recent Structured Events (24h)'
            query: 'traces | where timestamp > ago(24h) | where message has "event" | extend normalized = replace_string(replace_string(message, "INFORMATION: ", ""), "ERROR: ", "") | extend json = parse_json(normalized) | project timestamp, severityLevel, invocationId=tostring(json.invocationId), event=tostring(json.event), bookingUid=tostring(json.bookingUid), message | order by timestamp desc'
            visualization: 'table'
          }
          name: 'recent-events'
        }
        {
          type: 3
          content: {
            version: 'KqlItem/1.0'
            queryType: 0
            resourceType: 'microsoft.insights/components'
            crossComponentResources: [
              appInsightsResourceId
            ]
            title: 'Errors by Event (24h)'
            query: 'traces | where timestamp > ago(24h) | where severityLevel >= 3 | extend normalized = replace_string(replace_string(message, "ERROR: ", ""), "INFORMATION: ", "") | extend json = parse_json(normalized) | summarize errors=count() by event=tostring(json.event), httpStatus=tostring(json.httpStatus) | order by errors desc'
            visualization: 'barchart'
          }
          name: 'errors-by-event'
        }
        {
          type: 3
          content: {
            version: 'KqlItem/1.0'
            queryType: 0
            resourceType: 'microsoft.insights/components'
            crossComponentResources: [
              appInsightsResourceId
            ]
            title: 'Failure Details (24h)'
            query: 'traces | where timestamp > ago(24h) | where message has "GuestAddFailed" or severityLevel >= 3 | extend normalized = replace_string(replace_string(message, "ERROR: ", ""), "INFORMATION: ", "") | extend json = parse_json(normalized) | project timestamp, bookingUid=tostring(json.bookingUid), invocationId=tostring(json.invocationId), event=tostring(json.event), httpStatus=tostring(json.httpStatus), errorMessage=tostring(json.errorMessage), responseBody=tostring(json.responseBody) | order by timestamp desc'
            visualization: 'table'
          }
          name: 'failure-details'
        }
        {
          type: 3
          content: {
            version: 'KqlItem/1.0'
            queryType: 0
            resourceType: 'microsoft.insights/components'
            crossComponentResources: [
              appInsightsResourceId
            ]
            title: 'Events Grouped by Invocation (24h)'
            query: 'traces | where timestamp > ago(24h) | where message has "event" | extend normalized = replace_string(replace_string(message, "INFORMATION: ", ""), "ERROR: ", "") | extend json = parse_json(normalized) | summarize events=count(), firstSeen=min(timestamp), lastSeen=max(timestamp), sampleBooking=any(tostring(json.bookingUid)) by invocationId=tostring(json.invocationId) | order by lastSeen desc'
            visualization: 'table'
          }
          name: 'by-invocation'
        }
      ]
      fallbackResourceIds: [
        appInsightsResourceId
      ]
      isLocked: false
    })
  }
}

output workbookResourceId string = workbook.id
