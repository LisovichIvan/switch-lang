ObjC.import('AppKit');
ObjC.import('Foundation');
const identifier = 'local.switch-lang.app';
const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
if (Number(applications.count) > 1) throw Error('Multiple Switch Lang applications; no action permitted');
const running = [];
for (let index = 0; index < Number(applications.count); index++) {
  const application = applications.objectAtIndex(index);
  running.push({pid: Number(application.processIdentifier), bundlePath: ObjC.unwrap(application.bundleURL.path), executablePath: ObjC.unwrap(application.executableURL.path)});
}
const domain = $.NSUserDefaults.standardUserDefaults.persistentDomainForName(identifier);
const keys = ['automatic', 'hotkeyCode', 'hotkeyModifiers', 'diagnosticLogging', 'permissionIntroductionHandled', 'accessibilityRegistrationAttempted', 'inputMonitoringRegistrationAttempted'];
const settings = {};
for (const key of keys) {
  const value = domain ? domain.objectForKey(key) : null;
  if (value) settings[key] = ObjC.unwrap(value);
}
JSON.stringify({applications: running, settings: settings});
