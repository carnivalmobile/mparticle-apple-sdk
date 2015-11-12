//
//  MPBackend.m
//
//  Copyright 2015 mParticle, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "MPBackendController.h"
#import "MPPersistenceController.h"
#import "MPMessage.h"
#import "MPSession.h"
#import "MPConstants.h"
#import "MPStateMachine.h"
#import "MPNetworkPerformance.h"
#import "NSUserDefaults+mParticle.h"
#import "MPNetworkCommunication.h"
#import "MPBreadcrumb.h"
#import "MPExceptionHandler.h"
#import "MPUpload.h"
#import "MPCommand.h"
#import "MPSegment.h"
#import "MPApplication.h"
#import "MPCustomModule.h"
#import "MPMessageBuilder.h"
#import "MPAppDelegateProxy.h"
#import "MPNotificationController.h"
#import "MPStandaloneCommand.h"
#import "MPStandaloneMessage.h"
#import "MPStandaloneUpload.h"
#import "MPEvent.h"
#import "MPEvent+Internal.h"
#import "MPEventSet.h"
#import "MParticleUserNotification.h"
#import "MPMediaTrackContainer.h"
#import "MPMediaTrack.h"
#import "NSDictionary+MPCaseInsensitive.h"
#import "Hasher.h"
#import "MediaControl.h"
#import "MPMediaTrack+Internal.h"
#import "MPUploadBuilder.h"
#import "MPLogger.h"
#import "MPResponseEvents.h"
#import "MPConsumerInfo.h"
#import "MPResponseConfig.h"
#import "MPSessionHistory.h"
#import "MPCommerceEvent.h"
#import "MPCommerceEvent+Dictionary.h"
#import "MPCart.h"
#import "MPCart+Dictionary.h"
#import "MPEvent+MessageType.h"
#include "MessageTypeName.h"
#import "MPKitContainer.h"
#import "MPLocationManager.h"

#define METHOD_EXEC_MAX_ATTEMPT 10

using namespace mParticle;

const NSTimeInterval kMPRemainingBackgroundTimeMinimumThreshold = 1000;
const NSInteger kInvalidKey = 100;
const NSInteger kInvalidValue = 101;
const NSInteger kEmptyValueAttribute = 102;
const NSInteger kExceededNumberOfAttributesLimit = 103;
const NSInteger kExceededAttributeMaximumLength = 104;
const NSInteger kExceededKeyMaximumLength = 105;

static NSArray *execStatusDescriptions;
static BOOL appBackgrounded = NO;

@interface MPBackendController() <MPNotificationControllerDelegate> {
    MPAppDelegateProxy *appDelegateProxy;
    NSTimer *uploadTimer;
    NSMutableSet *deletedUserAttributes;
    NSTimer *backgroundTimer;
    __weak MPSession *sessionBeingUploaded;
    dispatch_queue_t backendQueue;
    dispatch_queue_t notificationsQueue;
    NSTimeInterval nextCleanUpTime;
    NSTimeInterval timeAppWentToBackground;
    NSTimeInterval backgroundStartTime;
    UIBackgroundTaskIdentifier backendBackgroundTaskIdentifier;
    BOOL originalAppDelegateProxied;
    BOOL retrievingSegments;
    BOOL appFinishedLaunching;
    BOOL longSession;
    BOOL resignedActive;
}

@property (nonatomic, strong) MPEventSet *eventSet;
@property (nonatomic, strong) MPMediaTrackContainer *mediaTrackContainer;
@property (nonatomic, strong) MPNetworkCommunication *networkCommunication;
@property (nonatomic, strong) MPNotificationController *notificationController;
@property (nonatomic, strong) MPSession *session;
@property (nonatomic, strong) NSMutableDictionary *userAttributes;
@property (nonatomic, strong) NSMutableArray *userIdentities;

@end


@implementation MPBackendController

@synthesize initializationStatus = _initializationStatus;
@synthesize uploadInterval = _uploadInterval;

+ (void)initialize {
    execStatusDescriptions = @[@"Success", @"Fail", @"Missing Parameter", @"Feature Disabled Remotely", @"Feature Enabled Remotely", @"User Opted Out of Tracking", @"Data Already Being Fetched",
                               @"Invalid Data Type", @"Data is Being Uploaded", @"Server is Busy", @"Item Not Found", @"Feature is Disabled in Settings", @"Delayed Execution",
                               @"Continued Delayed Execution", @"SDK Has Not Been Started Yet", @"There is no network connectivity"];
}

- (instancetype)initWithDelegate:(id<MPBackendControllerDelegate>)delegate {
    self = [super init];
    if (self) {
        _sessionTimeout = DEFAULT_SESSION_TIMEOUT;
        nextCleanUpTime = [[NSDate date] timeIntervalSince1970];
        backendBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
        retrievingSegments = NO;
        originalAppDelegateProxied = NO;
        _delegate = delegate;
        backgroundStartTime = 0;
        appFinishedLaunching = YES;
        longSession = NO;
        _initializationStatus = MPInitializationStatusNotStarted;
        resignedActive = NO;
        sessionBeingUploaded = nil;
        
        backendQueue = dispatch_queue_create("com.mParticle.BackendQueue", DISPATCH_QUEUE_SERIAL);
        notificationsQueue = dispatch_queue_create("com.mParticle.NotificationsQueue", DISPATCH_QUEUE_CONCURRENT);

        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationDidEnterBackground:)
                                   name:UIApplicationDidEnterBackgroundNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationWillEnterForeground:)
                                   name:UIApplicationWillEnterForegroundNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationDidFinishLaunching:)
                                   name:UIApplicationDidFinishLaunchingNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationWillTerminate:)
                                   name:UIApplicationWillTerminateNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleNetworkPerformanceNotification:)
                                   name:kMPNetworkPerformanceMeasurementNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleMemoryWarningNotification:)
                                   name:UIApplicationDidReceiveMemoryWarningNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleSignificantTimeChange:)
                                   name:UIApplicationSignificantTimeChangeNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationDidBecomeActive:)
                                   name:UIApplicationDidBecomeActiveNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleEventCounterLimitReached:)
                                   name:kMPEventCounterLimitReachedNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleDeviceTokenNotification:)
                                   name:kMPRemoteNotificationDeviceTokenNotification
                                 object:nil];
        
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationWillResignActive:)
                                   name:UIApplicationWillResignActiveNotification
                                 object:nil];
    }
    
    return self;
}

- (void)dealloc {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationDidFinishLaunchingNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
    [notificationCenter removeObserver:self name:kMPNetworkPerformanceMeasurementNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationSignificantTimeChangeNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [notificationCenter removeObserver:self name:kMPEventCounterLimitReachedNotification object:nil];
    [notificationCenter removeObserver:self name:kMPRemoteNotificationDeviceTokenNotification object:nil];
    [notificationCenter removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];

    [self endTimer];
}

#pragma mark Accessors
- (MPEventSet *)eventSet {
    if (_eventSet) {
        return _eventSet;
    }

    [self willChangeValueForKey:@"eventSet"];
    _eventSet = [[MPEventSet alloc] initWithCapacity:1];
    [self didChangeValueForKey:@"eventSet"];
    
    return _eventSet;
}

- (void)setInitializationStatus:(MPInitializationStatus)initializationStatus {
    _initializationStatus = initializationStatus;
}

- (MPMediaTrackContainer *)mediaTrackContainer {
    if (_mediaTrackContainer) {
        return _mediaTrackContainer;
    }
    
    [self willChangeValueForKey:@"mediaTrackContainer"];
    _mediaTrackContainer = [[MPMediaTrackContainer alloc] initWithCapacity:1];
    [self didChangeValueForKey:@"mediaTrackContainer"];
    
    return _mediaTrackContainer;
}

- (MPNetworkCommunication *)networkCommunication {
    if (_networkCommunication) {
        return _networkCommunication;
    }
    
    [self willChangeValueForKey:@"networkCommunication"];
    _networkCommunication = [[MPNetworkCommunication alloc] init];
    [self didChangeValueForKey:@"networkCommunication"];
    
    return _networkCommunication;
}

- (MPNotificationController *)notificationController {
    if (_notificationController) {
        return _notificationController;
    }
    
    [self willChangeValueForKey:@"notificationController"];
    _notificationController = [[MPNotificationController alloc] initWithDelegate:self];
    [self didChangeValueForKey:@"notificationController"];
    
    return _notificationController;
}

- (MPSession *)session {
    if (_session) {
        return _session;
    }
    
    [self beginSession:nil];
    
    return _session;
}

- (NSMutableDictionary *)userAttributes {
    if (_userAttributes) {
        return _userAttributes;
    }
    
    _userAttributes = [[NSMutableDictionary alloc] initWithCapacity:2];
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *userAttributes = userDefaults[kMPUserAttributeKey];
    if (userAttributes) {
        NSEnumerator *attributeEnumerator = [userAttributes keyEnumerator];
        NSString *key;
        id value;
        Class NSStringClass = [NSString class];
        
        while ((key = [attributeEnumerator nextObject])) {
            value = userAttributes[key];
            
            if ([value isKindOfClass:NSStringClass]) {
                _userAttributes[key] = ![userAttributes[key] isEqualToString:kMPNullUserAttributeString] ? value : [NSNull null];
            } else {
                _userAttributes[key] = value;
            }
        }
    }
    
    return _userAttributes;
}

- (NSMutableArray *)userIdentities {
    if (_userIdentities) {
        return _userIdentities;
    }
    
    _userIdentities = [[NSMutableArray alloc] initWithCapacity:10];
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSArray *userIdentityArray = userDefaults[kMPUserIdentityArrayKey];
    if (userIdentityArray) {
        [_userIdentities addObjectsFromArray:userIdentityArray];
    }
    
    return _userIdentities;
}

#pragma mark Private methods
- (NSDictionary *)attributesDictionaryForSession:(MPSession *)session {
    NSUInteger attributeCount = session.attributesDictionary.count;
    if (attributeCount == 0) {
        return nil;
    }
    
    NSMutableDictionary *attributesDictionary = [[NSMutableDictionary alloc] initWithCapacity:attributeCount];
    NSEnumerator *attributeEnumerator = [session.attributesDictionary keyEnumerator];
    NSString *key;
    id value;
    Class NSNumberClass = [NSNumber class];

    while ((key = [attributeEnumerator nextObject])) {
        value = session.attributesDictionary[key];
        attributesDictionary[key] = [value isKindOfClass:NSNumberClass] ? [(NSNumber *)value stringValue] : value;
    }
    
    return [attributesDictionary copy];
}

- (void)beginUploadTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [uploadTimer invalidate];
        uploadTimer = nil;
        
        uploadTimer = [NSTimer scheduledTimerWithTimeInterval:self.uploadInterval
                                                       target:self
                                                     selector:@selector(upload)
                                                     userInfo:nil
                                                      repeats:YES];
    });
}

