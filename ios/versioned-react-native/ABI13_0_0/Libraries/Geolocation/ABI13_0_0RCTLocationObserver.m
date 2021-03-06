/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI13_0_0RCTLocationObserver.h"

#import <CoreLocation/CLError.h>
#import <CoreLocation/CLLocationManager.h>
#import <CoreLocation/CLLocationManagerDelegate.h>

#import <ReactABI13_0_0/ABI13_0_0RCTAssert.h>
#import <ReactABI13_0_0/ABI13_0_0RCTBridge.h>
#import <ReactABI13_0_0/ABI13_0_0RCTConvert.h>
#import <ReactABI13_0_0/ABI13_0_0RCTEventDispatcher.h>
#import <ReactABI13_0_0/ABI13_0_0RCTLog.h>

typedef NS_ENUM(NSInteger, ABI13_0_0RCTPositionErrorCode) {
  ABI13_0_0RCTPositionErrorDenied = 1,
  ABI13_0_0RCTPositionErrorUnavailable,
  ABI13_0_0RCTPositionErrorTimeout,
};

#define ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY kCLLocationAccuracyHundredMeters

typedef struct {
  double timeout;
  double maximumAge;
  double accuracy;
  double distanceFilter;
} ABI13_0_0RCTLocationOptions;

@implementation ABI13_0_0RCTConvert (ABI13_0_0RCTLocationOptions)

+ (ABI13_0_0RCTLocationOptions)ABI13_0_0RCTLocationOptions:(id)json
{
  NSDictionary<NSString *, id> *options = [ABI13_0_0RCTConvert NSDictionary:json];

  double distanceFilter = options[@"distanceFilter"] == NULL ? ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY
    : [ABI13_0_0RCTConvert double:options[@"distanceFilter"]] ?: kCLDistanceFilterNone;

  return (ABI13_0_0RCTLocationOptions){
    .timeout = [ABI13_0_0RCTConvert NSTimeInterval:options[@"timeout"]] ?: INFINITY,
    .maximumAge = [ABI13_0_0RCTConvert NSTimeInterval:options[@"maximumAge"]] ?: INFINITY,
    .accuracy = [ABI13_0_0RCTConvert BOOL:options[@"enableHighAccuracy"]] ? kCLLocationAccuracyBest : ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY,
    .distanceFilter = distanceFilter
  };
}

@end

static NSDictionary<NSString *, id> *ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorCode code, NSString *msg /* nil for default */)
{
  if (!msg) {
    switch (code) {
      case ABI13_0_0RCTPositionErrorDenied:
        msg = @"User denied access to location services.";
        break;
      case ABI13_0_0RCTPositionErrorUnavailable:
        msg = @"Unable to retrieve location.";
        break;
      case ABI13_0_0RCTPositionErrorTimeout:
        msg = @"The location request timed out.";
        break;
    }
  }

  return @{
    @"code": @(code),
    @"message": msg,
    @"PERMISSION_DENIED": @(ABI13_0_0RCTPositionErrorDenied),
    @"POSITION_UNAVAILABLE": @(ABI13_0_0RCTPositionErrorUnavailable),
    @"TIMEOUT": @(ABI13_0_0RCTPositionErrorTimeout)
  };
}

@interface ABI13_0_0RCTLocationRequest : NSObject

@property (nonatomic, copy) ABI13_0_0RCTResponseSenderBlock successBlock;
@property (nonatomic, copy) ABI13_0_0RCTResponseSenderBlock errorBlock;
@property (nonatomic, assign) ABI13_0_0RCTLocationOptions options;
@property (nonatomic, strong) NSTimer *timeoutTimer;

@end

@implementation ABI13_0_0RCTLocationRequest

- (void)dealloc
{
  if (_timeoutTimer.valid) {
    [_timeoutTimer invalidate];
  }
}

@end

@interface ABI13_0_0RCTLocationObserver () <CLLocationManagerDelegate>

@end

@implementation ABI13_0_0RCTLocationObserver
{
  CLLocationManager *_locationManager;
  NSDictionary<NSString *, id> *_lastLocationEvent;
  NSMutableArray<ABI13_0_0RCTLocationRequest *> *_pendingRequests;
  BOOL _observingLocation;
  ABI13_0_0RCTLocationOptions _observerOptions;
}

