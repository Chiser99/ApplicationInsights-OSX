#import "ApplicationInsights.h"

#if MSAI_FEATURE_CRASH_REPORTER

#import "ApplicationInsightsPrivate.h"
#import "MSAIHelper.h"
#import "MSAICrashManagerPrivate.h"
#import "MSAICrashDataProvider.h"
#import "MSAICrashDetailsPrivate.h"
#import "MSAICrashData.h"
#import "MSAICrashDataHeaders.h"
#import "MSAICrashCXXExceptionHandler.h"
#import "MSAIChannel.h"
#import "MSAIChannelPrivate.h"
#import "MSAIPersistencePrivate.h"
#import "MSAIContextHelper.h"
#import "MSAIContextHelperPrivate.h"
#import "MSAIEnvelope.h"
#import "MSAIEnvelopeManager.h"
#import "MSAIEnvelopeManagerPrivate.h"
#import "MSAIData.h"
#import <mach-o/loader.h>
#import <mach-o/dyld.h>

#import <AppKit/AppKit.h>

#include <sys/sysctl.h>
// stores the set of crashreports that have been approved but aren't sent yet
#define kMSAICrashApprovedReports @"MSAICrashApprovedReports" //TODO remove this in next Sprint

// internal keys
NSString *const kMSAICrashManagerIsDisabled = @"MSAICrashManagerIsDisabled";

static char const *saveEventsFilePath;

static MSAICrashManagerCallbacks msaiCrashCallbacks = {
    .context = NULL,
    .handleSignal = NULL
};

// Proxy implementation for PLCrashReporter to keep our interface stable while this can change
static void plcr_post_crash_callback(siginfo_t *info, ucontext_t *uap, void *context) {
  msai_save_events_callback(info, uap, context);

  if(msaiCrashCallbacks.handleSignal != NULL) {
    msaiCrashCallbacks.handleSignal(context);
  }
}

// Proxy that is set as a callback when the developer defined a custom callback.
// The developer's callback will be called in plcr_post_crash_callback in addition to our default function.
static PLCrashReporterCallbacks plCrashCallbacks = {
    .version = 0,
    .context = NULL,
    .handleSignal = plcr_post_crash_callback
};

// Our default callback that will always be executed, possibly in addition to a custom callback set by the developer.
static PLCrashReporterCallbacks defaultCallback = {
  .version = 0,
  .context = NULL,
  .handleSignal = msai_save_events_callback
};


// Temporary class until PLCR catches up
// We trick PLCR with an Objective-C exception.
//
// This code provides us access to the C++ exception message and stack trace.
//
@interface BITCrashCXXExceptionWrapperException : NSException
- (instancetype)initWithCXXExceptionInfo:(const MSAICrashUncaughtCXXExceptionInfo *)info;
@end

@implementation BITCrashCXXExceptionWrapperException {
  const MSAICrashUncaughtCXXExceptionInfo *_info;
}

- (instancetype)initWithCXXExceptionInfo:(const MSAICrashUncaughtCXXExceptionInfo *)info {
  extern char* __cxa_demangle(const char* mangled_name, char* output_buffer, size_t* length, int* status);
  char *demangled_name = __cxa_demangle ? __cxa_demangle(info->exception_type_name ?: "", NULL, NULL, NULL) : NULL;
  
  if ((self = [super
               initWithName:[NSString stringWithUTF8String:demangled_name ?: info->exception_type_name ?: ""]
               reason:[NSString stringWithUTF8String:info->exception_message ?: ""]
               userInfo:nil])) {
    _info = info;
  }
  return self;
}

- (NSArray *)callStackReturnAddresses {
  NSMutableArray *cxxFrames = [NSMutableArray arrayWithCapacity:_info->exception_frames_count];
  
  for (uint32_t i = 0; i < _info->exception_frames_count; ++i) {
    [cxxFrames addObject:[NSNumber numberWithUnsignedLongLong:_info->exception_frames[i]]];
  }
  return cxxFrames;
}

@end


// C++ Exception Handler
static void uncaught_cxx_exception_handler(const MSAICrashUncaughtCXXExceptionInfo *info) {
  // This relies on a LOT of sneaky internal knowledge of how PLCR works and should not be considered a long-term solution.
  NSGetUncaughtExceptionHandler()([[BITCrashCXXExceptionWrapperException alloc] initWithCXXExceptionInfo:info]);
  abort();
}


@implementation MSAICrashManager {
  id _appDidBecomeActiveObserver;
}

#pragma mark - Start