- (void)broadcastSessionDidBegin:(MPSession *)session {
    [self.delegate sessionDidBegin:session];
    
    __weak MPBackendController *weakSelf = self;
    dispatch_async(notificationsQueue, ^{
        __strong MPBackendController *strongSelf = weakSelf;
        
        [[NSNotificationCenter defaultCenter] postNotificationName:mParticleSessionDidBeginNotification
                                                            object:strongSelf.delegate
                                                          userInfo:@{mParticleSessionId:@(session.sessionId)}];
    });
}

- (void)broadcastSessionDidEnd:(MPSession *)session {
    [self.mediaTrackContainer pruneMediaTracks];
    
    [self.delegate sessionDidEnd:session];
    
    __weak MPBackendController *weakSelf = self;
    NSNumber *sessionId = @(session.sessionId);
    dispatch_async(notificationsQueue, ^{
        __strong MPBackendController *strongSelf = weakSelf;
        
        [[NSNotificationCenter defaultCenter] postNotificationName:mParticleSessionDidEndNotification
                                                            object:strongSelf.delegate
                                                          userInfo:@{mParticleSessionId:sessionId}];
    });
}

- (void)cleanUp {
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (nextCleanUpTime < currentTime) {
        MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
        [persistence deleteExpiredUserNotifications];
        [persistence deleteRecordsOlderThan:(currentTime - ONE_HUNDRED_EIGHTY_DAYS)];
        nextCleanUpTime = currentTime + TWENTY_FOUR_HOURS;
    }
}

- (void)endTimer {
    [uploadTimer invalidate];
    uploadTimer = nil;
}

- (void)forceAppFinishedLaunching {
    appFinishedLaunching = NO;
}

- (void)handleBackgroundTimer:(NSTimer *)timer {
    NSTimeInterval backgroundTimeRemaining = [[UIApplication sharedApplication] backgroundTimeRemaining];

    if (backgroundTimeRemaining < kMPRemainingBackgroundTimeMinimumThreshold) {
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        __weak MPBackendController *weakSelf = self;
        
        void(^processSession)(NSTimeInterval) = ^(NSTimeInterval timeout) {
            __strong MPBackendController *strongSelf = weakSelf;
            
            [strongSelf->backgroundTimer invalidate];
            strongSelf->backgroundTimer = nil;
            strongSelf->longSession = NO;
            
            strongSelf.session.backgroundTime += timeout;
            
            [strongSelf processOpenSessionsIncludingCurrent:YES
                                          completionHandler:^(BOOL success) {
                                              [MPStateMachine setRunningInBackground:NO];
                                              [strongSelf broadcastSessionDidEnd:strongSelf->_session];
                                              strongSelf->_session = nil;
                                              
                                              if (strongSelf.eventSet.count == 0) {
                                                  strongSelf->_eventSet = nil;
                                              }
                                              
                                              if (strongSelf.mediaTrackContainer.count == 0) {
                                                  strongSelf->_mediaTrackContainer = nil;
                                              }
                                          }];
        };
        
        if (timer.timeInterval >= self.sessionTimeout) {
            processSession(self.sessionTimeout);
        } else if (backgroundStartTime == 0) {
            backgroundStartTime = currentTime;
        } else if ((currentTime - backgroundStartTime) >= self.sessionTimeout) {
            processSession(currentTime - timeAppWentToBackground);
        }
    } else {
        backgroundStartTime = 0;
        longSession = YES;
        
        if (!uploadTimer) {
            [self beginUploadTimer];
        }
    }
}

- (NSNumber *)previousSessionSuccessfullyClosed {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *stateMachineDirectoryPath = STATE_MACHINE_DIRECTORY_PATH;
    NSString *previousSessionStateFile = [stateMachineDirectoryPath stringByAppendingPathComponent:kMPPreviousSessionStateFileName];
    NSNumber *previousSessionSuccessfullyClosed = nil;
    if ([fileManager fileExistsAtPath:previousSessionStateFile]) {
        NSDictionary *previousSessionStateDictionary = [NSDictionary dictionaryWithContentsOfFile:previousSessionStateFile];
        previousSessionSuccessfullyClosed = previousSessionStateDictionary[kMPASTPreviousSessionSuccessfullyClosedKey];
    }
    
    if (!previousSessionSuccessfullyClosed) {
        previousSessionSuccessfullyClosed = @YES;
    }
    
    return previousSessionSuccessfullyClosed;
}

- (void)setPreviousSessionSuccessfullyClosed:(NSNumber *)previousSessionSuccessfullyClosed {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *stateMachineDirectoryPath = STATE_MACHINE_DIRECTORY_PATH;
    NSString *previousSessionStateFile = [stateMachineDirectoryPath stringByAppendingPathComponent:kMPPreviousSessionStateFileName];
    NSDictionary *previousSessionStateDictionary = @{kMPASTPreviousSessionSuccessfullyClosedKey:previousSessionSuccessfullyClosed};

    if (![fileManager fileExistsAtPath:stateMachineDirectoryPath]) {
        [fileManager createDirectoryAtPath:stateMachineDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    } else if ([fileManager fileExistsAtPath:previousSessionStateFile]) {
        [fileManager removeItemAtPath:previousSessionStateFile error:nil];
    }
    
    [previousSessionStateDictionary writeToFile:previousSessionStateFile atomically:YES];
}

- (void)processOpenSessionsIncludingCurrent:(BOOL)includeCurrentSession completionHandler:(void (^)(BOOL success))completionHandler {
    [self endTimer];
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    
    [persistence fetchSessions:^(NSMutableArray *sessions) {
        if (includeCurrentSession) {
            self.session.endTime = [[NSDate date] timeIntervalSince1970];
            [persistence updateSession:self.session];
        } else {
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"sessionId == %ld", self.session.sessionId];
            MPSession *currentSession = [[sessions filteredArrayUsingPredicate:predicate] lastObject];
            [sessions removeObject:currentSession];
            
            for (MPSession *openSession in sessions) {
                [self broadcastSessionDidEnd:openSession];
            }
        }
        
        [self uploadOpenSessions:sessions completionHandler:completionHandler];
    }];
}

- (void)processPendingArchivedMessages {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *crashLogsDirectoryPath = CRASH_LOGS_DIRECTORY_PATH;
    NSString *archivedMessagesDirectoryPath = ARCHIVED_MESSAGES_DIRECTORY_PATH;
    NSArray *directoryPaths = @[crashLogsDirectoryPath, archivedMessagesDirectoryPath];
    NSArray *fileExtensions = @[@".log", @".arcmsg"];
    
    [directoryPaths enumerateObjectsUsingBlock:^(NSString *directoryPath, NSUInteger idx, BOOL *stop) {
        if (![fileManager fileExistsAtPath:directoryPath]) {
            return;
        }
        
        NSArray *directoryContents = [fileManager contentsOfDirectoryAtPath:directoryPath error:nil];
        NSString *predicateFormat = [NSString stringWithFormat:@"self ENDSWITH '%@'", fileExtensions[idx]];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:predicateFormat];
        directoryContents = [directoryContents filteredArrayUsingPredicate:predicate];
        
        for (NSString *fileName in directoryContents) {
            NSString *filePath = [directoryPath stringByAppendingPathComponent:fileName];
            MPMessage *message = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
            
            if (message) {
                [self saveMessage:message updateSession:NO];
            }
            
            [fileManager removeItemAtPath:filePath error:nil];
        }
    }];
}

- (void)proxyOriginalAppDelegate {
    if (originalAppDelegateProxied) {
        return;
    }
    
    originalAppDelegateProxied = YES;
    
    UIApplication *application = [UIApplication sharedApplication];
    appDelegateProxy = [[MPAppDelegateProxy alloc] initWithOriginalAppDelegate:application.delegate];
    application.delegate = appDelegateProxy;
}

- (void)resetUserIdentitiesFirstTimeUseFlag {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF[%@] == %@", kMPIsFirstTimeUserIdentityHasBeenSet, @YES];
    NSArray *userIdentities = [self.userIdentities filteredArrayUsingPredicate:predicate];
    
    for (NSDictionary *userIdentity in userIdentities) {
        MPUserIdentity identityType = (MPUserIdentity)[userIdentity[kMPUserIdentityTypeKey] integerValue];

        [self setUserIdentity:userIdentity[kMPUserIdentityIdKey]
                 identityType:identityType
                      attempt:0
            completionHandler:^(NSString *identityString, MPUserIdentity identityType, MPExecStatus execStatus) {
                
            }];
    }
}

- (void)saveMessage:(MPDataModelAbstract *)abstractMessage updateSession:(BOOL)updateSession {
    __weak MPBackendController *weakSelf = self;
    void (^uploadMessage)() = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong MPBackendController *strongSelf = weakSelf;
            [strongSelf upload];
        });
    };
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    
    if ([abstractMessage isKindOfClass:[MPMessage class]]) {
        MPMessage *message = (MPMessage *)abstractMessage;
        MPMessageType messageTypeCode = (MPMessageType)MessageTypeName::messageTypeForName(string([message.messageType UTF8String]));
        if (messageTypeCode == MPMessageTypeBreadcrumb) {
            [persistence saveBreadcrumb:message session:self.session];
        } else {
            [persistence saveMessage:message];
        }

        MPLogVerbose(@"Source Event Id: %@", message.uuid);

        if (updateSession) {
            if (self.session.persisted) {
                self.session.endTime = [[NSDate date] timeIntervalSince1970];
                [persistence updateSession:self.session];
            } else {
                [persistence saveSession:self.session];
            }
        }
        
        dispatch_async(backendQueue, ^{
            MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
            BOOL shouldUpload = [stateMachine.triggerMessageTypes containsObject:message.messageType];
            
            if (!shouldUpload && stateMachine.triggerEventTypes) {
                NSError *error = nil;
                NSDictionary *messageDictionary = [message dictionaryRepresentation];
                NSString *eventName = messageDictionary[kMPEventNameKey];
                NSString *eventType = messageDictionary[kMPEventTypeKey];
                
                if (!error && eventName && eventType) {
                    NSString *hashedEvent = [NSString stringWithCString:Hasher::hashEvent([eventName cStringUsingEncoding:NSUTF8StringEncoding], [eventType cStringUsingEncoding:NSUTF8StringEncoding]).c_str()
                                                               encoding:NSUTF8StringEncoding];
                    
                    shouldUpload = [stateMachine.triggerEventTypes containsObject:hashedEvent];
                }
            }
            
            if (shouldUpload) {
                uploadMessage();
            }
        });
    } else if ([abstractMessage isKindOfClass:[MPStandaloneMessage class]]) {
        [persistence saveStandaloneMessage:(MPStandaloneMessage *)abstractMessage];
        uploadMessage();
    }
}

