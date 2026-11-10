ObjC.import('AppKit');
function run(arguments) {
  if (arguments.length !== 2 || !/^\d+$/.test(arguments[0]) || !arguments[1].startsWith('/')) throw Error('Expected exact process identifier and bundle path');
  const expectedProcessIdentifier = Number(arguments[0]);
  const bundlePath = arguments[1];
  const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('local.switch-lang.app');
  if (Number(applications.count) !== 1) throw Error('Expected exactly one application; no action taken');
  const application = applications.objectAtIndex(0);
  if (Number(application.processIdentifier) !== expectedProcessIdentifier ||
      ObjC.unwrap(application.bundleURL.path) !== bundlePath ||
      ObjC.unwrap(application.executableURL.path) !== bundlePath + '/Contents/MacOS/switch-lang') {
    throw Error('Application changed; no action taken');
  }
  if (!application.terminate) throw Error('Application did not accept graceful termination');
  return 'Graceful termination requested for verified application';
}
