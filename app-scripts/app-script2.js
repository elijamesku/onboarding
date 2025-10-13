/*******************************
 * Apps Script: onFormSubmit handler
 * - Reads template mapping from a Google Sheet ("Templates")
 * - Builds payload with on-prem groups (memberOf) and cloud groups
 * - Optionally appends a row to a Google Sheet "NewHires" for visibility
 *******************************/

const SCRIPT_PROPS = PropertiesService.getScriptProperties();

/**
 * Required Script Properties:
 * API_KEY                >>>>> API key for Lambda/API Gateway
 * API_GATEWAY_URL        >>>>> full invoke URL (include /$default/newuser if needed)
 * TEMPLATE_SHEET_ID      >>>>> Google Sheet ID that contains the Templates sheet
 * OPTIONAL_NEWHIRES_SHEET_ID (optional) >>>>> Google Sheet ID where we append visible NewHires rows (if set)
 *
 * Templates sheet layout (sheet name = "Templates"):
 * Header row (A1:D1): TemplateTitle | OnPremTemplateId | CloudTemplateUPN | OnPremGroups | CloudGroups
 * OnPremGroups and CloudGroups are comma-separated lists of group names (or CNs as preferred)
 */

function getConfig() {
  const apiKey = SCRIPT_PROPS.getProperty('API_KEY');
  const apiUrl = SCRIPT_PROPS.getProperty('API_GATEWAY_URL');
  const templateSheetId = SCRIPT_PROPS.getProperty('TEMPLATE_SHEET_ID');
  const newHiresSheetId = SCRIPT_PROPS.getProperty('OPTIONAL_NEWHIRES_SHEET_ID'); // optional

  if (!apiUrl) throw new Error('Missing Script Property: API_GATEWAY_URL.');
  if (!templateSheetId) throw new Error('Missing Script Property: TEMPLATE_SHEET_ID. Create a Google Sheet with name "Templates".');

  return { apiKey, apiUrl, templateSheetId, newHiresSheetId };
}

/**
 * Read template mapping from Google Sheet.
 * Returns { onPremId, cloudUPN, onPremGroups:[], cloudGroups:[] }
 */
function getTemplateInfo(jobTitle) {
  const cfg = getConfig();
  const ss = SpreadsheetApp.openById(cfg.templateSheetId);
  const sheet = ss.getSheetByName('Templates');
  if (!sheet) throw new Error('Templates sheet not found. Create sheet named "Templates".');

  const data = sheet.getDataRange().getValues(); // 2D array
  if (data.length < 2) {
    // no rows
    return {
      onPremId: null,
      cloudUPN: null,
      onPremGroups: [],
      cloudGroups: []
    };
  }

  // assume header row at index 0, columns:
  // 0 = TemplateTitle, 1 = OnPremTemplateId, 2 = CloudTemplateUPN, 3 = OnPremGroups, 4 = CloudGroups
  for (let r = 1; r < data.length; r++) {
    const row = data[r];
    if (!row || !row[0]) continue;
    if (String(row[0]).trim() === String(jobTitle).trim()) {
      const onPremId = row[1] ? String(row[1]).trim() : null;
      const cloudUPN = row[2] ? String(row[2]).trim() : null;
      const onPremGroups = row[3] ? String(row[3]).split(',').map(s => s.trim()).filter(Boolean) : [];
      const cloudGroups = row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : [];
      return {
        onPremId,
        cloudUPN,
        onPremGroups,
        cloudGroups
      };
    }
  }

  // fallback default
  return {
    onPremId: null,
    cloudUPN: null,
    onPremGroups: [],
    cloudGroups: []
  };
}

/**
 * Optionally append a row to a "NewHires" Google Sheet for visibility/audit.
 * The polling/post-sync still relies on the EC2-created NewHires.csv; this is just an optional UI copy.
 */