+ (instancetype)sharedManager {
  static MSAICrashManager *sharedManager = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedManager = [self new];
  });
  return sharedManager;
}

/**
*	 Main startup sequence initializing PLCrashReporter if it wasn't disabled
*/
- (void)startManager {
  if(self.isCrashManagerDisabled) return;
  if(![MSAICrashManager sharedManager].isSetupCorrectly) {
    [self checkCrashManagerDisabled];

    [self registerObservers];

    static dispatch_once_t plcrPredicate;
    dispatch_once(&plcrPredicate, ^{
      _timeintervalCrashInLastSessionOccured = -1;

      [[MSAIPersistence sharedInstance] deleteCrashReporterLockFile];

      [self configDefaultCallback];

      [self configPLCrashReporter];

      // Check if we previously crashed
      if([self.plCrashReporter hasPendingCrashReport]) {
        _didCrashInLastSession = YES;
        [self readCrashReportAndStartProcessing];
      }

      // The actual signal and mach handlers are only registered when invoking `enableCrashReporterAndReturnError`
      // So it is safe enough to only disable the following part when a debugger is attached no matter which
      // signal handler type is set
      // We only check for this if we are not in the App Store environment

      if(self.debuggerIsAttached) {
        NSLog(@"[ApplicationInsights] WARNING: Detecting crashes is NOT enabled due to running the app with a debugger attached.");
      }

      [self setupExceptionHandler];
    });

    [MSAICrashManager sharedManager].isSetupCorrectly = YES;
  }
}

- (void)dealloc {
  [self unregisterObservers];
}

#pragma mark - Start Helpers

- (void)setupExceptionHandler {
  if(!self.debuggerIsAttached) {
    // Multiple exception handlers can be set, but we can only query the top level error handler (uncaught exception handler).
    //
    // To check if PLCrashReporter's error handler is successfully added, we compare the top
    // level one that is set before and the one after PLCrashReporter sets up its own.
    //
    // With delayed processing we can then check if another error handler was set up afterwards
    // and can show a debug warning log message, that the dev has to make sure the "newer" error handler
    // doesn't exit the process itself, because then all subsequent handlers would never be invoked.
    //
    // Note: ANY error handler setup BEFORE ApplicationInsights initialization will not be processed!

    // get the current top level error handler
    NSUncaughtExceptionHandler *initialHandler = NSGetUncaughtExceptionHandler();

    // PLCrashReporter may only be initialized once. So make sure the developer
    // can't break this
    NSError *error = NULL;

    // set any user defined callbacks, hopefully the users knows what they do
    if(self.crashCallBacks) {
      [self.plCrashReporter setCrashCallbacks:self.crashCallBacks];
    } else {
      [self.plCrashReporter setCrashCallbacks:&defaultCallback];
    }

    // Enable the Crash Reporter
    if(![self.plCrashReporter enableCrashReporterAndReturnError:&error]) {
      NSLog(@"[ApplicationInsights] WARNING: Could not enable crash reporter: %@", [error localizedDescription]);
    }

    // get the new current top level error handler, which should now be the one from PLCrashReporter
    NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();

    // do we have a new top level error handler? then we were successful
    if(currentHandler && currentHandler != initialHandler) {
      self.exceptionHandler = currentHandler;

      MSAILog(@"INFO: Exception handler successfully initialized.");
    } else {
      // this should never happen, theoretically only if NSSetUncaugtExceptionHandler() has some internal issues
      NSLog(@"[ApplicationInsights] ERROR: Exception handler could not be set. Make sure there is no other exception handler set up!");
    }
    
    // Add the C++ uncaught exception handler, which is currently not handled by PLCrashReporter internally
    [MSAICrashUncaughtCXXExceptionHandlerManager addCXXExceptionHandler:uncaught_cxx_exception_handler];
  }
}

- (void)configPLCrashReporter {
  PLCrashReporterSignalHandlerType signalHandlerType = PLCrashReporterSignalHandlerTypeMach;
  if(self.machExceptionHandlerDisabled) {
    signalHandlerType = PLCrashReporterSignalHandlerTypeBSD;
  }

  PLCrashReporterSymbolicationStrategy symbolicationStrategy = PLCrashReporterSymbolicationStrategyNone;
  if(self.onDeviceSymbolicationEnabled) {
    symbolicationStrategy = PLCrashReporterSymbolicationStrategyAll;
  }

  MSAIPLCrashReporterConfig *config = [[MSAIPLCrashReporterConfig alloc] initWithSignalHandlerType:signalHandlerType
                                                                             symbolicationStrategy:symbolicationStrategy];
  self.plCrashReporter = [[MSAIPLCrashReporter alloc] initWithConfiguration:config];
}

