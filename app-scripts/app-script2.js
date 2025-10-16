/*******************************
 * Apps Script: onFormSubmit handler
 * - Uses "List user to mirror access" to find a template row in the Templates sheet
 * - New: supports a "Name" column (human-friendly name) for matching what managers type
 * - Pulls OnPremGroups from the matched template row and includes them as `memberOf`
 * - Only runs when "Reason for request" contains "Onboarding"
 *
 * Templates sheet (sheet name = "Templates") columns (A..F):
 *   TemplateTitle | Name | OnPremTemplateId | CloudTemplateUPN | OnPremGroups | CloudGroups
 *   - Name: human friendly name (e.g. "Eli James") that matches what manager types into "List user to mirror access"
 *   - OnPremGroups and CloudGroups are comma-separated lists (group display names or CNs)
 *******************************/

const SCRIPT_PROPS = PropertiesService.getScriptProperties();

/** Return config (throws if required props missing) */
function getConfig() {
  const apiKey = SCRIPT_PROPS.getProperty('API_KEY');
  const apiUrl = SCRIPT_PROPS.getProperty('API_GATEWAY_URL');
  const templateSheetId = SCRIPT_PROPS.getProperty('TEMPLATE_SHEET_ID');
  const newHiresSheetId = SCRIPT_PROPS.getProperty('OPTIONAL_NEWHIRES_SHEET_ID');

  if (!apiUrl) throw new Error('Missing Script Property: API_GATEWAY_URL.');
  if (!templateSheetId) throw new Error('Missing Script Property: TEMPLATE_SHEET_ID.');

  return { apiKey, apiUrl, templateSheetId, newHiresSheetId };
}

/**
 * Read template mapping from Google Sheet "Templates".
 * Matching priority:
 *   1) mirrorKey (exact case-insensitive match) against TemplateTitle, Name, OnPremTemplateId, CloudTemplateUPN
 *   2) jobTitle fallback matching TemplateTitle
 *
 * Returns: { onPremId, cloudUPN, onPremGroups:[], cloudGroups:[] }
 */
function getTemplateInfo(jobTitle, mirrorKey) {
  const cfg = getConfig();
  const ss = SpreadsheetApp.openById(cfg.templateSheetId);
  const sheet = ss.getSheetByName('Templates');
  if (!sheet) throw new Error('Templates sheet not found. Create a sheet named "Templates".');

  const data = sheet.getDataRange().getValues(); // 2D array
  if (data.length < 2) {
    return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };
  }

  // Normalize helper (null-safe, lower-case trimmed)
  const norm = (v) => (v === undefined || v === null) ? '' : String(v).trim().toLowerCase();

  // Try mirrorKey first (if provided)
  if (mirrorKey && String(mirrorKey).trim() !== '') {
    const mk = norm(mirrorKey);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const title = norm(row[0]);       // TemplateTitle (col A)
      const nameCol = norm(row[1]);    // Name (col B) - human friendly
      const onPremId = norm(row[2]);   // OnPremTemplateId (col C)
      const cloudUpn = norm(row[3]);   // CloudTemplateUPN (col D)
      if (mk === title || mk === nameCol || mk === onPremId || mk === cloudUpn) {
        return {
          onPremId: row[2] ? String(row[2]).trim() : null,
          cloudUPN: row[3] ? String(row[3]).trim() : null,
          onPremGroups: row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : [],
          cloudGroups: row[5] ? String(row[5]).split(',').map(s => s.trim()).filter(Boolean) : []
        };
      }
    }
  }

  // Fallback: match jobTitle to TemplateTitle
  if (jobTitle && String(jobTitle).trim() !== '') {
    const jt = norm(jobTitle);
    for (let r = 1; r < data.length; r++) {
      const row = data[r];
      if (!row) continue;
      const title = norm(row[0]);
      if (jt === title) {
        return {
          onPremId: row[2] ? String(row[2]).trim() : null,
          cloudUPN: row[3] ? String(row[3]).trim() : null,
          onPremGroups: row[4] ? String(row[4]).split(',').map(s => s.trim()).filter(Boolean) : [],
          cloudGroups: row[5] ? String(row[5]).split(',').map(s => s.trim()).filter(Boolean) : []
        };
      }
    }
  }

  // not found
  return { onPremId: null, cloudUPN: null, onPremGroups: [], cloudGroups: [] };
}