- (void)uploadMessagesFromSession:(MPSession *)session completionHandler:(void(^)(MPSession *uploadedSession))completionHandler {
    if ([sessionBeingUploaded isEqual:session]) {
        return;
    }
    
    const void (^completionHandlerCopy)(MPSession *) = [completionHandler copy];
    MPSession *uploadSession = [session copy];
    sessionBeingUploaded = uploadSession;
    __weak MPBackendController *weakSelf = self;
    MPNetworkCommunication *networkCommunication = [[MPNetworkCommunication alloc] init];
    
    [networkCommunication requestConfig:^(BOOL success, NSDictionary *configurationDictionary) {
        if (!success) {
            sessionBeingUploaded = nil;
            completionHandlerCopy(nil);
            return;
        }
        
        __strong MPBackendController *strongSelf = weakSelf;
        
        MPResponseConfig *responseConfig = [[MPResponseConfig alloc] initWithConfiguration:configurationDictionary];
        
        if (responseConfig.influencedOpenTimer) {
            strongSelf.notificationController.influencedOpenTimer = [responseConfig.influencedOpenTimer doubleValue];
        }
        
        MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
        
        [persistence fetchMessagesForUploadingInSession:uploadSession
                                      completionHandler:^(NSArray *messages) {
                                          if (!messages) {
                                              sessionBeingUploaded = nil;
                                              completionHandlerCopy(uploadSession);
                                              return;
                                          }
                                          
                                          MPUploadBuilder *uploadBuilder = [MPUploadBuilder newBuilderWithSession:uploadSession messages:messages sessionTimeout:strongSelf.sessionTimeout uploadInterval:strongSelf.uploadInterval];
                                          
                                          if (!uploadBuilder) {
                                              sessionBeingUploaded = nil;
                                              completionHandlerCopy(uploadSession);
                                              return;
                                          }
                                          
                                          [uploadBuilder withUserAttributes:strongSelf.userAttributes deletedUserAttributes:deletedUserAttributes];
                                          [uploadBuilder withUserIdentities:strongSelf.userIdentities];
                                          [uploadBuilder build:^(MPDataModelAbstract *upload) {
                                              [persistence saveUpload:(MPUpload *)upload messageIds:uploadBuilder.preparedMessageIds operation:MPPersistenceOperationFlag];
                                              [strongSelf resetUserIdentitiesFirstTimeUseFlag];
                                              
                                              [persistence fetchUploadsInSession:session
                                                               completionHandler:^(NSArray *uploads) {
                                                                   if (!uploads) {
                                                                       sessionBeingUploaded = nil;
                                                                       completionHandlerCopy(uploadSession);
                                                                       return;
                                                                   }
                                                                   
                                                                   if ([MPStateMachine sharedInstance].dataRamped) {
                                                                       for (MPUpload *upload in uploads) {
                                                                           [persistence deleteUpload:upload];
                                                                       }
                                                                       
                                                                       [persistence deleteNetworkPerformanceMessages];
                                                                       return;
                                                                   }
                                                                   
                                                                   [networkCommunication upload:uploads
                                                                                          index:0
                                                                              completionHandler:^(BOOL success, MPUpload *upload, NSDictionary *responseDictionary, BOOL finished) {
                                                                                  if (!success) {
                                                                                      return;
                                                                                  }
                                                                                  
                                                                                  [MPResponseEvents parseConfiguration:responseDictionary session:uploadSession];
                                                                                  
                                                                                  [persistence deleteUpload:upload];
                                                                                  
                                                                                  if (!finished) {
                                                                                      return;
                                                                                  }
                                                                                  
                                                                                  [persistence fetchCommandsInSession:uploadSession
                                                                                                    completionHandler:^(NSArray *commands) {
                                                                                                        if (!commands) {
                                                                                                            sessionBeingUploaded = nil;
                                                                                                            completionHandlerCopy(uploadSession);
                                                                                                            return;
                                                                                                        }
                                                                                                        
                                                                                                        [networkCommunication sendCommands:commands
                                                                                                                                     index:0
                                                                                                                         completionHandler:^(BOOL success, MPCommand *command, BOOL finished) {
                                                                                                                             if (!success || !networkCommunication) {
                                                                                                                                 sessionBeingUploaded = nil;
                                                                                                                                 completionHandlerCopy(uploadSession);
                                                                                                                                 return;
                                                                                                                             }
                                                                                                                             
                                                                                                                             [persistence deleteCommand:command];
                                                                                                                             
                                                                                                                             if (finished) {
                                                                                                                                 sessionBeingUploaded = nil;
                                                                                                                                 completionHandlerCopy(uploadSession);
                                                                                                                             }
                                                                                                                         }];
                                                                                                    }];
                                                                              }];
                                                               }];
                                          }];
                                          
                                          deletedUserAttributes = nil;
                                      }];
    }];
}

- (void)uploadOpenSessions:(NSMutableArray *)openSessions completionHandler:(void (^)(BOOL success))completionHandler {
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];

    if (!openSessions || openSessions.count == 0) {
        [persistence deleteMessagesWithNoSession];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(YES);
        });
        
        return;
    }
    
    __block MPSession *session = [openSessions[0] copy];
    [openSessions removeObjectAtIndex:0];
    NSMutableDictionary *messageInfo = [@{kMPSessionLengthKey:MPMilliseconds(session.foregroundTime),
                                          kMPSessionTotalLengthKey:MPMilliseconds(session.length)}
                                        mutableCopy];
    
    NSDictionary *sessionAttributesDictionary = [self attributesDictionaryForSession:session];
    if (sessionAttributesDictionary) {
        messageInfo[kMPAttributesKey] = sessionAttributesDictionary;
    }
    
    MPMessage *message = [persistence fetchSessionEndMessageInSession:session];
    if (!message) {
        MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeSessionEnd session:session messageInfo:messageInfo];
        if ([MPLocationManager trackingLocation]) {
            messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
        }
        message = (MPMessage *)[[messageBuilder withTimestamp:session.endTime] build];
        
        [self saveMessage:message updateSession:NO];
        MPLogVerbose(@"Session Ended: %@", session.uuid);
    }
    
    if ([MPStateMachine sharedInstance].networkStatus != NotReachable) {
        [self uploadMessagesFromSession:session completionHandler:^(MPSession *uploadedSession) {
            session = nil;
            
            if (uploadedSession) {
                [self uploadSessionHistory:uploadedSession completionHandler:^(BOOL sessionHistorySuccess) {
                    if (sessionHistorySuccess) {
                        [self uploadOpenSessions:openSessions completionHandler:completionHandler];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completionHandler(NO);
                        });
                    }
                }];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(NO);
                });
            }
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(NO);
        });
    }
}

- (void)uploadSessionHistory:(MPSession *)session completionHandler:(void (^)(BOOL sessionHistorySuccess))completionHandler {
    if (!session) {
        return;
    }
    
    __weak MPBackendController *weakSelf = self;
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];

    [persistence fetchUploadedMessagesInSession:session
              excludeNetworkPerformanceMessages:NO
                              completionHandler:^(NSArray *messages) {
                                  if (!messages) {
                                      if (completionHandler) {
                                          completionHandler(NO);
                                      }
                                      
                                      return;
                                  }
                                  
                                  __strong MPBackendController *strongSelf = weakSelf;
                                  
                                  MPUploadBuilder *uploadBuilder = [MPUploadBuilder newBuilderWithSession:session
                                                                                                 messages:messages
                                                                                           sessionTimeout:strongSelf.sessionTimeout
                                                                                           uploadInterval:strongSelf.uploadInterval];
                                  
                                  if (!uploadBuilder) {
                                      if (completionHandler) {
                                          completionHandler(NO);
                                      }
                                      
                                      return;
                                  }
                                  
                                  [uploadBuilder withUserAttributes:strongSelf.userAttributes deletedUserAttributes:deletedUserAttributes];
                                  [uploadBuilder withUserIdentities:strongSelf.userIdentities];
                                  [uploadBuilder build:^(MPDataModelAbstract *upload) {
                                      [persistence saveUpload:(MPUpload *)upload messageIds:uploadBuilder.preparedMessageIds operation:MPPersistenceOperationDelete];
                                      
                                      [persistence fetchUploadsInSession:session
                                                       completionHandler:^(NSArray *uploads) {
                                                           MPSessionHistory *sessionHistory = [[MPSessionHistory alloc] initWithSession:session uploads:uploads];
                                                           sessionHistory.userAttributes = self.userAttributes;
                                                           sessionHistory.userIdentities = self.userIdentities;
                                                           
                                                           if (!sessionHistory) {
                                                               if (completionHandler) {
                                                                   completionHandler(NO);
                                                               }
                                                               
                                                               return;
                                                           }
                                                           
                                                           [strongSelf.networkCommunication uploadSessionHistory:sessionHistory
                                                                                               completionHandler:^(BOOL success) {
                                                                                                   void (^deleteUploadIds)(NSArray *uploadIds) = ^(NSArray *uploadIds) {
                                                                                                       for (NSNumber *uploadId in sessionHistory.uploadIds) {
                                                                                                           [persistence deleteUploadId:[uploadId intValue]];
                                                                                                       }
                                                                                                   };
                                                                                                   
                                                                                                   if (!success) {
                                                                                                       if (completionHandler) {
                                                                                                           completionHandler(NO);
                                                                                                       }
                                                                                                       
                                                                                                       return;
                                                                                                   }
                                                                                                   
                                                                                                   deleteUploadIds(sessionHistory.uploadIds);
                                                                                                   
                                                                                                   [persistence archiveSession:session
                                                                                                             completionHandler:^(MPSession *archivedSession) {
                                                                                                                 [persistence deleteSession:archivedSession];
                                                                                                                 [persistence deleteNetworkPerformanceMessages];
                                                                                                                 
                                                                                                                 if (completionHandler) {
                                                                                                                     completionHandler(YES);
                                                                                                                 }
                                                                                                             }];
                                                                                               }];
                                                       }];
                                  }];
                              }];
}