- (void)checkCrashManagerDisabled {
  NSString *testValue = [[NSUserDefaults standardUserDefaults] stringForKey:kMSAICrashManagerIsDisabled];
  if(testValue) {
    self.isCrashManagerDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:kMSAICrashManagerIsDisabled];
  } else {
    [[NSUserDefaults standardUserDefaults] setBool:self.isCrashManagerDisabled forKey:kMSAICrashManagerIsDisabled];
  }
}

#pragma mark - Configuration

// Enable/Disable the CrashManager and store the setting in standardUserDefaults
- (void)setCrashManagerDisabled:(BOOL)disableCrashManager {
  _isCrashManagerDisabled = disableCrashManager;
  [[NSUserDefaults standardUserDefaults] setBool:disableCrashManager forKey:kMSAICrashManagerIsDisabled];
}

/**
*  Set the callback for PLCrashReporter
*
*  @param callbacks MSAICrashManagerCallbacks instance
*/
- (void)setCrashCallbacks:(MSAICrashManagerCallbacks *)callbacks {
  if(!callbacks) return;

  // set our proxy callback struct
  msaiCrashCallbacks.context = callbacks->context;
  msaiCrashCallbacks.handleSignal = callbacks->handleSignal;

  // set the PLCrashReporterCallbacks struct
  plCrashCallbacks.context = callbacks->context;

  self.crashCallBacks = &plCrashCallbacks;
}

- (void)configDefaultCallback {
  saveEventsFilePath = strdup([[[MSAIPersistence sharedInstance] newFileURLForPersitenceType:MSAIPersistenceTypeRegular] UTF8String]);
}

void msai_save_events_callback(siginfo_t *info, ucontext_t *uap, void *context) {
  // Try to get a file descriptor with our pre-filled path
  int fd = open(saveEventsFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return;
  }
  
  size_t len = strlen(MSAISafeJsonEventsString);
  if (len > 0) {
    // Simply write the whole string to disk and close the JSON array 
    write(fd, MSAISafeJsonEventsString, len);
    if ((len >= 1) && strncmp(MSAISafeJsonEventsString, "[", 1) == 0) {
      write(fd, "]", 1);
    }
  }
  close(fd);
}

#pragma mark - Debugging Helpers

- (BOOL)getIsDebuggerAttached {
  return msai_isDebuggerAttached();
}

- (void)generateTestCrash {
  if(self.debuggerIsAttached) {
    NSLog(@"[ApplicationInsights] WARNING: The debugger is attached. The following crash cannot be detected by the SDK!");
  }

  __builtin_trap();
}

#pragma mark - Lifecycle Notifications

- (void)registerObservers {
  __weak typeof(self) weakSelf = self;

  if(nil == _appDidBecomeActiveObserver) {
    _appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                                                    object:nil
                                                                                     queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *note) {
                                                                                  typeof(self) strongSelf = weakSelf;
                                                                                  [strongSelf readCrashReportAndStartProcessing];
                                                                                }];
  }
}

- (void)unregisterObservers {
  [self unregisterObserver:_appDidBecomeActiveObserver];
}

- (void)unregisterObserver:(id)observer {
  if(observer) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    observer = nil;
  }
}


#pragma mark - PLCrashReporter

