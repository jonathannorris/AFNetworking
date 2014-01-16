// AFURLSessionManager.m
// 
// Copyright (c) 2013 AFNetworking (http://afnetworking.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "TL_AFURLSessionManager.h"

#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 70000) || (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 1090)

static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}

static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}

NSString * const TL_AFNetworkingTaskDidStartNotification = @"com.alamofire.networking.task.start";
NSString * const TL_AFNetworkingTaskDidFinishNotification = @"com.alamofire.networking.task.finish";
NSString * const TL_AFNetworkingTaskDidFinishResponseDataKey = @"com.alamofire.networking.task.finish.responsedata";
NSString * const TL_AFNetworkingTaskDidSuspendNotification = @"com.alamofire.networking.task.suspend";
NSString * const TL_AFURLSessionDidInvalidateNotification = @"com.alamofire.networking.session.invalidate";
NSString * const TL_AFURLSessionDownloadTaskDidFailToMoveFileNotification = @"com.alamofire.networking.session.download.file-manager-error";

NSString * const TL_AFNetworkingTaskDidFinishSerializedResponseKey = @"com.alamofire.networking.task.finish.serializedresponse";
NSString * const TL_AFNetworkingTaskDidFinishResponseSerializerKey = @"com.alamofire.networking.task.finish.responseserializer";
NSString * const TL_AFNetworkingTaskDidFinishErrorKey = @"com.alamofire.networking.task.finish.error";
NSString * const TL_AFNetworkingTaskDidFinishAssetPathKey = @"com.alamofire.networking.task.finish.assetpath";

static NSString * const TL_AFURLSessionManagerLockName = @"com.alamofire.networking.session.manager.lock";

static void * TL_AFTaskStateChangedContext = &TL_AFTaskStateChangedContext;

typedef void (^TL_AFURLSessionDidBecomeInvalidBlock)(NSURLSession *session, NSError *error);
typedef NSURLSessionAuthChallengeDisposition (^TL_AFURLSessionDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSURLRequest * (^TL_AFURLSessionTaskWillPerformHTTPRedirectionBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request);
typedef NSURLSessionAuthChallengeDisposition (^TL_AFURLSessionTaskDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSInputStream * (^TL_AFURLSessionTaskNeedNewBodyStreamBlock)(NSURLSession *session, NSURLSessionTask *task);
typedef void (^TL_AFURLSessionTaskDidSendBodyDataBlock)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);
typedef void (^TL_AFURLSessionTaskDidCompleteBlock)(NSURLSession *session, NSURLSessionTask *task, NSError *error);

typedef NSURLSessionResponseDisposition (^TL_AFURLSessionDataTaskDidReceiveResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response);
typedef void (^TL_AFURLSessionDataTaskDidBecomeDownloadTaskBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
typedef void (^TL_AFURLSessionDataTaskDidReceiveDataBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
typedef NSCachedURLResponse * (^TL_AFURLSessionDataTaskWillCacheResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse);
typedef void (^TL_AFURLSessionDidFinishEventsForBackgroundURLSessionBlock)(NSURLSession *session);

typedef NSURL * (^TL_AFURLSessionDownloadTaskDidFinishDownloadingBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location);
typedef void (^TL_AFURLSessionDownloadTaskDidWriteDataBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
typedef void (^TL_AFURLSessionDownloadTaskDidResumeBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes);

typedef void (^AFURLSessionTaskCompletionHandler)(NSURLResponse *response, id responseObject, NSError *error);

#pragma mark -

@interface TL_AFURLSessionManagerTaskDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, weak) TL_AFURLSessionManager *manager;
@property (nonatomic, strong) NSMutableData *mutableData;
@property (nonatomic, strong) NSProgress *uploadProgress;
@property (nonatomic, strong) NSProgress *downloadProgress;
@property (nonatomic, copy) NSURL *downloadFileURL;
@property (nonatomic, copy) TL_AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (nonatomic, copy) AFURLSessionTaskCompletionHandler completionHandler;

+ (instancetype)delegateForManager:(TL_AFURLSessionManager *)manager
                 completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler;

@end

@implementation TL_AFURLSessionManagerTaskDelegate

+ (instancetype)delegateForManager:(TL_AFURLSessionManager *)manager
                 completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [[self alloc] init];
    delegate.manager = manager;
    delegate.completionHandler = completionHandler;

    return delegate;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.mutableData = [NSMutableData data];

    self.uploadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    self.downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];

    return self;
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(__unused NSURLSession *)session
              task:(__unused NSURLSessionTask *)task
   didSendBodyData:(__unused int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    self.uploadProgress.totalUnitCount = totalBytesExpectedToSend;
    self.uploadProgress.completedUnitCount = totalBytesSent;
}

- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
    if (self.completionHandler) {
        __strong TL_AFURLSessionManager *manager = self.manager;

        __block id responseObject = nil;

        __block NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[TL_AFNetworkingTaskDidFinishResponseSerializerKey] = manager.responseSerializer;

        if (self.downloadFileURL) {
            userInfo[TL_AFNetworkingTaskDidFinishAssetPathKey] = self.downloadFileURL;
        } else if (self.mutableData) {
            userInfo[TL_AFNetworkingTaskDidFinishResponseDataKey] = [NSData dataWithData:self.mutableData];
        }

        if (error) {
            userInfo[TL_AFNetworkingTaskDidFinishErrorKey] = error;

            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                if (self.completionHandler) {
                    self.completionHandler(task.response, responseObject, error);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:TL_AFNetworkingTaskDidFinishNotification object:task userInfo:userInfo];
                });
            });
        } else {
            dispatch_async(url_session_manager_processing_queue(), ^{
                NSError *serializationError = nil;
                if (self.downloadFileURL) {
                    responseObject = self.downloadFileURL;
                } else {
                    responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:[NSData dataWithData:self.mutableData] error:&serializationError];
                }

                if (responseObject) {
                    userInfo[TL_AFNetworkingTaskDidFinishSerializedResponseKey] = responseObject;
                }

                if (serializationError) {
                    userInfo[TL_AFNetworkingTaskDidFinishErrorKey] = serializationError;
                }

                dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                    if (self.completionHandler) {
                        self.completionHandler(task.response, responseObject, serializationError);
                    }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:TL_AFNetworkingTaskDidFinishNotification object:task userInfo:userInfo];
                    });
                });
            });
        }
    }