- (void)uploadStandaloneMessages {
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    NSArray *standaloneMessages = [persistence fetchStandaloneMessages];
    
    if (!standaloneMessages) {
        return;
    }
    
    MPUploadBuilder *uploadBuilder = [MPUploadBuilder newBuilderWithMessages:standaloneMessages uploadInterval:self.uploadInterval];
    
    if (!uploadBuilder) {
        return;
    }
    
    [uploadBuilder withUserAttributes:self.userAttributes deletedUserAttributes:deletedUserAttributes];
    [uploadBuilder withUserIdentities:self.userIdentities];
    [uploadBuilder build:^(MPDataModelAbstract *standaloneUpload) {
        [persistence saveStandaloneUpload:(MPStandaloneUpload *)standaloneUpload];
        [persistence deleteStandaloneMessageIds:uploadBuilder.preparedMessageIds];
    }];

    NSArray *standaloneUploads = [persistence fetchStandaloneUploads];
    if (!standaloneUploads) {
        return;
    }
    
    if ([MPStateMachine sharedInstance].dataRamped) {
        for (MPStandaloneUpload *standaloneUpload in standaloneUploads) {
            [persistence deleteStandaloneUpload:standaloneUpload];
        }
        
        return;
    }
    
    __weak MPBackendController *weakSelf = self;
    
    [self.networkCommunication standaloneUploads:standaloneUploads
                                           index:0
                               completionHandler:^(BOOL success, MPStandaloneUpload *standaloneUpload, NSDictionary *responseDictionary, BOOL finished) {
                                   __strong MPBackendController *strongSelf = weakSelf;
                                   
                                   if (!success) {
                                       return;
                                   }
                                   
                                   [MPResponseEvents parseConfiguration:responseDictionary session:nil];
                                   
                                   [persistence deleteStandaloneUpload:standaloneUpload];
                                   
                                   if (!finished) {
                                       return;
                                   }
                                   
                                   NSArray *standaloneCommands = [persistence fetchStandaloneCommands];
                                   if (!standaloneCommands) {
                                       return;
                                   }
                                   
                                   [strongSelf.networkCommunication sendStandaloneCommands:standaloneCommands
                                                                                     index:0
                                                                         completionHandler:^(BOOL success, MPStandaloneCommand *standaloneCommand, BOOL finished) {
                                                                             if (!success) {
                                                                                 return;
                                                                             }
                                                                             
                                                                             [persistence deleteStandaloneCommand:standaloneCommand];
                                                                         }];
                               }];
}

#pragma mark Notification handlers
- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    if (appBackgrounded || [MPStateMachine runningInBackground]) {
        return;
    }
    
    appBackgrounded = YES;
    [MPStateMachine setRunningInBackground:YES];
    
    timeAppWentToBackground = [[NSDate date] timeIntervalSince1970];
    
    [self setPreviousSessionSuccessfullyClosed:@YES];

    [self endTimer];
    [self cleanUp];

    if ([MPLocationManager trackingLocation] && ![MPStateMachine sharedInstance].locationManager.backgroundLocationTracking) {
        [[MPStateMachine sharedInstance].locationManager.locationManager stopUpdatingLocation];
    }
    
    NSMutableDictionary *messageInfo = [@{kMPAppStateTransitionType:kMPASTBackgroundKey} mutableCopy];
    
    if (self.notificationController.initialRedactedUserNotificationString) {
        messageInfo[kMPPushMessagePayloadKey] = self.notificationController.initialRedactedUserNotificationString;
    }
    
    MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeAppStateTransition session:self.session messageInfo:messageInfo];
    if ([MPLocationManager trackingLocation]) {
        messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
    }
    MPMessage *message = (MPMessage *)[messageBuilder build];
    
    [self.session suspendSession];
    [self saveMessage:message updateSession:YES];

    MPLogVerbose(@"Application Did Enter Background");

    [self upload];
    
    backgroundTimer = [NSTimer scheduledTimerWithTimeInterval:(MINIMUM_SESSION_TIMEOUT + 0.1)
                                                       target:self
                                                     selector:@selector(handleBackgroundTimer:)
                                                     userInfo:nil
                                                      repeats:YES];

    
    __weak MPBackendController *weakSelf = self;
    if (backendBackgroundTaskIdentifier == UIBackgroundTaskInvalid) {
        backendBackgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            __strong MPBackendController *strongSelf = weakSelf;

            [MPStateMachine setRunningInBackground:NO];
            
            if (strongSelf->backgroundTimer) {
                [strongSelf->backgroundTimer invalidate];
                strongSelf->backgroundTimer = nil;
            }

            if (strongSelf->_session) {
                [strongSelf broadcastSessionDidEnd:strongSelf->_session];
                strongSelf->_session = nil;
                
                if (strongSelf.eventSet.count == 0) {
                    strongSelf->_eventSet = nil;
                }
                
                if (strongSelf.mediaTrackContainer.count == 0) {
                    strongSelf->_mediaTrackContainer = nil;
                }
            }
            
            [[MPPersistenceController sharedInstance] purgeMemory];
            
            MPLogDebug(@"SDK has become dormant with the app.");
            
            [[UIApplication sharedApplication] endBackgroundTask:strongSelf->backendBackgroundTaskIdentifier];
            strongSelf->backendBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
        }];
    }
}

- (void)handleApplicationWillEnterForeground:(NSNotification *)notification {
    backgroundStartTime = 0;
    
    if (backgroundTimer) {
        [backgroundTimer invalidate];
        backgroundTimer = nil;
    }

    appBackgrounded = NO;
    [MPStateMachine setRunningInBackground:NO];
    resignedActive = NO;

    if (backendBackgroundTaskIdentifier != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:backendBackgroundTaskIdentifier];
        backendBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
    }
    
    if ([MPLocationManager trackingLocation] && ![MPStateMachine sharedInstance].locationManager.backgroundLocationTracking) {
        [[MPStateMachine sharedInstance].locationManager.locationManager startUpdatingLocation];
    }
    
    __weak MPBackendController *weakSelf = self;
    [self.networkCommunication requestConfig:^(BOOL success, NSDictionary *configurationDictionary) {
        __strong MPBackendController *strongSelf = weakSelf;
        
        if (success && [configurationDictionary[kMPMessageTypeKey] isEqualToString:kMPMessageTypeConfig]) {
            MPResponseConfig *responseConfig = [[MPResponseConfig alloc] initWithConfiguration:configurationDictionary];
            
            if (responseConfig.influencedOpenTimer) {
                strongSelf.notificationController.influencedOpenTimer = [responseConfig.influencedOpenTimer doubleValue];
            }
        }
    }];
}

- (void)handleApplicationDidFinishLaunching:(NSNotification *)notification {
    NSString *astType = kMPASTInitKey;
    NSMutableDictionary *messageInfo = [[NSMutableDictionary alloc] initWithCapacity:3];
    NSDictionary *userInfo = [notification userInfo];
    NSDictionary *pushNotificationDictionary = userInfo[UIApplicationLaunchOptionsRemoteNotificationKey];
    MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
    MParticleUserNotification *userNotification = nil;
    
    if (stateMachine.installationType == MPInstallationTypeKnownInstall) {
        messageInfo[kMPASTIsFirstRunKey] = @YES;
        [self.delegate forwardLogInstall];
    } else if (stateMachine.installationType == MPInstallationTypeKnownUpgrade) {
        messageInfo[kMPASTIsUpgradeKey] = @YES;
        [self.delegate forwardLogUpdate];
    }
    
    messageInfo[kMPASTPreviousSessionSuccessfullyClosedKey] = [self previousSessionSuccessfullyClosed];
    
    BOOL sessionFinalized = YES;
    
    if (pushNotificationDictionary) {
        astType = kMPASTForegroundKey;
        userNotification = [self.notificationController newUserNotificationWithDictionary:pushNotificationDictionary
                                                                         actionIdentifier:nil
                                                                                    state:kMPPushNotificationStateNotRunning];
        
        if (userNotification.redactedUserNotificationString) {
            messageInfo[kMPPushMessagePayloadKey] = userNotification.redactedUserNotificationString;
        }

        if (_session) {
            NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
            NSTimeInterval backgroundedTime = (currentTime - _session.endTime) > 0 ? (currentTime - _session.endTime) : 0;
            sessionFinalized = backgroundedTime > self.sessionTimeout;
        }
    }
    
    messageInfo[kMPAppStateTransitionType] = astType;
    
    MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeAppStateTransition session:self.session messageInfo:messageInfo];
    
    if ([MPLocationManager trackingLocation]) {
        messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
    }
    messageBuilder = [messageBuilder withStateTransition:sessionFinalized previousSession:nil];
    MPMessage *message = (MPMessage *)[messageBuilder build];
    
    [self saveMessage:message updateSession:YES];
    
    if (userNotification) {
        [self receivedUserNotification:userNotification];
    }
    
    MPLogVerbose(@"Application Did Finish Launching");
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeAppStateTransition session:_session messageInfo:@{kMPAppStateTransitionType:kMPASTExitKey}];
    
    MPMessage *message = (MPMessage *)[messageBuilder build];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *archivedMessagesDirectoryPath = ARCHIVED_MESSAGES_DIRECTORY_PATH;
    if (![fileManager fileExistsAtPath:archivedMessagesDirectoryPath]) {
        [fileManager createDirectoryAtPath:archivedMessagesDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString *messagePath = [archivedMessagesDirectoryPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%.0f.arcmsg", message.uuid, message.timestamp]];
    BOOL messageArchived = [NSKeyedArchiver archiveRootObject:message toFile:messagePath];
    if (!messageArchived) {
        MPLogError(@"Application Will Terminate message not archived.");
    }
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];

    if (persistence.databaseOpen) {
        if (_session) {
            _session.endTime = [[NSDate date] timeIntervalSince1970];
            [persistence updateSession:_session];
        }
        
        [persistence closeDatabase];
    }

    if (backendBackgroundTaskIdentifier != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:backendBackgroundTaskIdentifier];
        backendBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
    }
}

- (void)handleMemoryWarningNotification:(NSNotification *)notification {
    self.userAttributes = nil;
    self.userIdentities = nil;
}

- (void)handleNetworkPerformanceNotification:(NSNotification *)notification {
    if (!_session) {
        return;
    }
    
    NSDictionary *userInfo = [notification userInfo];
    MPNetworkPerformance *networkPerformance = userInfo[kMPNetworkPerformanceKey];
    
    [self logNetworkPerformanceMeasurement:networkPerformance attempt:0 completionHandler:nil];
}

