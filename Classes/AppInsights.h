#ifndef MSAI_h
#define MSAI_h

#import "AppInsightsFeatureConfig.h"
#import "MSAIAppInsights.h"

#if MSAI_FEATURE_CRASH_REPORTER
#import "MSAICrashManager.h"
#import "MSAICrashManagerDelegate.h"
#import "MSAICrashDetails.h"
#import "MSAICrashMetaData.h"
#endif /* MSAI_FEATURE_CRASH_REPORTER */

#if MSAI_FEATURE_TELEMETRY
#import "MSAICategoryContainer.h"
#import "MSAITelemetryManager.h"
#endif /* MSAI_FEATURE_TELEMETRY */

// Notification message which AppInsightsManager is listening to, to retry requesting updated from the server
#define MSAINetworkDidBecomeReachableNotification @"MSAINetworkDidBecomeReachable"

#define MSAI_CRASH_DATA_URL   @"https://dray-prod.aisvc.visualstudio.com/v2/track"
#define MSAI_EVENT_DATA_URL   @"https://dc.services.visualstudio.com/v2/track"

#if MSAI_FEATURE_CRASH_REPORTER
/**
 *  MSAI Crash Reporter error domain
 */
typedef NS_ENUM (NSInteger, MSAICrashErrorReason) {
  /**
   *  Unknown error
   */
  MSAICrashErrorUnknown,
  /**
   *  API Server rejected app version
   */
  MSAICrashAPIAppVersionRejected,
  /**
   *  API Server returned empty response
   */
  MSAICrashAPIReceivedEmptyResponse,
  /**
   *  Connection error with status code
   */
  MSAICrashAPIErrorWithStatusCode
};
extern NSString *const __unused kMSAICrashErrorDomain;


/**
 *  MSAI global error domain
 */
typedef NS_ENUM(NSInteger, MSAIErrorReason) {
  /**
   *  Unknown error
   */
  MSAIErrorUnknown
};
extern NSString *const __unused kMSAIErrorDomain;
#endif 

#endif