#pragma clang diagnostic pop
}

#pragma mark - NSURLSessionDataTaskDelegate

- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    [self.mutableData appendData:data];

    self.downloadProgress.totalUnitCount += [data length];
}

#pragma mark - NSURLSessionDownloadTaskDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSError *fileManagerError = nil;
    self.downloadFileURL = nil;

    if (self.downloadTaskDidFinishDownloading) {
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (self.downloadFileURL) {
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError];

            if (fileManagerError) {
                [[NSNotificationCenter defaultCenter] postNotificationName:TL_AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            }
        }
    }
}

- (void)URLSession:(__unused NSURLSession *)session
      downloadTask:(__unused NSURLSessionDownloadTask *)downloadTask
      didWriteData:(__unused int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    self.downloadProgress.totalUnitCount = totalBytesExpectedToWrite;
    self.downloadProgress.completedUnitCount = totalBytesWritten;
}

- (void)URLSession:(__unused NSURLSession *)session
      downloadTask:(__unused NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    self.downloadProgress.totalUnitCount = expectedTotalBytes;
    self.downloadProgress.completedUnitCount = fileOffset;
}

@end

#pragma mark -

@interface TL_AFURLSessionManager ()
@property (readwrite, nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (readwrite, nonatomic, strong) NSOperationQueue *operationQueue;
@property (readwrite, nonatomic, strong) NSURLSession *session;
@property (readwrite, nonatomic, strong) NSMutableDictionary *mutableTaskDelegatesKeyedByTaskIdentifier;
@property (readwrite, nonatomic, strong) TL_AFNetworkReachabilityManager *reachabilityManager;
@property (readwrite, nonatomic, strong) NSLock *lock;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) TL_AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
@property (readwrite, nonatomic, copy) TL_AFURLSessionTaskDidReceiveAuthenticationChallengeBlock taskDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) TL_AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
@property (readwrite, nonatomic, copy) TL_AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
@property (readwrite, nonatomic, copy) TL_AFURLSessionTaskDidCompleteBlock taskDidComplete;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
@property (readwrite, nonatomic, copy) TL_AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
@end

@implementation TL_AFURLSessionManager

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }

    self.operationQueue = [[NSOperationQueue alloc] init];
    self.operationQueue.maxConcurrentOperationCount = NSOperationQueueDefaultMaxConcurrentOperationCount;

    self.responseSerializer = [TL_AFJSONResponseSerializer serializer];

    self.sessionConfiguration = configuration;
    self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];

    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];

    self.reachabilityManager = [TL_AFNetworkReachabilityManager sharedManager];
    [self.reachabilityManager startMonitoring];

    self.securityPolicy = [TL_AFSecurityPolicy defaultPolicy];

    self.lock = [[NSLock alloc] init];
    self.lock.name =TL_AFURLSessionManagerLockName;

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, self.session, self.operationQueue];
}

#pragma mark -

- (TL_AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    TL_AFURLSessionManagerTaskDelegate *delegate = nil;
    [self.lock lock];
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    [self.lock unlock];

    return delegate;
}