- (void)handleSignificantTimeChange:(NSNotification *)notification {
    if (_session) {
        [self beginSession:nil];
    }
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    if (appFinishedLaunching || [MPStateMachine sharedInstance].optOut) {
        appFinishedLaunching = NO;
        return;
    }
    
    if (resignedActive) {
        resignedActive = NO;
        return;
    }
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval backgroundedTime = (currentTime - _session.endTime) > 0 ? (currentTime - _session.endTime) : 0;
    BOOL sessionExpired = backgroundedTime > self.sessionTimeout && !longSession;

    void (^appStateTransition)(MPSession *, MPSession *, BOOL) = ^(MPSession *session, MPSession *previousSession, BOOL sessionExpired) {
        MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeAppStateTransition session:session messageInfo:@{kMPAppStateTransitionType:kMPASTForegroundKey}];
        messageBuilder = [messageBuilder withStateTransition:sessionExpired previousSession:previousSession];
        if ([MPLocationManager trackingLocation]) {
            messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
        }
        
        MPMessage *message = (MPMessage *)[messageBuilder build];
        
        [self saveMessage:message updateSession:YES];
        
        MPLogVerbose(@"Application Did Become Active");
    };
    
    if (sessionExpired) {
        [self beginSession:^(MPSession *session, MPSession *previousSession, MPExecStatus execStatus) {
            [self processOpenSessionsIncludingCurrent:NO completionHandler:^(BOOL success) {
                [self beginUploadTimer];
            }];
            
            appStateTransition(session, previousSession, sessionExpired);
        }];
    } else {
        self.session.backgroundTime += currentTime - timeAppWentToBackground;
        timeAppWentToBackground = 0.0;
        _session.endTime = currentTime;
        [[MPPersistenceController sharedInstance] updateSession:_session];
        
        appStateTransition(self.session, nil, sessionExpired);
        [self beginUploadTimer];
    }
}

- (void)handleEventCounterLimitReached:(NSNotification *)notification {
    MPLogDebug(@"The event limit has been exceeded for this session. Automatically begining a new session.");
    [self beginSession:nil];
}

- (void)handleDeviceTokenNotification:(NSNotification *)notification {
    NSDictionary *userInfo = [notification userInfo];
    NSData *deviceToken = userInfo[kMPRemoteNotificationDeviceTokenKey];
    NSData *oldDeviceToken = userInfo[kMPRemoteNotificationOldDeviceTokenKey];
    
    if ((!deviceToken && !oldDeviceToken) || [deviceToken isEqualToData:oldDeviceToken]) {
        return;
    }
    
    NSData *logDeviceToken;
    NSString *status;
    NSUInteger notificationTypes;
    BOOL pushNotificationsEnabled = deviceToken != nil;
    if (pushNotificationsEnabled) {
        logDeviceToken = deviceToken;
        status = @"true";
    } else if (!pushNotificationsEnabled && oldDeviceToken) {
        logDeviceToken = oldDeviceToken;
        status = @"false";
    }
    
    if ([[UIDevice currentDevice].systemVersion floatValue] >= 8.0) {
        UIUserNotificationSettings *userNotificationSettings = [[UIApplication sharedApplication] currentUserNotificationSettings];
        notificationTypes = userNotificationSettings.types;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        notificationTypes = [[UIApplication sharedApplication] enabledRemoteNotificationTypes];
#pragma clang diagnostic pop
    }
    
    NSMutableDictionary *messageInfo = [@{kMPDeviceTokenKey:[NSString stringWithFormat:@"%@", logDeviceToken],
                                          kMPPushStatusKey:status,
                                          kMPDeviceSupportedPushNotificationTypesKey:@(notificationTypes)}
                                        mutableCopy];
    
    if ([MPStateMachine sharedInstance].deviceTokenType.length > 0) {
        messageInfo[kMPDeviceTokenTypeKey] = [MPStateMachine sharedInstance].deviceTokenType;
    }
    
    MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypePushRegistration session:self.session messageInfo:messageInfo];
    MPMessage *message = (MPMessage *)[messageBuilder build];
    
    [self saveMessage:message updateSession:YES];
    
    if (deviceToken) {
        MPLogDebug(@"Set Device Token: %@", deviceToken);
    } else {
        MPLogDebug(@"Reset Device Token: %@", oldDeviceToken);
    }
}

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    resignedActive = YES;
}

#pragma mark MPNotificationControllerDelegate
- (void)receivedUserNotification:(MParticleUserNotification *)userNotification {
    switch (userNotification.command) {
        case MPUserNotificationCommandAlertUserLocalTime:
            [self.notificationController scheduleNotification:userNotification];
            break;
            
        case MPUserNotificationCommandConfigRefresh: {
            __weak MPBackendController *weakSelf = self;
            
            [self.networkCommunication requestConfig:^(BOOL success, NSDictionary *configurationDictionary) {
                __strong MPBackendController *strongSelf = weakSelf;
                
                if (success) {
                    MPResponseConfig *responseConfig = [[MPResponseConfig alloc] initWithConfiguration:configurationDictionary];
                    
                    if (responseConfig.influencedOpenTimer) {
                        strongSelf.notificationController.influencedOpenTimer = [responseConfig.influencedOpenTimer doubleValue];
                    }
                }
            }];
        }
            break;
            
            
        case MPUserNotificationCommandDoNothing:
            return;
            break;
            
        default:
            break;
    }

    if (userNotification.shouldPersist) {
        if (userNotification.userNotificationId) {
            [[MPPersistenceController sharedInstance] updateUserNotification:userNotification];
        } else {
            [[MPPersistenceController sharedInstance] saveUserNotification:userNotification];
        }
    }
    
    NSMutableDictionary *messageInfo = [@{kMPDeviceTokenKey:[NSString stringWithFormat:@"%@", [MPNotificationController deviceToken]],
                                          kMPPushNotificationStateKey:userNotification.state,
                                          kMPPushMessageProviderKey:kMPPushMessageProviderValue,
                                          kMPPushMessageTypeKey:userNotification.type}
                                        mutableCopy];
    
    if (userNotification.redactedUserNotificationString) {
        messageInfo[kMPPushMessagePayloadKey] = userNotification.redactedUserNotificationString;
    }
    
    if (userNotification.actionIdentifier) {
        messageInfo[kMPPushNotificationActionIdentifierKey] = userNotification.actionIdentifier;
        messageInfo[kMPPushNotificationCategoryIdentifierKey] = userNotification.categoryIdentifier;
    }

    if (userNotification.actionTitle) {
        messageInfo[kMPPushNotificationActionTileKey] = userNotification.actionTitle;
    }
    
    if (userNotification.behavior > 0) {
        messageInfo[kMPPushNotificationBehaviorKey] = @(userNotification.behavior);
    }
    
    MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypePushNotification session:_session messageInfo:messageInfo];
    if ([MPLocationManager trackingLocation]) {
        messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
    }
    MPDataModelAbstract *message = [messageBuilder build];
    
    [self saveMessage:message updateSession:(_session != nil)];
}

#pragma mark Public accessors
- (void)setSessionTimeout:(NSTimeInterval)sessionTimeout {
    if (sessionTimeout == _sessionTimeout) {
        return;
    }
    
    _sessionTimeout = MIN(MAX(sessionTimeout, MINIMUM_SESSION_TIMEOUT), MAXIMUM_SESSION_TIMEOUT);
}

- (NSTimeInterval)uploadInterval {
    if (_uploadInterval == 0.0) {
        _uploadInterval = [MPStateMachine environment] == MPEnvironmentDevelopment ? DEFAULT_DEBUG_UPLOAD_INTERVAL : DEFAULT_UPLOAD_INTERVAL;
    }
    
    return _uploadInterval;
}

- (void)setUploadInterval:(NSTimeInterval)uploadInterval {
    if (uploadInterval == _uploadInterval) {
        return;
    }
    
    _uploadInterval = MAX(uploadInterval, 1.0);
    
    if (uploadTimer) {
        [self beginUploadTimer];
    }
}

#pragma mark Public methods
- (MPExecStatus)beginLocationTrackingWithAccuracy:(CLLocationAccuracy)accuracy distanceFilter:(CLLocationDistance)distance authorizationRequest:(MPLocationAuthorizationRequest)authorizationRequest {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Location tracking cannot begin prior to starting the mParticle SDK.\n****\n");

    if ([[MPStateMachine sharedInstance].locationTrackingMode isEqualToString:kMPRemoteConfigForceFalse]) {
        return MPExecStatusDisabledRemotely;
    }
    
    MPLocationManager *locationManager = [[MPLocationManager alloc] initWithAccuracy:accuracy distanceFilter:distance authorizationRequest:authorizationRequest];
    [MPStateMachine sharedInstance].locationManager = locationManager ? : nil;
    
    return MPExecStatusSuccess;
}

- (MPExecStatus)endLocationTracking {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Location tracking cannot end prior to starting the mParticle SDK.\n****\n");

    if ([[MPStateMachine sharedInstance].locationTrackingMode isEqualToString:kMPRemoteConfigForceTrue]) {
        return MPExecStatusEnabledRemotely;
    }
    
    [[MPStateMachine sharedInstance].locationManager endLocationTracking];
    [MPStateMachine sharedInstance].locationManager = nil;
    
    return MPExecStatusSuccess;
}

- (void)beginSession:(void (^)(MPSession *session, MPSession *previousSession, MPExecStatus execStatus))completionHandler {
    MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
    if (stateMachine.optOut) {
        if (completionHandler) {
            completionHandler(nil, nil, MPExecStatusOptOut);
        }
        
        return;
    }
    
    if (_session) {
        [self endSession];
    }
    
    [self willChangeValueForKey:@"session"];
    
    _session = [[MPSession alloc] initWithStartTime:[[NSDate date] timeIntervalSince1970]];
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];

    [persistence fetchPreviousSession:^(MPSession *previousSession) {
        NSMutableDictionary *messageInfo = [[NSMutableDictionary alloc] initWithCapacity:2];
        NSInteger previousSessionLength = 0;
        if (previousSession) {
            previousSessionLength = trunc(previousSession.length);
            messageInfo[kMPPreviousSessionIdKey] = previousSession.uuid;
            messageInfo[kMPPreviousSessionStartKey] = MPMilliseconds(previousSession.startTime);
        }
        
        messageInfo[kMPPreviousSessionLengthKey] = @(previousSessionLength);
        
        MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeSessionStart session:_session messageInfo:messageInfo];
        MPMessage *message = (MPMessage *)[[messageBuilder withTimestamp:_session.startTime] build];
        
        [self saveMessage:message updateSession:YES];
        
        if (completionHandler) {
            completionHandler(_session, previousSession, MPExecStatusSuccess);
        }
    }];
    
    [persistence saveSession:_session];
    
    stateMachine.currentSession = _session;
    
    [self didChangeValueForKey:@"session"];
    
    [self broadcastSessionDidBegin:_session];
    
    MPLogVerbose(@"New Session Has Begun: %@", _session.uuid);
}