ABI13_0_0RCT_EXPORT_MODULE()

#pragma mark - Lifecycle

- (void)dealloc
{
  [_locationManager stopUpdatingLocation];
  _locationManager.delegate = nil;
}

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[@"geolocationDidChange", @"geolocationError"];
}

#pragma mark - Private API

- (void)beginLocationUpdatesWithDesiredAccuracy:(CLLocationAccuracy)desiredAccuracy distanceFilter:(CLLocationDistance)distanceFilter
{
  if (!_locationManager) {
    _locationManager = [CLLocationManager new];
    _locationManager.delegate = self;
  }

  // Request location access permission
  if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"] &&
    [_locationManager respondsToSelector:@selector(requestAlwaysAuthorization)]) {
    [_locationManager requestAlwaysAuthorization];

    // On iOS 9+ we also need to enable background updates
    NSArray *backgroundModes  = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
    if(backgroundModes && [backgroundModes containsObject:@"location"]) {
      if([_locationManager respondsToSelector:@selector(setAllowsBackgroundLocationUpdates:)]) {
        [_locationManager setAllowsBackgroundLocationUpdates:YES];
      }
    }
  } else if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"] &&
    [_locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
    [_locationManager requestWhenInUseAuthorization];
  }

  _locationManager.distanceFilter  = distanceFilter;
  _locationManager.desiredAccuracy = desiredAccuracy;
  // Start observing location
  [_locationManager startUpdatingLocation];
}

#pragma mark - Timeout handler

- (void)timeout:(NSTimer *)timer
{
  ABI13_0_0RCTLocationRequest *request = timer.userInfo;
  NSString *message = [NSString stringWithFormat: @"Unable to fetch location within %.1fs.", request.options.timeout];
  request.errorBlock(@[ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorTimeout, message)]);
  [_pendingRequests removeObject:request];

  // Stop updating if no pending requests
  if (_pendingRequests.count == 0 && !_observingLocation) {
    [_locationManager stopUpdatingLocation];
  }
}

#pragma mark - Public API

ABI13_0_0RCT_EXPORT_METHOD(startObserving:(ABI13_0_0RCTLocationOptions)options)
{
  checkLocationConfig();

  // Select best options
  _observerOptions = options;
  for (ABI13_0_0RCTLocationRequest *request in _pendingRequests) {
    _observerOptions.accuracy = MIN(_observerOptions.accuracy, request.options.accuracy);
  }

  [self beginLocationUpdatesWithDesiredAccuracy:_observerOptions.accuracy distanceFilter:_observerOptions.distanceFilter];
  _observingLocation = YES;
}

ABI13_0_0RCT_EXPORT_METHOD(stopObserving)
{
  // Stop observing
  _observingLocation = NO;

  // Stop updating if no pending requests
  if (_pendingRequests.count == 0) {
    [_locationManager stopUpdatingLocation];
  }
}