- (void)setDelegate:(TL_AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    NSParameterAssert(task);

    [self.lock lock];
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
    [self.lock unlock];
}

- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    [self.lock lock];
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    [self.lock unlock];
}

- (void)removeAllDelegates {
    [self.lock lock];
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeAllObjects];
    [self.lock unlock];
}

#pragma mark -

- (NSArray *)tasksForKeyPath:(NSString *)keyPath {
    __block NSArray *tasks = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(dataTasks))]) {
            tasks = dataTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(uploadTasks))]) {
            tasks = uploadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(downloadTasks))]) {
            tasks = downloadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(tasks))]) {
            tasks = [@[dataTasks, uploadTasks, downloadTasks] valueForKeyPath:@"@unionOfArrays.self"];
        }

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    return tasks;
}

- (NSArray *)tasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)dataTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)uploadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)downloadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

#pragma mark -

- (void)invalidateSessionCancelingTasks:(BOOL)cancelPendingTasks {
    if (cancelPendingTasks) {
        [self.session invalidateAndCancel];
    } else {
        [self.session finishTasksAndInvalidate];
    }
}

#pragma mark -

- (void)setResponseSerializer:(id <TL_AFURLResponseSerialization>)responseSerializer {
    NSParameterAssert(responseSerializer);

    _responseSerializer = responseSerializer;
}

#pragma mark -

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:request];

    TL_AFURLSessionManagerTaskDelegate *delegate = [TL_AFURLSessionManagerTaskDelegate delegateForManager:self completionHandler:completionHandler];
    [self setDelegate:delegate forTask:dataTask];

    [dataTask addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew context:TL_AFTaskStateChangedContext];

    return dataTask;
}

#pragma mark -

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                         progress:(NSProgress * __autoreleasing *)progress
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];

    return [self uploadTaskWithTask:uploadTask progress:progress completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                         progress:(NSProgress * __autoreleasing *)progress
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromData:bodyData];

    return [self uploadTaskWithTask:uploadTask progress:progress completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
                                                 progress:(NSProgress * __autoreleasing *)progress
                                        completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithStreamedRequest:request];

    return [self uploadTaskWithTask:uploadTask progress:progress completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)uploadTaskWithTask:(NSURLSessionUploadTask *)uploadTask
                                      progress:(NSProgress * __autoreleasing *)progress
                             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    if (!uploadTask) {
        return nil;
    }
    
    TL_AFURLSessionManagerTaskDelegate *delegate = [TL_AFURLSessionManagerTaskDelegate delegateForManager:self completionHandler:completionHandler];

    delegate.uploadProgress = [NSProgress progressWithTotalUnitCount:uploadTask.countOfBytesExpectedToSend];
    delegate.uploadProgress.pausingHandler = ^{
        [uploadTask suspend];
    };
    delegate.uploadProgress.cancellationHandler = ^{
        [uploadTask cancel];
    };

    if (progress) {
        *progress = delegate.uploadProgress;
    }

    [self setDelegate:delegate forTask:uploadTask];

    [uploadTask addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew context:TL_AFTaskStateChangedContext];
    
    return uploadTask;
}

#pragma mark -

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(NSProgress * __autoreleasing *)progress
                                          destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithRequest:request];

    return [self downloadTaskWithTask:downloadTask progress:progress destination:destination completionHandler:completionHandler];
}

- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                                progress:(NSProgress * __autoreleasing *)progress
                                             destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                       completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithResumeData:resumeData];

    return [self downloadTaskWithTask:downloadTask progress:progress destination:destination completionHandler:completionHandler];
}

- (NSURLSessionDownloadTask *)downloadTaskWithTask:(NSURLSessionDownloadTask *)downloadTask
                                          progress:(NSProgress * __autoreleasing *)progress
                                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    if (!downloadTask) {
        return nil;
    }
    
    TL_AFURLSessionManagerTaskDelegate *delegate = [TL_AFURLSessionManagerTaskDelegate delegateForManager:self completionHandler:completionHandler];
    delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
        if (destination) {
            return destination(location, task.response);
        }

        return location;
    };

    if (progress) {
        *progress = delegate.downloadProgress;
    }

    [self setDelegate:delegate forTask:downloadTask];

    [downloadTask addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew context:TL_AFTaskStateChangedContext];

    return downloadTask;
}

#pragma mark -

- (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}

- (void)setSessionDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.sessionDidReceiveAuthenticationChallenge = block;
}

#pragma mark -

- (void)setTaskWillPerformHTTPRedirectionBlock:(NSURLRequest * (^)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request))block {
    self.taskWillPerformHTTPRedirection = block;
}

- (void)setTaskDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.taskDidReceiveAuthenticationChallenge = block;
}

- (void)setTaskDidSendBodyDataBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend))block {
    self.taskDidSendBodyData = block;
}

- (void)setTaskDidCompleteBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, NSError *error))block {
    self.taskDidComplete = block;
}

#pragma mark -

- (void)setDataTaskDidReceiveResponseBlock:(NSURLSessionResponseDisposition (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response))block {
    self.dataTaskDidReceiveResponse = block;
}

- (void)setDataTaskDidBecomeDownloadTaskBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask))block {
    self.dataTaskDidBecomeDownloadTask = block;
}

- (void)setDataTaskDidReceiveDataBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data))block {
    self.dataTaskDidReceiveData = block;
}

- (void)setDataTaskWillCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse))block {
    self.dataTaskWillCacheResponse = block;
}

- (void)setDidFinishEventsForBackgroundURLSessionBlock:(void (^)(NSURLSession *session))block {
    self.didFinishEventsForBackgroundURLSession = block;
}

#pragma mark -

- (void)setDownloadTaskDidFinishDownloadingBlock:(NSURL * (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location))block {
    self.downloadTaskDidFinishDownloading = block;
}

- (void)setDownloadTaskDidWriteDataBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite))block {
    self.downloadTaskDidWriteData = block;
}

- (void)setDownloadTaskDidResumeBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes))block {
    self.downloadTaskDidResume = block;
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    if (self.sessionDidBecomeInvalid) {
        self.sessionDidBecomeInvalid(session, error);
    }

    [self removeAllDelegates];

    [[NSNotificationCenter defaultCenter] postNotificationName:TL_AFURLSessionDidInvalidateNotification object:session];
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    if (self.sessionDidReceiveAuthenticationChallenge) {
        disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust]) {
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                if (credential) {
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    NSURLRequest *redirectRequest = request;

    if (self.taskWillPerformHTTPRedirection) {
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }

    if (completionHandler) {
        completionHandler(redirectRequest);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    if (self.taskDidReceiveAuthenticationChallenge) {
        disposition = self.taskDidReceiveAuthenticationChallenge(session, task, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust]) {
                disposition = NSURLSessionAuthChallengeUseCredential;
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    NSInputStream *inputStream = nil;
    
    if (self.taskNeedNewBodyStream) {
        inputStream = self.taskNeedNewBodyStream(session, task);
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }

    if (completionHandler) {
        completionHandler(inputStream);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    [delegate URLSession:session task:task didSendBodyData:bytesSent totalBytesSent:totalBytesSent totalBytesExpectedToSend:totalBytesExpectedToSend];

    if (self.taskDidSendBodyData) {
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalBytesExpectedToSend);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    [delegate URLSession:session task:task didCompleteWithError:error];

    if (self.taskDidComplete) {
        self.taskDidComplete(session, task, error);
    }

    [self removeDelegateForTask:task];
    
    @try {
        [task removeObserver:self forKeyPath:@"state" context:TL_AFTaskStateChangedContext];
    } @catch (NSException *exception) {}
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;

    if (self.dataTaskDidReceiveResponse) {
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }

    if (completionHandler) {
        completionHandler(disposition);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    if (self.dataTaskDidBecomeDownloadTask) {
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];

    if (self.dataTaskDidReceiveData) {
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.dataTaskWillCacheResponse) {
       cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }

    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (self.didFinishEventsForBackgroundURLSession) {
        self.didFinishEventsForBackgroundURLSession(session);
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    if (delegate) {
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    } else if (self.downloadTaskDidFinishDownloading) {
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            NSError *error = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error];
            if (error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:TL_AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    TL_AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    [delegate URLSession:session downloadTask:downloadTask didWriteData:bytesWritten totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite];

    if (self.downloadTaskDidWriteData) {
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    if (self.downloadTaskDidResume) {
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}

#pragma mark - NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if (context == TL_AFTaskStateChangedContext && [keyPath isEqualToString:@"state"]) {
        NSString *notificationName = nil;
        switch ([(NSURLSessionTask *)object state]) {
            case NSURLSessionTaskStateRunning:
                notificationName = TL_AFNetworkingTaskDidStartNotification;
                break;
            case NSURLSessionTaskStateSuspended:
                notificationName = TL_AFNetworkingTaskDidSuspendNotification;
                break;
            case NSURLSessionTaskStateCompleted:
                // AFNetworkingTaskDidFinishNotification posted by task completion handlers
            default:
                break;
        }

        if (notificationName) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:object];
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)decoder {
    NSURLSessionConfiguration *configuration = [decoder decodeObjectForKey:@"sessionConfiguration"];

    self = [self initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithSessionConfiguration:self.session.configuration];
}

@end

#endif