- (void)endSession {
    if (_session == nil || [MPStateMachine sharedInstance].optOut) {
        return;
    }

    _session.endTime = [[NSDate date] timeIntervalSince1970];
    
    MPSession *endSession = [_session copy];
    NSMutableDictionary *messageInfo = [@{kMPSessionLengthKey:MPMilliseconds(endSession.foregroundTime),
                                          kMPSessionTotalLengthKey:MPMilliseconds(endSession.length),
                                          kMPEventCounterKey:@(endSession.eventCounter)}
                                        mutableCopy];
    
    NSDictionary *sessionAttributesDictionary = [self attributesDictionaryForSession:endSession];
    if (sessionAttributesDictionary) {
        messageInfo[kMPAttributesKey] = sessionAttributesDictionary;
    }
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    MPMessage *message = [persistence fetchSessionEndMessageInSession:endSession];
    
    if (!message) {
        MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeSessionEnd session:endSession messageInfo:messageInfo];
        if ([MPLocationManager trackingLocation]) {
            messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
        }
        message = (MPMessage *)[[messageBuilder withTimestamp:endSession.endTime] build];
        
        [self saveMessage:message updateSession:NO];
    }
    
    [persistence archiveSession:endSession completionHandler:nil];
    
    [self uploadMessagesFromSession:endSession completionHandler:^(MPSession *uploadedSession) {
        [self uploadSessionHistory:uploadedSession completionHandler:nil];
    }];
    
    [self broadcastSessionDidEnd:endSession];
    _session = nil;
    
    MPLogVerbose(@"Session Ended: %@", endSession.uuid);
}

- (void)beginTimedEvent:(MPEvent *)event attempt:(NSUInteger)attempt completionHandler:(void (^)(MPEvent *event, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Timed events cannot begin prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(event, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            [event beginTiming];
            [self.eventSet addEvent:event];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf beginTimedEvent:event attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(event, execStatus);
}

- (BOOL)checkAttribute:(NSDictionary *)attributesDictionary key:(NSString *)key value:(id)value error:(out NSError *__autoreleasing *)error {
    static NSString *attributeValidationErrorDomain = @"Attribute Validation";
    
    if (!key) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kInvalidKey userInfo:nil];
        }
        
        return NO;
    }
    
    if (!value) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kInvalidValue userInfo:nil];
        }
        
        return NO;
    }
    
    if ([value isKindOfClass:[NSString class]]) {
        if ([value isEqualToString:@""]) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kEmptyValueAttribute userInfo:nil];
            }
            
            return NO;
        }
        
        if (((NSString *)value).length > LIMIT_ATTR_VALUE) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kExceededAttributeMaximumLength userInfo:nil];
            }
            
            return NO;
        }
    }
    
    if (attributesDictionary.count >= LIMIT_ATTR_COUNT) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kExceededNumberOfAttributesLimit userInfo:nil];
        }
        
        return NO;
    }
    
    if (key.length > LIMIT_NAME) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:attributeValidationErrorDomain code:kExceededKeyMaximumLength userInfo:nil];
        }
        
        return NO;
    }
    
    return YES;
}

- (MPEvent *)eventWithName:(NSString *)eventName {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Cannot fetch event name prior to starting the mParticle SDK.\n****\n");
    
    if (_initializationStatus != MPInitializationStatusStarted) {
        return nil;
    }
    
    MPEvent *event = [self.eventSet eventWithName:eventName];
    return event;
}

- (MPExecStatus)fetchSegments:(NSTimeInterval)timeout endpointId:(NSString *)endpointId completionHandler:(void (^)(NSArray *segments, NSTimeInterval elapsedTime, NSError *error))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Segments cannot be fetched prior to starting the mParticle SDK.\n****\n");
    
    if (self.networkCommunication.retrievingSegments) {
        return MPExecStatusDataBeingFetched;
    }

    NSAssert(completionHandler != nil, @"completionHandler cannot be nil.");

    NSArray *(^validSegments)(NSArray *segments) = ^(NSArray *segments) {
        NSMutableArray *validSegments = [[NSMutableArray alloc] initWithCapacity:segments.count];
        
        for (MPSegment *segment in segments) {
            if (!segment.expired && (endpointId == nil || [segment.endpointIds containsObject:endpointId])) {
                [validSegments addObject:segment];
            }
        }
        
        if (validSegments.count == 0) {
            validSegments = nil;
        }
        
        return [validSegments copy];
    };
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    
    [self.networkCommunication requestSegmentsWithTimeout:timeout
                                        completionHandler:^(BOOL success, NSArray *segments, NSTimeInterval elapsedTime, NSError *error) {
                                            if (!error) {
                                                if (success && segments.count > 0) {
                                                    [persistence deleteSegments];
                                                }
                                                
                                                for (MPSegment *segment in segments) {
                                                    [persistence saveSegment:segment];
                                                }
                                                
                                                completionHandler(validSegments(segments), elapsedTime, error);
                                            } else {
                                                MPNetworkError networkError = (MPNetworkError)error.code;
                                                
                                                switch (networkError) {
                                                    case MPNetworkErrorTimeout: {
                                                        NSArray *persistedSegments = [persistence fetchSegments];
                                                        completionHandler(validSegments(persistedSegments), timeout, nil);
                                                    }
                                                        break;
                                                        
                                                    case MPNetworkErrorDelayedSegemnts:
                                                        if (success && segments.count > 0) {
                                                            [persistence deleteSegments];
                                                        }
                                                        
                                                        for (MPSegment *segment in segments) {
                                                            [persistence saveSegment:segment];
                                                        }
                                                        break;
                                                }
                                            }
                                        }];
    
    return MPExecStatusSuccess;
}

- (NSString *)execStatusDescription:(MPExecStatus)execStatus {
    if (execStatus >= execStatusDescriptions.count) {
        return nil;
    }
    
    NSString *description = execStatusDescriptions[execStatus];
    return description;
}