ABI13_0_0RCT_EXPORT_METHOD(getCurrentPosition:(ABI13_0_0RCTLocationOptions)options
                  withSuccessCallback:(ABI13_0_0RCTResponseSenderBlock)successBlock
                  errorCallback:(ABI13_0_0RCTResponseSenderBlock)errorBlock)
{
  checkLocationConfig();

  if (!successBlock) {
    ABI13_0_0RCTLogError(@"%@.getCurrentPosition called with nil success parameter.", [self class]);
    return;
  }

  if (![CLLocationManager locationServicesEnabled]) {
    if (errorBlock) {
      errorBlock(@[
        ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorUnavailable, @"Location services disabled.")
      ]);
      return;
    }
  }

  if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied) {
    if (errorBlock) {
      errorBlock(@[
        ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorDenied, nil)
      ]);
      return;
    }
  }

  // Check if previous recorded location exists and is good enough
  if (_lastLocationEvent &&
      [NSDate date].timeIntervalSince1970 - [ABI13_0_0RCTConvert NSTimeInterval:_lastLocationEvent[@"timestamp"]] < options.maximumAge &&
      [_lastLocationEvent[@"coords"][@"accuracy"] doubleValue] <= options.accuracy) {

    // Call success block with most recent known location
    successBlock(@[_lastLocationEvent]);
    return;
  }

  // Create request
  ABI13_0_0RCTLocationRequest *request = [ABI13_0_0RCTLocationRequest new];
  request.successBlock = successBlock;
  request.errorBlock = errorBlock ?: ^(NSArray *args){};
  request.options = options;
  request.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:options.timeout
                                                          target:self
                                                        selector:@selector(timeout:)
                                                        userInfo:request
                                                         repeats:NO];
  if (!_pendingRequests) {
    _pendingRequests = [NSMutableArray new];
  }
  [_pendingRequests addObject:request];

  // Configure location manager and begin updating location
  CLLocationAccuracy accuracy = options.accuracy;
  if (_locationManager) {
    accuracy = MIN(_locationManager.desiredAccuracy, accuracy);
  }
  [self beginLocationUpdatesWithDesiredAccuracy:accuracy distanceFilter:options.distanceFilter];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations
{
  // Create event
  CLLocation *location = locations.lastObject;
  _lastLocationEvent = @{
    @"coords": @{
      @"latitude": @(location.coordinate.latitude),
      @"longitude": @(location.coordinate.longitude),
      @"altitude": @(location.altitude),
      @"accuracy": @(location.horizontalAccuracy),
      @"altitudeAccuracy": @(location.verticalAccuracy),
      @"heading": @(location.course),
      @"speed": @(location.speed),
    },
    @"timestamp": @([location.timestamp timeIntervalSince1970] * 1000) // in ms
  };

  // Send event
  if (_observingLocation) {
    [self sendEventWithName:@"geolocationDidChange" body:_lastLocationEvent];
  }

  // Fire all queued callbacks
  for (ABI13_0_0RCTLocationRequest *request in _pendingRequests) {
    request.successBlock(@[_lastLocationEvent]);
    [request.timeoutTimer invalidate];
  }
  [_pendingRequests removeAllObjects];

  // Stop updating if not observing
  if (!_observingLocation) {
    [_locationManager stopUpdatingLocation];
  }

  // Reset location accuracy if desiredAccuracy is changed.
  // Otherwise update accuracy will force triggering didUpdateLocations, watchPosition would keeping receiving location updates, even there's no location changes.
  if (ABS(_locationManager.desiredAccuracy - ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY) > 0.000001) {
    _locationManager.desiredAccuracy = ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY;
  }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
  // Check error type
  NSDictionary<NSString *, id> *jsError = nil;
  switch (error.code) {
    case kCLErrorDenied:
      jsError = ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorDenied, nil);
      break;
    case kCLErrorNetwork:
      jsError = ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorUnavailable, @"Unable to retrieve location due to a network failure");
      break;
    case kCLErrorLocationUnknown:
    default:
      jsError = ABI13_0_0RCTPositionError(ABI13_0_0RCTPositionErrorUnavailable, nil);
      break;
  }

  // Send event
  if (_observingLocation) {
    [self sendEventWithName:@"geolocationError" body:jsError];
  }

  // Fire all queued error callbacks
  for (ABI13_0_0RCTLocationRequest *request in _pendingRequests) {
    request.errorBlock(@[jsError]);
    [request.timeoutTimer invalidate];
  }
  [_pendingRequests removeAllObjects];

  // Reset location accuracy if desiredAccuracy is changed.
  // Otherwise update accuracy will force triggering didUpdateLocations, watchPosition would keeping receiving location updates, even there's no location changes.
  if (ABS(_locationManager.desiredAccuracy - ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY) > 0.000001) {
    _locationManager.desiredAccuracy = ABI13_0_0RCT_DEFAULT_LOCATION_ACCURACY;
  }
}

static void checkLocationConfig()
{
#if ABI13_0_0RCT_DEV
  if (!([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"] ||
    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"])) {
    ABI13_0_0RCTLogError(@"Either NSLocationWhenInUseUsageDescription or NSLocationAlwaysUsageDescription key must be present in Info.plist to use geolocation.");
  }
#endif
}

@end