function appendToNewHiresSheet(upn, jobTitle, templateOnPremId, templateCloudUPN) {
  const cfg = getConfig();
  const newHiresSheetId = cfg.newHiresSheetId;
  if (!newHiresSheetId) return; // feature disabled

  try {
    const ss = SpreadsheetApp.openById(newHiresSheetId);
    let sheet = ss.getSheetByName('NewHires');
    if (!sheet) {
      sheet = ss.insertSheet('NewHires');
      // Add header
      sheet.appendRow(['Timestamp','UserPrincipalName','JobTitle','TemplateOnPremId','TemplateCloudUPN']);
    }
    const ts = new Date();
    sheet.appendRow([ts.toISOString(), upn, jobTitle, templateOnPremId || '', templateCloudUPN || '']);
  } catch (err) {
    // Non-fatal; just log
    console.error('appendToNewHiresSheet error:', err);
  }
}

/**
 * Trigger function bound to Google Form submit
 */
function onFormSubmit(e) {
  try {
    const values = (e.namedValues || {});
    const props = getConfig();

    const jobTitle = values["Employee Job Title"] ? values["Employee Job Title"][0] : "TEMPLATE_DEFAULT";
    const template = getTemplateInfo(jobTitle);

    const givenName = values["Employee's Name"] ? values["Employee's Name"][0].split(" ")[0] : "";
    const displayName = values["Employee's Name"] ? values["Employee's Name"][0] : "";
    const upn = values["Employee's LEAD Email Address"] ? values["Employee's LEAD Email Address"][0] : "";
    const mailNickname = upn ? upn.split('@')[0] : "";

    const payload = {
      requestId: Utilities.getUuid(),

      // Template user info
      templateUserId: template.onPremId || null,
      templateCloudUPN: template.cloudUPN || null,

      // Core AD attributes
      givenName: givenName,
      displayName: displayName,
      userPrincipalName: upn,
      mailNickname: mailNickname,
      title: jobTitle,
      department: values["Employee Department"] ? values["Employee Department"][0] : "",
      company: values["Employee Company"] ? values["Employee Company"][0] : "Lead Bank",
      physicalDeliveryOfficeName: values["Employee Location"] ? values["Employee Location"][0] : "",
      streetAddress: values["Shipping Address"] ? values["Shipping Address"][0] : "",
      city: values["Employee City"] ? values["Employee City"][0] : "",
      state: values["Employee State"] ? values["Employee State"][0] : "",
      postalCode: values["Employee Postal Code"] ? values["Employee Postal Code"][0] : "",
      country: values["Employee Country"] ? values["Employee Country"][0] : "",
      manager: values["Manager UPN"] ? values["Manager UPN"][0] : "",

      // On-prem & cloud groups
      memberOf: template.onPremGroups || [],
      cloudGroups: template.cloudGroups || [],

      // requester info
      requesterEmail: (e.values && e.values[0]) ? e.values[0] : Session.getActiveUser().getEmail()
    };


    // Send payload to API Gateway / Lambda
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

    Logger.log(`POST ${props.apiUrl} -> ${code}`);
    Logger.log(body);

    return { status: code, body: body };
  } catch (err) {
    console.error('onFormSubmit error:', err);
    throw err;
  }
}

/**
 * Test helper 
 */
function testPayload() {
  const fakeEvent = {
    namedValues: {
      "Employee's Name": ["Jane Doe"],
      "Employee's Family Name": ["Doe"],
      "Employee Job Title": ["Software Engineer III"],
      "Employee's LEAD Email Address": ["jane.doe@lead.bank"],
      "Employee Location": ["NYC"],
      "Shipping Address": ["123 Main St, NY"],
      "Employee Department": ["Engineering"],
      "Employee Company": ["Lead Bank"],
      "Employee Phone": ["555-1234"],
      "Employee City": ["New York"],
      "Employee State": ["NY"],
      "Employee Postal Code": ["10001"],
      "Employee Country": ["United States"],
      "Manager UPN": ["manager@company.com"]
    },
    values: ["manager@example.com"]
  };

  const result = onFormSubmit(fakeEvent);
  Logger.log('testPayload result: %s', JSON.stringify(result));
}
// comment out fully eventually(used to test)
function testSheetAccess() {
  const id = PropertiesService.getScriptProperties().getProperty('TEMPLATE_SHEET_ID');
  const ss = SpreadsheetApp.openById(id);
  Logger.log('Spreadsheet name: ' + ss.getName());
  const sheet = ss.getSheetByName('Templates');
  if (sheet) {
    Logger.log('Templates sheet found! Row count: ' + sheet.getLastRow());
  } else {
    Logger.log('Templates sheet NOT found.');
  }
}