- (NSNumber *)incrementSessionAttribute:(MPSession *)session key:(NSString *)key byValue:(NSNumber *)value {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Incrementing session attribute cannot happen prior to starting the mParticle SDK.\n****\n");

    if (!session) {
        return nil;
    }
    
    NSString *localKey = [session.attributesDictionary caseInsensitiveKey:key];
    if (!localKey) {
        [self setSessionAttribute:session key:localKey value:value];
        return value;
    }
    
    id currentValue = session.attributesDictionary[localKey];
    if (![currentValue isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    
    NSDecimalNumber *incrementValue = [[NSDecimalNumber alloc] initWithString:[value stringValue]];
    NSDecimalNumber *newValue = [[NSDecimalNumber alloc] initWithString:[(NSNumber *)currentValue stringValue]];
    newValue = [newValue decimalNumberByAdding:incrementValue];
    
    session.attributesDictionary[localKey] = newValue;
    
    [[MPPersistenceController sharedInstance] updateSession:session];

    return (NSNumber *)newValue;
}

- (NSNumber *)incrementUserAttribute:(NSString *)key byValue:(NSNumber *)value {
    NSAssert([key isKindOfClass:[NSString class]], @"'key' must be a string.");
    NSAssert([value isKindOfClass:[NSNumber class]], @"'value' must be a number.");
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Incrementing user attribute cannot happen prior to starting the mParticle SDK.\n****\n");

    NSString *localKey = [self.userAttributes caseInsensitiveKey:key];
    if (!localKey) {
        [self setUserAttribute:key value:value attempt:0 completionHandler:nil];
        return value;
    }
    
    id currentValue = self.userAttributes[localKey];
    if (![currentValue isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    
    NSDecimalNumber *incrementValue = [[NSDecimalNumber alloc] initWithString:[value stringValue]];
    NSDecimalNumber *newValue = [[NSDecimalNumber alloc] initWithString:[(NSNumber *)currentValue stringValue]];
    newValue = [newValue decimalNumberByAdding:incrementValue];
    
    self.userAttributes[localKey] = newValue;
    
    NSMutableDictionary *userAttributes = [[NSMutableDictionary alloc] initWithCapacity:self.userAttributes.count];
    NSEnumerator *attributeEnumerator = [self.userAttributes keyEnumerator];
    NSString *aKey;
    
    while ((aKey = [attributeEnumerator nextObject])) {
        if ((NSNull *)self.userAttributes[aKey] == [NSNull null]) {
            userAttributes[aKey] = kMPNullUserAttributeString;
        } else {
            userAttributes[aKey] = self.userAttributes[aKey];
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        userDefaults[kMPUserAttributeKey] = userAttributes;
        [userDefaults synchronize];
    });

    return (NSNumber *)newValue;
}

- (void)leaveBreadcrumb:(MPEvent *)event attempt:(NSUInteger)attempt completionHandler:(void (^)(MPEvent *event, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Breadcrumbs cannot be left prior to starting the mParticle SDK.\n****\n");

    event.messageType = MPMessageTypeBreadcrumb;
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(event, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            NSDictionary *messageInfo = [event breadcrumbDictionaryRepresentation];
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:event.messageType session:self.session messageInfo:messageInfo];
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.eventSet removeEvent:event];
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf leaveBreadcrumb:event attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(event, execStatus);
}

- (void)logCommerceEvent:(MPCommerceEvent *)commerceEvent attempt:(NSUInteger)attempt completionHandler:(void (^)(MPCommerceEvent *commerceEvent, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Commerce Events cannot be logged prior to starting the mParticle SDK.\n****\n");
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(commerceEvent, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeCommerceEvent session:self.session commerceEvent:commerceEvent];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            [self.session incrementCounter];
            
            // Update cart
            NSArray *products = nil;
            if (commerceEvent.action == MPCommerceEventActionAddToCart) {
                products = [commerceEvent addedProducts];
                
                if (products) {
                    [[MPCart sharedInstance] addProducts:products logEvent:NO updateProductList:YES];
                    [commerceEvent resetLatestProducts];
                } else {
                    MPLogWarning(@"Commerce event products were not added to the cart.");
                }
            } else if (commerceEvent.action == MPCommerceEventActionRemoveFromCart) {
                products = [commerceEvent removedProducts];
                
                if (products) {
                    [[MPCart sharedInstance] removeProducts:products logEvent:NO updateProductList:YES];
                    [commerceEvent resetLatestProducts];
                } else {
                    MPLogWarning(@"Commerce event products were not removed from the cart.");
                }
            }
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logCommerceEvent:commerceEvent attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(commerceEvent, execStatus);
}

- (void)logError:(NSString *)message exception:(NSException *)exception topmostContext:(id)topmostContext eventInfo:(NSDictionary *)eventInfo attempt:(NSUInteger)attempt completionHandler:(void (^)(NSString *message, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Errors or exceptions cannot be logged prior to starting the mParticle SDK.\n****\n");

    NSString *execMessage = exception ? exception.name : message;
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(execMessage, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            NSMutableDictionary *messageInfo = [@{kMPCrashWasHandled:@"true",
                                                  kMPCrashingSeverity:@"error"}
                                                mutableCopy];
            
            if (exception) {
                NSData *liveExceptionReportData = [MPExceptionHandler generateLiveExceptionReport];
                if (liveExceptionReportData) {
                    messageInfo[kMPPLCrashReport] = [liveExceptionReportData base64EncodedStringWithOptions:0];
                }
                
                messageInfo[kMPErrorMessage] = exception.reason;
                messageInfo[kMPCrashingClass] = exception.name;
                
                NSArray *callStack = [exception callStackSymbols];
                if (callStack) {
                    messageInfo[kMPStackTrace] = [callStack componentsJoinedByString:@"\n"];
                }
                
                NSArray *fetchedbreadcrumbs = [[MPPersistenceController sharedInstance] fetchBreadcrumbs];
                if (fetchedbreadcrumbs) {
                    NSMutableArray *breadcrumbs = [[NSMutableArray alloc] initWithCapacity:fetchedbreadcrumbs.count];
                    for (MPBreadcrumb *breadcrumb in fetchedbreadcrumbs) {
                        [breadcrumbs addObject:[breadcrumb dictionaryRepresentation]];
                    }
                    
                    NSString *messageTypeBreadcrumbKey = [NSString stringWithCString:MessageTypeName::nameForMessageType(Breadcrumb).c_str() encoding:NSUTF8StringEncoding];
                    messageInfo[messageTypeBreadcrumbKey] = breadcrumbs;
                    
                    NSNumber *sessionNumber = self.session.sessionNumber;
                    if (sessionNumber) {
                        messageInfo[kMPSessionNumberKey] = sessionNumber;
                    }
                }
            } else {
                messageInfo[kMPErrorMessage] = message;
            }
            
            if (topmostContext) {
                messageInfo[kMPTopmostContext] = [[topmostContext class] description];
            }
            
            if (eventInfo) {
                [messageInfo addEntriesFromDictionary:eventInfo];
            }
            
            NSDictionary *appImageInfo = [MPExceptionHandler appImageInfo];
            if (appImageInfo) {
                [messageInfo addEntriesFromDictionary:appImageInfo];
            }
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeCrashReport session:self.session messageInfo:messageInfo];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *errorMessage = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:errorMessage updateSession:YES];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logError:message exception:exception topmostContext:topmostContext eventInfo:eventInfo attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(execMessage, execStatus);
}

- (void)logEvent:(MPEvent *)event attempt:(NSUInteger)attempt completionHandler:(void (^)(MPEvent *event, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Events cannot be logged prior to starting the mParticle SDK.\n****\n");
    
    event.messageType = MPMessageTypeEvent;
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(event, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            [event endTiming];
            
            NSDictionary *messageInfo = [event dictionaryRepresentation];
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:event.messageType session:self.session messageInfo:messageInfo];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.eventSet removeEvent:event];
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logEvent:event attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(event, execStatus);
}

- (void)logNetworkPerformanceMeasurement:(MPNetworkPerformance *)networkPerformance attempt:(NSUInteger)attempt completionHandler:(void (^)(MPNetworkPerformance *networkPerformance, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Network performance measurement cannot be logged prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        if (completionHandler) {
            completionHandler(networkPerformance, MPExecStatusFail);
        }
        
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            NSDictionary *messageInfo = [networkPerformance dictionaryRepresentation];
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeNetworkPerformance session:self.session messageInfo:messageInfo];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];

            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logNetworkPerformanceMeasurement:networkPerformance attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    if (completionHandler) {
        completionHandler(networkPerformance, execStatus);
    }
}

- (void)logScreen:(MPEvent *)event attempt:(NSUInteger)attempt completionHandler:(void (^)(MPEvent *event, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Screens cannot be logged prior to starting the mParticle SDK.\n****\n");

    event.messageType = MPMessageTypeScreenView;
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(event, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;

    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            [event endTiming];
            
            if (event.type != MPEventTypeNavigation) {
                event.type = MPEventTypeNavigation;
            }
            
            NSDictionary *messageInfo = [event screenDictionaryRepresentation];
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:event.messageType session:self.session messageInfo:messageInfo];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.eventSet removeEvent:event];
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logScreen:event attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(event, execStatus);
}

- (void)profileChange:(MPProfileChange)profile attempt:(NSUInteger)attempt completionHandler:(void (^)(MPProfileChange profile, MPExecStatus execStatus))completionHandler {
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(profile, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            NSDictionary *profileChangeDictionary = nil;
            
            switch (profile) {
                case MPProfileChangeLogout:
                    profileChangeDictionary = @{kMPProfileChangeTypeKey:@"logout"};
                    break;
                    
                default:
                    return;
                    break;
            }
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeProfile session:self.session messageInfo:profileChangeDictionary];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf profileChange:profile attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(profile, execStatus);
}

- (void)setOptOut:(BOOL)optOutStatus attempt:(NSUInteger)attempt completionHandler:(void (^)(BOOL optOut, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Setting opt out cannot happen prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(optOutStatus, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            [MPStateMachine sharedInstance].optOut = optOutStatus;
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeOptOut session:self.session messageInfo:@{kMPOptOutStatus:(optOutStatus ? @"true" : @"false")}];
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            if (optOutStatus) {
                [self endSession];
            }
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf setOptOut:optOutStatus attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(optOutStatus, execStatus);
}

- (MPExecStatus)setSessionAttribute:(MPSession *)session key:(NSString *)key value:(id)value {
    NSAssert(session != nil, @"session cannot be nil.");
    NSAssert([key isKindOfClass:[NSString class]], @"'key' must be a string.");
    NSAssert([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]], @"'value' must be a string or number.");
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Setting session attribute cannot be done prior to starting the mParticle SDK.\n****\n");

    if (!session) {
        return MPExecStatusMissingParam;
    } else if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) {
        return MPExecStatusInvalidDataType;
    }
    
    NSString *localKey = [session.attributesDictionary caseInsensitiveKey:key];
    NSError *error = nil;
    BOOL validAttributes = [self checkAttribute:session.attributesDictionary key:localKey value:value error:&error];
    if (!validAttributes || [session.attributesDictionary[localKey] isEqual:value]) {
        return MPExecStatusInvalidDataType;
    }
    
    session.attributesDictionary[localKey] = value;
    
    [[MPPersistenceController sharedInstance] updateSession:session];
    
    return MPExecStatusSuccess;
}

- (void)startWithKey:(NSString *)apiKey secret:(NSString *)secret firstRun:(BOOL)firstRun installationType:(MPInstallationType)installationType proxyAppDelegate:(BOOL)proxyAppDelegate completionHandler:(dispatch_block_t)completionHandler {
    appFinishedLaunching = YES;
    _initializationStatus = MPInitializationStatusStarting;

    if (proxyAppDelegate) {
        [self proxyOriginalAppDelegate];
    }
    
    [self.notificationController registerForSilentNotifications];

    [MPKitContainer sharedInstance];
    
    MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
    stateMachine.apiKey = apiKey;
    stateMachine.secret = secret;
    stateMachine.installationType = installationType;
    [MPStateMachine setRunningInBackground:NO];

    __weak MPBackendController *weakSelf = self;
    
    dispatch_async(backendQueue, ^{
        __strong MPBackendController *strongSelf = weakSelf;
        
        if (firstRun) {
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeFirstRun session:strongSelf.session messageInfo:nil];
            MPMessage *message = (MPMessage *)[messageBuilder build];
            message.uploadStatus = MPUploadStatusBatch;
            
            [strongSelf saveMessage:message updateSession:YES];
            
            MPLogDebug(@"Application First Run");
        }
        
        [strongSelf processPendingArchivedMessages];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_initializationStatus = MPInitializationStatusStarted;
            MPLogDebug(@"SDK %@ has started", kMParticleSDKVersion);
            
            [strongSelf processOpenSessionsIncludingCurrent:NO completionHandler:^(BOOL success) {
                if (firstRun) {
                    [strongSelf upload];
                }
                
                [strongSelf beginUploadTimer];
            }];
            
            completionHandler();
        });
    });
}

- (void)resetTimer {
    if ([MPStateMachine environment] == MPEnvironmentDevelopment) {
        _uploadInterval = DEFAULT_DEBUG_UPLOAD_INTERVAL;
    } else {
        _uploadInterval = 0.0;
    }
    
    [self beginUploadTimer];
}

- (MPExecStatus)upload {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Upload cannot be done prior to starting the mParticle SDK.\n****\n");

    if ([MPStateMachine sharedInstance].networkStatus == NotReachable) {
        return MPExecStatusNoConnectivity;
    }
    
    if (self.networkCommunication.inUse) {
        return MPExecStatusDataBeingUploaded;
    }
    
    if (_initializationStatus != MPInitializationStatusStarted) {
        return MPExecStatusDelayedExecution;
    }
    
    if ([[MPStateMachine sharedInstance].minUploadDate compare:[NSDate date]] == NSOrderedDescending) {
        return MPExecStatusServerBusy;
    }

    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    BOOL shouldTryToUploadSessionMessages = (_session != nil) ? [persistence countMesssagesForUploadInSession:_session] > 0 : NO;
    BOOL shouldTryToUploadStandaloneMessages = [persistence countStandaloneMessages] > 0;
    
    if (shouldTryToUploadSessionMessages) {
        __weak MPBackendController *weakSelf = self;
        
        [self uploadMessagesFromSession:self.session
                      completionHandler:^(MPSession *uploadedSession) {
                          if (shouldTryToUploadStandaloneMessages) {
                              __strong MPBackendController *strongSelf = weakSelf;
                              
                              [strongSelf uploadStandaloneMessages];
                          }
                      }];
    } else if (shouldTryToUploadStandaloneMessages) {
        [self uploadStandaloneMessages];
    }
    
    return MPExecStatusSuccess;
}

