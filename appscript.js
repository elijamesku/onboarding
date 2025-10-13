// Apps Script: onFormSubmit handler for onboarding -> AWS API Gateway -> Lambda -> SQS

const SCRIPT_PROPS = PropertiesService.getScriptProperties();

function getConfig() {
  const apiKey = SCRIPT_PROPS.getProperty('API_KEY');
  const apiUrl = SCRIPT_PROPS.getProperty('API_GATEWAY_URL'); // e.g. https://...amazonaws.com/newuser
  if (!apiUrl) {
    throw new Error('Missing Script Property: API_GATEWAY_URL. Set it to your API Gateway endpoint + /newuser');
  }
  return { apiKey, apiUrl };
}

/**
 * Trigger function bound to Google Form submit
 * e is the event object provided by Apps Script (onFormSubmit)
 */
function onFormSubmit(e) {
  try {
    const values = (e.namedValues || {});
    const props = getConfig();

    const payload = {
      requestId: Utilities.getUuid(),
      givenName: values["Employee's Name"] ? values["Employee's Name"][0] : "",
      familyName: values["Employee's Family Name"] ? values["Employee's Family Name"][0] : "",
      displayName: values["Employee's Name"] ? values["Employee's Name"][0] : "",
      positionTemplate: values["Employee Job Title"] ? values["Employee Job Title"][0] : "TEMPLATE_DEFAULT",
      emailAlias: (values["Employee's LEAD Email Address"] ? values["Employee's LEAD Email Address"][0] : "").split("@")[0],
      requesterEmail: (e.values && e.values[0]) ? e.values[0] : Session.getActiveUser().getEmail(),
      startDate: values["Employee Start Date/Termination Date"] ? values["Employee Start Date/Termination Date"][0] : "",
      location: values["Employee Location"] ? values["Employee Location"][0] : "",
      workstation: values["Workstation Required"] ? values["Workstation Required"][0] : "",
      shippingAddress: values["Shipping Address"] ? values["Shipping Address"][0] : ""
    };

    const options = {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(payload),
      headers: {
        'x-api-key': props.apiKey || ''
      },
      muteHttpExceptions: true,
      timeout: 30000
    };

    const response = UrlFetchApp.fetch(props.apiUrl, options);
    const code = response.getResponseCode();
    const body = response.getContentText();

    // Logging for debugging - execution logs are visible in Apps Script Dashboard (Executions)
    Logger.log(`POST ${props.apiUrl} -> ${code}`);
    Logger.log(body);

    // Optionally write response back to Sheet (append or set in a column) - omitted by default
    return { status: code, body: body };
  } catch (err) {
    // Log error so you can inspect it in Executions
    console.error('onFormSubmit error:', err);
    throw err; // rethrow so Apps Script failure is visible in Executions
  }
}

/**
 * Test helper 
 * Call testPayload() from the editor to run
 */
function testPayload() {
  const fakeEvent = {
    namedValues: {
      "Employee's Name": ["Jane Doe"],
      "Employee's Family Name": ["Doe"],
      "Employee Job Title": ["TEMPLATE_ENGINEER"],
      "Employee's LEAD Email Address": ["jane.doe@lead.bank"],
      "Employee Start Date/Termination Date": ["2025-10-15"],
      "Employee Location": ["NYC"],
      "Workstation Required": ["Laptop"],
      "Shipping Address": ["123 Main St, NY"]
    },
    values: ["manager@example.com"]
  };

  const result = onFormSubmit(fakeEvent);
  Logger.log('testPayload result: %s', JSON.stringify(result));
}