/** Optional: append minimal visibility row into a NewHires sheet (not required by poller) */
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

/** Safe field reader that tolerates small differences in question text (case/spacing/colon) */
function readField(valuesObj, name) {
  if (!valuesObj) return '';
  if (valuesObj[name]) return valuesObj[name][0];
  const keys = Object.keys(valuesObj || {});
  const low = name.toLowerCase().trim();
  const alt = keys.find(k => k && k.toLowerCase().trim() === low);
  return alt ? valuesObj[alt][0] : '';
}

/** Main onFormSubmit handler */
function onFormSubmit(e) {
  try {
    const values = (e.namedValues || {});
    const cfg = getConfig();

    // Only run for onboarding requests
    const reason = readField(values, "Reason for request");
    if (!reason || !String(reason).toLowerCase().includes("onboarding")) {
      Logger.log("Skipping run — not an onboarding request. Reason: " + reason);
      return;
    }

    // Read required form fields (accept some common punctuation variants)
    const employeeName = readField(values, "Employee Name");
    const jobTitle = readField(values, "Employee Job Title");
    const upnField = readField(values, "Employee's LEAD Email Address:") || readField(values, "Employee's LEAD Email Address");
    const supervisor = readField(values, "Employee's Supervisor:") || readField(values, "Employee's Supervisor");
    const mirrorTyped = readField(values, "List user to mirror access"); // manager typed template identifier (now can be the human Name column)
    const location = readField(values, "Employee Location");

    // Lookup template in Spreadsheet (mirrorTyped takes precedence)
    const template = getTemplateInfo(jobTitle, mirrorTyped);

    // Build AD-focused payload
    const givenName = employeeName ? String(employeeName).split(' ')[0] : '';
    const displayName = employeeName || '';
    const mailNickname = upnField ? String(upnField).split('@')[0] : '';

    const payload = {
      requestId: Utilities.getUuid(),

      // Template info (for poller)
      templateUserId: template.onPremId || null,
      templateCloudUPN: template.cloudUPN || null,

      // Core AD attributes from form
      givenName: givenName,
      displayName: displayName,
      userPrincipalName: upnField || '',
      mailNickname: mailNickname,
      title: jobTitle || '',
      manager: supervisor || '',
      physicalDeliveryOfficeName: location || '',

      // <-- IMPORTANT: memberOf comes from the matched template row's OnPremGroups column
      memberOf: template.onPremGroups || [],

      // cloudGroups from templates sheet (optional -- for post-sync)
      cloudGroups: template.cloudGroups || [],

      // For audit / fallback
      mirrorUserTyped: mirrorTyped || '',
      requesterEmail: (e.values && e.values[0]) ? e.values[0] : Session.getActiveUser().getEmail(),
      reasonForRequest: reason || ''
    };

    // Optional UI append (not required for poller)
    try {
      appendToNewHiresSheet(payload.userPrincipalName, jobTitle, payload.templateUserId, payload.templateCloudUPN);
    } catch (err) {
      console.warn('Failed to append to NewHires sheet:', err);
    }

    // Send payload to API Gateway > Lambda > SQS
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

    return { status: response.getResponseCode(), body: response.getContentText() };

  } catch (err) {
    console.error('onFormSubmit error:', err);
    throw err;
  }
}

/** Test helper to run locally in the editor */
function testPayload() {
  const fakeEvent = {
    namedValues: {
      "Employee Name": ["Elias James"],
      "Employee Job Title": ["IT Helpdesk Specialist"],
      "Employee's LEAD Email Address:": ["eliasj@lead.bank"],
      "Employee's Supervisor:": ["roscoe@lead.bank"],
      "List user to mirror access": ["Eli James"], 
      "Employee Location": ["Chapman Farms"],
      "Reason for request": ["Onboarding"]
    },
    values: ["roscoe@lead.bank"]
  };

  const result = onFormSubmit(fakeEvent);
  Logger.log('testPayload result: %s', JSON.stringify(result));
}
