/*******************************
 * Apps Script: onFormSubmit handler (sheet-driven, robust)
 * - Reads last row from NewHires sheet (form responses)
 * - Looks up template from Templates sheet
 * - Builds payload and sends to API Gateway
 *******************************/

const SCRIPT_PROPS = PropertiesService.getScriptProperties();

/** Return config */
function getConfig() {
  const apiKey = SCRIPT_PROPS.getProperty('API_KEY');
  const apiUrl = SCRIPT_PROPS.getProperty('API_GATEWAY_URL');
  const templateSheetId = SCRIPT_PROPS.getProperty('TEMPLATE_SHEET_ID');
  const newHiresSheetId = SCRIPT_PROPS.getProperty('OPTIONAL_NEWHIRES_SHEET_ID');

  if (!apiUrl) throw new Error('Missing Script Property: API_GATEWAY_URL.');
  if (!templateSheetId) throw new Error('Missing Script Property: TEMPLATE_SHEET_ID.');
  if (!newHiresSheetId) throw new Error('Missing Script Property: OPTIONAL_NEWHIRES_SHEET_ID.');

  return { apiKey, apiUrl, templateSheetId, newHiresSheetId };
}

/** Read template mapping from Google Sheet "Templates" */
function getTemplateInfo(jobTitle, mirrorKey) {
  const cfg = getConfig();
  const ss = SpreadsheetApp.openById(cfg.templateSheetId);
  const sheet = ss.getSheetByName('Templates');
  if (!sheet) throw new Error('Templates sheet not found.');

  const data = sheet.getDataRange().getValues();
  if (data.length < 2) return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };

  const norm = (v) => (v === undefined || v === null) ? '' : String(v).trim().toLowerCase();

  // Try mirrorKey first
  if (mirrorKey && mirrorKey.trim() !== '') {
    const mk = norm(mirrorKey);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const title = norm(row[0]);      // TemplateTitle
      const nameCol = norm(row[5]);    // Name column
      const onPremId = norm(row[1]);   // OnPremTemplateId
      const cloudUpn = norm(row[2]);   // CloudTemplateUPN
      if (mk === title || mk === nameCol || mk === onPremId || mk === cloudUpn) {
        return {
          onPremId: row[1] ? String(row[1]).trim() : null,
          cloudUPN: row[2] ? String(row[2]).trim() : null,
          onPremGroups: row[3] ? String(row[3]).split(',').map(s => s.trim()).filter(Boolean) : [],
          cloudGroups: row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : []
        };
      }
    }
  }

  // Fallback: match jobTitle to TemplateTitle
  if (jobTitle && jobTitle.trim() !== '') {
    const jt = norm(jobTitle);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const title = norm(row[0]);
      if (jt === title) {
        return {
          onPremId: row[1] ? String(row[1]).trim() : null,
          cloudUPN: row[2] ? String(row[2]).trim() : null,
          onPremGroups: row[3] ? String(row[3]).split(',').map(s => s.trim()).filter(Boolean) : [],
          cloudGroups: row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : []
        };
      }
    }
  }

  return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };
}

/** Optional: append to NewHires sheet */
function appendToNewHiresSheet(upn, jobTitle, templateOnPremId, templateCloudUPN) {
  const cfg = getConfig();
  const newHiresSheetId = cfg.newHiresSheetId;
  if (!newHiresSheetId) return;

  try {
    const ss = SpreadsheetApp.openById(newHiresSheetId);
    let sheet = ss.getSheetByName('NewHires');
    if (!sheet) {
      sheet = ss.insertSheet('NewHires');
      sheet.appendRow(['Timestamp','UserPrincipalName','JobTitle','TemplateOnPremId','TemplateCloudUPN']);
    }
    const ts = new Date();
    sheet.appendRow([ts.toISOString(), upn, jobTitle, templateOnPremId || '', templateCloudUPN || '']);
  } catch (err) {
    console.error('appendToNewHiresSheet error:', err);
  }
}

/** Safe field reader */
function readField(valuesObj, name) {
  if (!valuesObj) return '';
  return valuesObj[name] || '';
}

/** Main onFormSubmit handler (sheet-driven) */
function onFormSubmit() {
  try {
    const cfg = getConfig();

    // Pull last row from NewHires sheet (form responses)
    const ss = SpreadsheetApp.openById(cfg.newHiresSheetId);
    const sheet = ss.getSheetByName('NewHires');
    if (!sheet) throw new Error('NewHires sheet not found.');

    const lastRow = sheet.getLastRow();
    const headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const rowValues = sheet.getRange(lastRow, 1, 1, sheet.getLastColumn()).getValues()[0];

    // Build values object (like e.namedValues)
    const values = {};
    headers.forEach((h, i) => {
      if (h) values[h] = [rowValues[i]];
    });

    Logger.log('Form values pulled from Sheet: %s', JSON.stringify(values, null, 2));

    // Extract fields
    const employeeName = values["Employee Name"] ? values["Employee Name"][0] : '';
    const jobTitle = values["JobTitle"] ? values["JobTitle"][0] : '';
    const upnField = values["UserPrincipalName"] ? values["UserPrincipalName"][0] : '';
    const mirrorTyped = values["TemplateOnPremId"] ? values["TemplateOnPremId"][0] : '';
    const location = ''; 
    const supervisor = ''; 

    // Lookup template info
    const template = getTemplateInfo(jobTitle, mirrorTyped);

    const givenName = employeeName ? employeeName.split(' ')[0] : '';
    const displayName = employeeName || '';
    const mailNickname = upnField ? upnField.split('@')[0] : '';

    const payload = {
      requestId: Utilities.getUuid(),
      templateUserId: template.onPremId || null,
      templateCloudUPN: template.cloudUPN || null,
      givenName,
      displayName,
      userPrincipalName: upnField || '',
      mailNickname,
      title: jobTitle || '',
      manager: supervisor || '',
      physicalDeliveryOfficeName: location || '',
      memberOf: template.onPremGroups || [],
      cloudGroups: template.cloudGroups || [],
      mirrorUserTyped: mirrorTyped || '',
      requesterEmail: rowValues[0] || "unknown@domain.com"
    };

    Logger.log('Payload to send: %s', JSON.stringify(payload, null, 2));

    // Send payload to API Gateway
    const options = {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(payload),
      headers: { 'x-api-key': cfg.apiKey || '' },
      muteHttpExceptions: true,
      timeout: 30000
    };

    const response = UrlFetchApp.fetch(cfg.apiUrl, options);
    Logger.log(`POST ${cfg.apiUrl} -> ${response.getResponseCode()}`);
    Logger.log(response.getContentText());

    // Optional: append metadata back to NewHires
    appendToNewHiresSheet(payload.userPrincipalName, jobTitle, payload.templateUserId, payload.templateCloudUPN);

    return { status: response.getResponseCode(), body: response.getContentText() };
  } catch (err) {
    console.error('onFormSubmit error:', err);
    throw err;
  }
}

/** Test helper */
function testPayload() {
  return onFormSubmit();
}