- (void)setUserAttribute:(NSString *)key value:(id)value attempt:(NSUInteger)attempt completionHandler:(void (^)(NSString *key, id value, MPExecStatus execStatus))completionHandler {
    NSAssert([key isKindOfClass:[NSString class]], @"'key' must be a string.");
    NSAssert(value == nil || (value != nil && ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]])), @"'value' must be either nil, or string or number.");
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Setting user attribute cannot be done prior to starting the mParticle SDK.\n****\n");

    if (!key) {
        if (completionHandler) {
            completionHandler(key, value, MPExecStatusMissingParam);
        }
        
        return;
    }
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        if (completionHandler) {
            completionHandler(key, value, MPExecStatusFail);
        }

        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            if ([MPStateMachine sharedInstance].optOut) {
                if (completionHandler) {
                    completionHandler(key, value, MPExecStatusOptOut);
                }
                
                return;
            }
            
            if (value && ![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) {
                if (completionHandler) {
                    completionHandler(key, value, MPExecStatusInvalidDataType);
                }
                
                return;
            }
            
            NSString *localKey = [self.userAttributes caseInsensitiveKey:key];
            NSError *error = nil;
            BOOL validAttributes = [self checkAttribute:self.userAttributes key:localKey value:value error:&error];
            
            id<NSObject> userAttributeValue;
            if (!validAttributes && error.code == kInvalidValue) {
                userAttributeValue = [NSNull null];
                validAttributes = YES;
                error = nil;
            } else {
                userAttributeValue = value;
            }
            
            if (validAttributes) {
                self.userAttributes[localKey] = userAttributeValue;
            } else if ((error.code == kEmptyValueAttribute) && self.userAttributes[localKey]) {
                [self.userAttributes removeObjectForKey:localKey];
                
                if (!deletedUserAttributes) {
                    deletedUserAttributes = [[NSMutableSet alloc] initWithCapacity:1];
                }
                [deletedUserAttributes addObject:key];
            } else {
                if (completionHandler) {
                    completionHandler(key, value, MPExecStatusInvalidDataType);
                }
                
                return;
            }
            
            NSMutableDictionary *userAttributes = [[NSMutableDictionary alloc] initWithCapacity:self.userAttributes.count];
            NSEnumerator *attributeEnumerator = [self.userAttributes keyEnumerator];
            NSString *aKey;
            
            while ((aKey = [attributeEnumerator nextObject])) {
                if ((NSNull *)self.userAttributes[aKey] == [NSNull null]) {
                    userAttributes[aKey] = kMPNullUserAttributeString;
                } else {
                    userAttributes[aKey] = self.userAttributes[aKey];
                }
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
                userDefaults[kMPUserAttributeKey] = userAttributes;
                [userDefaults synchronize];
            });
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf setUserAttribute:key value:value attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    if (completionHandler) {
        completionHandler(key, value, execStatus);
    }
}

- (void)setUserIdentity:(NSString *)identityString identityType:(MPUserIdentity)identityType attempt:(NSUInteger)attempt completionHandler:(void (^)(NSString *identityString, MPUserIdentity identityType, MPExecStatus execStatus))completionHandler {
    NSAssert(completionHandler != nil, @"completionHandler cannot be nil.");
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Setting user identity cannot be done prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(identityString, identityType, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            NSNumber *identityTypeNumnber = @(identityType);
            
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF[%@] == %@", kMPUserIdentityTypeKey, identityTypeNumnber];
            NSDictionary *userIdentity = [[self.userIdentities filteredArrayUsingPredicate:predicate] lastObject];
            
            if (userIdentity &&
                [[userIdentity[kMPUserIdentityIdKey] lowercaseString] isEqualToString:[identityString lowercaseString]] &&
                ![userIdentity[kMPUserIdentityIdKey] isEqualToString:identityString])
            {
                return;
            }
            
            BOOL (^objectTester)(id, NSUInteger, BOOL *) = ^(id obj, NSUInteger idx, BOOL *stop) {
                NSNumber *currentIdentityType = obj[kMPUserIdentityTypeKey];
                BOOL foundMatch = [currentIdentityType isEqualToNumber:identityTypeNumnber];
                
                if (foundMatch) {
                    *stop = YES;
                }
                
                return foundMatch;
            };
            
            NSUInteger existingEntryIndex;
            BOOL persistUserIdentities = NO;
            if (identityString == nil || [identityString isEqualToString:@""]) {
                existingEntryIndex = [self.userIdentities indexOfObjectPassingTest:objectTester];
                
                if (existingEntryIndex != NSNotFound) {
                    [self.userIdentities removeObjectAtIndex:existingEntryIndex];
                    persistUserIdentities = YES;
                }
            } else {
                NSMutableDictionary *identityDictionary = [NSMutableDictionary dictionary];
                identityDictionary[kMPUserIdentityTypeKey] = identityTypeNumnber;
                identityDictionary[kMPUserIdentityIdKey] = identityString;
                
                NSError *error = nil;
                if ([self checkAttribute:identityDictionary key:kMPUserIdentityIdKey value:identityString error:&error] &&
                    [self checkAttribute:identityDictionary key:kMPUserIdentityTypeKey value:[identityTypeNumnber stringValue] error:&error]) {
                    
                    existingEntryIndex = [self.userIdentities indexOfObjectPassingTest:objectTester];
                    
                    if (existingEntryIndex == NSNotFound) {
                        identityDictionary[kMPDateUserIdentityWasFirstSet] = MPCurrentEpochInMilliseconds;
                        identityDictionary[kMPIsFirstTimeUserIdentityHasBeenSet] = @YES;
                        
                        [self.userIdentities addObject:identityDictionary];
                    } else {
                        NSDictionary *userIdentity = self.userIdentities[existingEntryIndex];
                        identityDictionary[kMPDateUserIdentityWasFirstSet] = userIdentity[kMPDateUserIdentityWasFirstSet] ? userIdentity[kMPDateUserIdentityWasFirstSet] : MPCurrentEpochInMilliseconds;
                        identityDictionary[kMPIsFirstTimeUserIdentityHasBeenSet] = @NO;
                        
                        [self.userIdentities replaceObjectAtIndex:existingEntryIndex withObject:identityDictionary];
                    }
                    
                    persistUserIdentities = YES;
                }
            }
            
            if (persistUserIdentities) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
                    userDefaults[kMPUserIdentityArrayKey] = self.userIdentities;
                    [userDefaults synchronize];
                });
            }
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf setUserIdentity:identityString identityType:identityType attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(identityString, identityType, execStatus);
}

#pragma mark Public media traking methods
- (void)beginPlaying:(MPMediaTrack *)mediaTrack attempt:(NSUInteger)attempt completionHandler:(void (^)(MPMediaTrack *mediaTrack, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Media track cannot play prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(mediaTrack, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            if (mediaTrack.playbackRate == 0.0) {
                mediaTrack.playbackRate = 1.0;
            }
            
            if (![self.mediaTrackContainer containsTrack:mediaTrack]) {
                [self.mediaTrackContainer addTrack:mediaTrack];
            }
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeEvent
                                                                                   session:self.session
                                                                                mediaTrack:mediaTrack
                                                                               mediaAction:MPMediaActionPlay];
            
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf beginPlaying:mediaTrack attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(mediaTrack, execStatus);
}

- (MPExecStatus)discardMediaTrack:(MPMediaTrack *)mediaTrack {
    [self.mediaTrackContainer removeTrack:mediaTrack];
    
    return MPExecStatusSuccess;
}

- (void)endPlaying:(MPMediaTrack *)mediaTrack attempt:(NSUInteger)attempt completionHandler:(void (^)(MPMediaTrack *mediaTrack, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Media track cannot end prior to starting the mParticle SDK.\n****\n");
    
    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(mediaTrack, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            if (mediaTrack.playbackRate != 0.0) {
                mediaTrack.playbackRate = 0.0;
            }
            
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeEvent
                                                                                   session:self.session
                                                                                mediaTrack:mediaTrack
                                                                               mediaAction:MPMediaActionStop];
            
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf endPlaying:mediaTrack attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(mediaTrack, execStatus);
}

- (void)logMetadataWithMediaTrack:(MPMediaTrack *)mediaTrack attempt:(NSUInteger)attempt completionHandler:(void (^)(MPMediaTrack *mediaTrack, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Media track cannot log metadata prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(mediaTrack, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeEvent
                                                                                   session:self.session
                                                                                mediaTrack:mediaTrack
                                                                               mediaAction:MPMediaActionMetadata];
            
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logMetadataWithMediaTrack:mediaTrack attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(mediaTrack, execStatus);
}

- (void)logTimedMetadataWithMediaTrack:(MPMediaTrack *)mediaTrack attempt:(NSUInteger)attempt completionHandler:(void (^)(MPMediaTrack *mediaTrack, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Media track cannot log timed metadata prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(mediaTrack, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeEvent
                                                                                   session:self.session
                                                                                mediaTrack:mediaTrack
                                                                               mediaAction:MPMediaActionMetadata];
            
            if ([MPLocationManager trackingLocation]) {
                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
            }
            MPMessage *message = (MPMessage *)[messageBuilder build];
            
            [self saveMessage:message updateSession:YES];
            
            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf logTimedMetadataWithMediaTrack:mediaTrack attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(mediaTrack, execStatus);
}

- (NSArray *)mediaTracks {
    NSArray *mediaTracks = [self.mediaTrackContainer allMediaTracks];
    return mediaTracks;
}

- (MPMediaTrack *)mediaTrackWithChannel:(NSString *)channel {
    MPMediaTrack *mediaTrack = [self.mediaTrackContainer trackWithChannel:channel];
    return mediaTrack;
}

- (void)updatePlaybackPosition:(MPMediaTrack *)mediaTrack attempt:(NSUInteger)attempt completionHandler:(void (^)(MPMediaTrack *mediaTrack, MPExecStatus execStatus))completionHandler {
    NSAssert(_initializationStatus != MPInitializationStatusNotStarted, @"\n****\n  Media track cannot update playback position prior to starting the mParticle SDK.\n****\n");

    if (attempt > METHOD_EXEC_MAX_ATTEMPT) {
        completionHandler(mediaTrack, MPExecStatusFail);
        return;
    }
    
    MPExecStatus execStatus = MPExecStatusFail;
    
    switch (_initializationStatus) {
        case MPInitializationStatusStarted: {
            // At the moment we will only forward playback position to kits but not log a message
//            MPMessageBuilder *messageBuilder = [MPMessageBuilder newBuilderWithMessageType:MPMessageTypeEvent
//                                                                                   session:self.session
//                                                                                mediaTrack:mediaTrack
//                                                                               mediaAction:MPMediaActionPlaybackPosition];
//            
//            if ([MPLocationManager trackingLocation]) {
//                messageBuilder = [messageBuilder withLocation:[MPStateMachine sharedInstance].locationManager.location];
//            }
//            MPMessage *message = (MPMessage *)[messageBuilder build];
//            
//            [self saveMessage:message updateSession:YES];
//            
//            [self.session incrementCounter];
            
            execStatus = MPExecStatusSuccess;
        }
            break;
            
        case MPInitializationStatusStarting: {
            __weak MPBackendController *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong MPBackendController *strongSelf = weakSelf;
                [strongSelf updatePlaybackPosition:mediaTrack attempt:(attempt + 1) completionHandler:completionHandler];
            });
            
            execStatus = attempt == 0 ? MPExecStatusDelayedExecution : MPExecStatusContinuedDelayedExecution;
        }
            break;
            
        case MPInitializationStatusNotStarted:
            execStatus = MPExecStatusSDKNotStarted;
            break;
    }
    
    completionHandler(mediaTrack, execStatus);
}

@end
