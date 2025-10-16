/*******************************
 * Apps Script: onFormSubmit handler (robust & sheet-driven)
 * - Normalizes headers and trims spaces
 * - Looks up Templates sheet reliably
 * - Builds payload and sends to API Gateway
 * - Duplicate app-script2.js so its not lost (prod potential)
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

/** Read template mapping from Templates sheet */
function getTemplateInfo(jobTitle, mirrorKey) {
  const cfg = getConfig();
  const ss = SpreadsheetApp.openById(cfg.templateSheetId);
  const sheet = ss.getSheetByName('Templates');
  if (!sheet) throw new Error('Templates sheet not found.');

  const data = sheet.getDataRange().getValues();
  if (data.length < 2) return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };

  const normalize = v => v ? String(v).trim().toLowerCase() : '';

  // Try mirrorKey first
  if (mirrorKey && mirrorKey.trim() !== '') {
    const mk = normalize(mirrorKey);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const templateTitle = normalize(row[0]);
      const onPremId = row[1] ? String(row[1]).trim() : null;
      const cloudUpn = row[2] ? String(row[2]).trim() : null;
      const onPremGroups = row[3] ? String(row[3]).split(',').map(s => s.trim()).filter(Boolean) : [];
      const cloudGroups = row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : [];
      const nameCol = row[5] ? normalize(row[5]) : '';

      if (mk === templateTitle || mk === nameCol || mk === normalize(onPremId) || mk === normalize(cloudUpn)) {
        return { onPremId, cloudUPN: cloudUpn, onPremGroups, cloudGroups };
      }
    }
  }

  // Fallback: match jobTitle to TemplateTitle
  if (jobTitle && jobTitle.trim() !== '') {
    const jt = normalize(jobTitle);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const templateTitle = normalize(row[0]);
      if (jt === templateTitle) {
        const onPremId = row[1] ? String(row[1]).trim() : null;
        const cloudUpn = row[2] ? String(row[2]).trim() : null;
        const onPremGroups = row[3] ? String(row[3]).split(',').map(s => s.trim()).filter(Boolean) : [];
        const cloudGroups = row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : [];
        return { onPremId, cloudUPN: cloudUpn, onPremGroups, cloudGroups };
      }
    }
  }

  return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };
}

/** Normalize and get a field from the sheet values */
function getValue(valuesObj, key) {
  const foundKey = Object.keys(valuesObj).find(k => k.trim().toLowerCase() === key.toLowerCase());
  return foundKey ? valuesObj[foundKey][0] : '';
}

/** Optional: append to NewHires sheet */
function appendToNewHiresSheet(upn, jobTitle, templateOnPremId, templateCloudUPN) {
  const cfg = getConfig();
  const newHiresSheetId = cfg.newHiresSheetId;
  if (!newHiresSheetId) return;

  try {
    const ss = SpreadsheetApp.openById(newHiresSheetId);
    let sheet = ss.getSheetByName('Form Responses 1');
    if (!sheet) {
      sheet = ss.insertSheet('Form Responses 1');
      sheet.appendRow(['Timestamp','UserPrincipalName','JobTitle','TemplateOnPremId','TemplateCloudUPN']);
    }
    const ts = new Date();
    sheet.appendRow([ts.toISOString(), upn, jobTitle, templateOnPremId || '', templateCloudUPN || '']);
  } catch (err) {
    console.error('appendToNewHiresSheet error:', err);
  }
}

/** Main onFormSubmit handler */
function onFormSubmit() {
  try {
    const cfg = getConfig();

    // Pull last row from NewHires sheet
    const ss = SpreadsheetApp.openById(cfg.newHiresSheetId);
    const sheet = ss.getSheetByName('Form Responses 1');
    if (!sheet) throw new Error('Form Responses 1 sheet not found.');

    const lastRow = sheet.getLastRow();
    const headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const rowValues = sheet.getRange(lastRow, 1, 1, sheet.getLastColumn()).getValues()[0];

    // Build a normalized values object
    const values = {};
    headers.forEach((h, i) => {
      if (h) values[h] = [rowValues[i]];
    });

    Logger.log('Form values pulled from Sheet: %s', JSON.stringify(values, null, 2));

    // Extract fields using normalized key lookup
    const employeeName = getValue(values, "Employee Name");
    const jobTitle = getValue(values, "Employee Job Title");
    const upnField = getValue(values, "Employee's LEAD Email Address:");
    const supervisor = getValue(values, "Employee's Supervisor:");
    const mirrorTyped = getValue(values, "List user to mirror access");
    const location = getValue(values, "Employee Location:");

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

    // Append metadata back to NewHires
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
