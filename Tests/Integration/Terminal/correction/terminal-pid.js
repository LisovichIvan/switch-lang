ObjC.import('AppKit');
const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.Terminal');
if (Number(applications.count) !== 1) throw Error('Expected exactly one running Terminal instance');
JSON.stringify({pid: Number(applications.objectAtIndex(0).processIdentifier)});