/**
*	 Process new crash reports provided by PLCrashReporter
*
* Parse the new crash report and gather additional meta data from the app which will be stored along the crash report
*/
- (void)readCrashReportAndStartProcessing {
  NSError *error = NULL;

  if(!self.plCrashReporter) {
    return;
  }

  NSData *crashData;

  // check if the next call ran successfully the last time
  // check again if we have a pending crash report to be sure we actually have something to load
  if(![[MSAIPersistence sharedInstance] crashReportLockFilePresent] && [self.plCrashReporter hasPendingCrashReport]) {
    // mark the start of the routine
    [[MSAIPersistence sharedInstance] createCrashReporterLockFile];

    // Try loading the crash report
    crashData = [[NSData alloc] initWithData:[self.plCrashReporter loadPendingCrashReportDataAndReturnError:&error]];

    if(crashData == nil) {
      MSAILog(@"ERROR: Could not load crash report: %@", error);
    } else {
      // get the startup timestamp from the crash report, and the file timestamp to calculate the timeinterval when the crash happened after startup
      MSAIPLCrashReport *report = [[MSAIPLCrashReport alloc] initWithData:crashData error:&error];

      if(report == nil) {
        MSAILog(@"WARNING: Could not parse crash report");
      }
      else {
        NSDate *appStartTime = nil;
        NSDate *appCrashTime = nil;
        if([report.processInfo respondsToSelector:@selector(processStartTime)]) {
          if(report.systemInfo.timestamp && report.processInfo.processStartTime) {
            appStartTime = report.processInfo.processStartTime;
            appCrashTime = report.systemInfo.timestamp;
            _timeintervalCrashInLastSessionOccured = [report.systemInfo.timestamp timeIntervalSinceDate:report.processInfo.processStartTime];
          }
        }

        NSString *incidentIdentifier = @"???";
        if(report.uuidRef != NULL) {
          incidentIdentifier = (NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef));
        }

        NSString *reporterKey = msai_appAnonID() ?: @"";

        _lastSessionCrashDetails = [[MSAICrashDetails alloc] initWithIncidentIdentifier:incidentIdentifier
                                                                            reporterKey:reporterKey
                                                                                 signal:report.signalInfo.name
                                                                          exceptionName:report.exceptionInfo.exceptionName
                                                                        exceptionReason:report.exceptionInfo.exceptionReason
                                                                           appStartTime:appStartTime
                                                                              crashTime:appCrashTime
                                                                              osVersion:report.systemInfo.operatingSystemVersion
                                                                                osBuild:report.systemInfo.operatingSystemBuild
                                                                               appBuild:report.applicationInfo.applicationVersion
        ];
      }
    }
  }
#if __MAC_OS_X_VERSION_MIN_REQUIRED > 1090
  if(!msai_isRunningInAppExtension() &&
      [NSApplication sharedApplication].active == NO) {
      [[MSAIPersistence sharedInstance] deleteCrashReporterLockFile];//TODO only do this when persisting was successful?
    return;
  }
#endif

  // check again if another exception handler was added with a short delay
  [self performSelector:@selector(checkForOtherExceptionHandlersAfterSetup) withObject:nil afterDelay:0.5f];

  [self createCrashReportWithCrashData:crashData];

  // Purge the report
  // mark the end of the routine
  [[MSAIPersistence sharedInstance] deleteCrashReporterLockFile];//TODO only do this when persisting was successful?
  [self.plCrashReporter purgePendingCrashReport]; //TODO only do this when persisting was successful?
  [[MSAIContextHelper sharedInstance] cleanUpMetaData];
}

- (void)checkForOtherExceptionHandlersAfterSetup {
  // was our own exception handler successfully added?
  if (self.exceptionHandler) {
    // get the current top level error handler
    NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();

    // If the top level error handler differs from our own, then at least another one was added.
    // This could cause exception crashes not to be reported to HockeyApp. See log message for details.
    if (self.exceptionHandler != currentHandler) {
      NSLog(@"[ApplicationInsights] ERROR: Exception handler could not be set. Make sure there is no other exception handler set up!");
    }
  }
}

#pragma mark - Crash Report Processing

/***
* Gathers all collected data and constructs Crash into an Envelope for processing
*/
- (void)createCrashReportWithCrashData:(NSData*)crashData {
  if(!crashData) {
    return;
  }

  NSError *error = NULL;

  if([crashData length] > 0) {
    MSAIPLCrashReport *report = nil;
    MSAIEnvelope *crashEnvelope = nil;

    report = [[MSAIPLCrashReport alloc] initWithData:crashData error:&error];

    if(report) {
      crashEnvelope = [MSAICrashDataProvider crashDataForCrashReport:report];
      if([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
        //TODO Check if this has to be added again
//        _crashIdenticalCurrentVersion = YES;
      }
    }

    if([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
      //TODO Check if this has to be added again
//        _crashIdenticalCurrentVersion = YES;
    }

    if(report == nil && crashEnvelope == nil) {
      MSAILog(@"WARNING: Could not parse crash report");
      // we cannot do anything with this report, so don't continue
      // the next crash will be automatically processed on the next app start/becoming active event
      return;
    }

    MSAILog(@"INFO: Persisting crash reports started.");
    [[MSAIChannel sharedChannel] processDictionary:[crashEnvelope serializeToDictionary] withCompletionBlock:nil];
  }
}

#pragma mark - Logging Helpers

- (void)reportError:(NSError *)error {
  MSAILog(@"ERROR: %@", [error localizedDescription]);
}

@end

#endif /* MSAI_FEATURE_CRASH_REPORTER */

