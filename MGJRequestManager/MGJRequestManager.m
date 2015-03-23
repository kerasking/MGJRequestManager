//
//  MGJRequestManager.m
//  MGJFoundation
//
//  Created by limboy on 12/10/14.
//  Copyright (c) 2014 juangua. All rights reserved.
//

#import "MGJRequestManager.h"

static NSString * const MGJRequestManagerCacheDirectory = @"requestCacheDirectory";
static NSString * const MGJFileProcessingQueue = @"MGJFileProcessingQueue";

@interface MGJResponseCache : NSObject

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key;

- (id <NSCoding>)objectForKey:(NSString *)key;

- (void)removeObjectForKey:(NSString *)key;

- (void)trimToDate:(NSDate *)date;

- (void)removeAllObjects;

@end

@implementation MGJResponseCache {
    NSCache *_memoryCache;
    NSFileManager *_fileManager;
    NSString *_cachePath;
    dispatch_queue_t _queue;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _memoryCache = [[NSCache alloc] init];
        _queue = dispatch_queue_create([MGJFileProcessingQueue UTF8String], DISPATCH_QUEUE_CONCURRENT);
        [self createCachesDirectory];
    }
    return self;
}

- (void)createCachesDirectory
{
    _fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachePath = [paths objectAtIndex:0];
    _cachePath = [cachePath stringByAppendingPathComponent:MGJRequestManagerCacheDirectory];
    BOOL isDirectory;
    if (![_fileManager fileExistsAtPath:_cachePath isDirectory:&isDirectory]) {
        __autoreleasing NSError *error = nil;
        BOOL created = [_fileManager createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:&error];
        if (!created) {
            NSLog(@"<MGJRequestManager> - create cache directory failed with error:%@", error);
        }
    }
}

- (NSString *)encodedString:(NSString *)string
{
    if (![string length])
        return @"";
    
    CFStringRef static const charsToEscape = CFSTR(".:/");
    CFStringRef escapedString = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                        (__bridge CFStringRef)string,
                                                                        NULL,
                                                                        charsToEscape,
                                                                        kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)escapedString;
}

- (NSString *)decodedString:(NSString *)string
{
    if (![string length])
        return @"";
    
    CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                          (__bridge CFStringRef)string,
                                                                                          CFSTR(""),
                                                                                          kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)unescapedString;
}


- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key
{
    NSString *encodedKey = [self encodedString:key];
    [_memoryCache setObject:object forKey:key];
    dispatch_async(_queue, ^{
        NSString *filePath = [_cachePath stringByAppendingPathComponent:encodedKey];
        BOOL written = [NSKeyedArchiver archiveRootObject:object toFile:filePath];
        if (!written) {
            NSLog(@"<MGJRequestManager> - set object to file failed");
        }
    });
}

- (id <NSCoding>)objectForKey:(NSString *)key
{
    NSString *encodedKey = [self encodedString:key];
    id<NSCoding> object = [_memoryCache objectForKey:encodedKey];
    if (!object) {
        NSString *filePath = [_cachePath stringByAppendingPathComponent:encodedKey];
        if ([_fileManager fileExistsAtPath:filePath]) {
            object = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        }
    }
    return object;
}

- (void)removeAllObjects
{
    [_memoryCache removeAllObjects];
    __autoreleasing NSError *error;
    BOOL removed = [_fileManager removeItemAtPath:_cachePath error:&error];
    if (!removed) {
        NSLog(@"<MGJRequestManager> - remove cache directory failed with error:%@", error);
    }
}

- (void)trimToDate:(NSDate *)date
{
    __autoreleasing NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL URLWithString:_cachePath]
                                                   includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&error];
    if (error) {
        NSLog(@"<MGJRequestManager> - get files error:%@", error);
    }

    dispatch_async(_queue, ^{
        for (NSURL *fileURL in files) {
            NSDictionary *dictionary = [fileURL resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil];
            NSDate *modificationDate = [dictionary objectForKey:NSURLContentModificationDateKey];
            if (modificationDate.timeIntervalSince1970 - date.timeIntervalSince1970 < 0) {
                [_fileManager removeItemAtPath:fileURL.absoluteString error:nil];
            }
        }
    });
}

- (void)removeObjectForKey:(NSString *)key
{
    NSString *encodedKey = [self encodedString:key];
    [_memoryCache removeObjectForKey:encodedKey];
    NSString *filePath = [_cachePath stringByAppendingPathComponent:encodedKey];
    if ([_fileManager fileExistsAtPath:filePath]) {
        __autoreleasing NSError *error = nil;
        BOOL removed = [_fileManager removeItemAtPath:filePath error:&error];
        if (!removed) {
            NSLog(@"<MGJRequestManager> - remove item failed with error:%@", error);
        }
    }
}

@end

@implementation MGJResponse @end

@implementation MGJRequestManagerConfiguration

- (AFHTTPRequestSerializer *)requestSerializer
{
    return _requestSerializer ? : [AFHTTPRequestSerializer serializer];
}

- (AFHTTPResponseSerializer *)responseSerializer
{
    return _responseSerializer ? : [AFJSONResponseSerializer serializer];
}

- (instancetype)copyWithZone:(NSZone *)zone
{
    MGJRequestManagerConfiguration *configuration = [[MGJRequestManagerConfiguration alloc] init];
    configuration.requestSerializer = self.requestSerializer;
    configuration.responseSerializer = self.responseSerializer;
    configuration.baseURL = self.baseURL;
    configuration.resultCacheDuration = self.resultCacheDuration;
    configuration.builtinParameters = [self.builtinParameters copy];
    configuration.userInfo = self.userInfo;
    return configuration;
}

@end

@interface MGJRequestManager ()
@property (nonatomic) AFHTTPRequestOperationManager *requestManager;
@property (nonatomic) NSMutableDictionary *chainedOperations;
@property (nonatomic) NSMapTable *completionBlocks;
@property (nonatomic) NSMapTable *operationMethodParameters;
@property (nonatomic) MGJResponseCache *cache;
@property (nonatomic) NSMutableArray *batchGroups;
@end

@implementation MGJRequestManager

@synthesize configuration = _configuration;

+ (instancetype)sharedInstance
{
    static MGJRequestManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.networkStatus = AFNetworkReachabilityStatusUnknown;
        [[AFNetworkReachabilityManager sharedManager] startMonitoring];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:AFNetworkingReachabilityDidChangeNotification object:nil];
        
        self.cache = [[MGJResponseCache alloc] init];
        self.chainedOperations = [[NSMutableDictionary alloc] init];
        self.completionBlocks = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory valueOptions:NSMapTableCopyIn];
        self.operationMethodParameters = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory valueOptions:NSMapTableStrongMemory];
        self.batchGroups = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)reachabilityChanged:(NSNotification *)notification
{
    self.networkStatus = [notification.userInfo[AFNetworkingReachabilityNotificationStatusItem] integerValue];
}

- (AFHTTPRequestOperation *)GET:(NSString *)URLString
                     parameters:(NSDictionary *)parameters
               startImmediately:(BOOL)startImmediately
           configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
              completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    return [self HTTPRequestOperationWithMethod:@"GET" URLString:URLString parameters:parameters startImmediately:startImmediately constructingBodyWithBlock:nil configurationHandler:configurationHandler completionHandler:completionHandler];
}

- (AFHTTPRequestOperation *)POST:(NSString *)URLString
                      parameters:(NSDictionary *)parameters
                startImmediately:(BOOL)startImmediately
            configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
               completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    return [self HTTPRequestOperationWithMethod:@"POST" URLString:URLString parameters:parameters startImmediately:startImmediately constructingBodyWithBlock:nil configurationHandler:configurationHandler completionHandler:completionHandler];
}

- (AFHTTPRequestOperation *)POST:(NSString *)URLString
                      parameters:(NSDictionary *)parameters
                startImmediately:(BOOL)startImmediately
       constructingBodyWithBlock:(void (^)(id<AFMultipartFormData>))block
            configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
               completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    return [self HTTPRequestOperationWithMethod:@"POST" URLString:URLString parameters:parameters startImmediately:startImmediately constructingBodyWithBlock:block configurationHandler:configurationHandler completionHandler:completionHandler];
}

- (AFHTTPRequestOperation *)PUT:(NSString *)URLString
                     parameters:(NSDictionary *)parameters
               startImmediately:(BOOL)startImmediately
           configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
              completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    return [self HTTPRequestOperationWithMethod:@"PUT" URLString:URLString parameters:parameters startImmediately:startImmediately constructingBodyWithBlock:nil configurationHandler:configurationHandler completionHandler:completionHandler];
}

- (AFHTTPRequestOperation *)DELETE:(NSString *)URLString
                        parameters:(NSDictionary *)parameters
                  startImmediately:(BOOL)startImmediately
              configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
                 completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    return [self HTTPRequestOperationWithMethod:@"DELETE" URLString:URLString parameters:parameters startImmediately:startImmediately constructingBodyWithBlock:nil configurationHandler:configurationHandler completionHandler:completionHandler];
}

- (AFHTTPRequestOperation *)HTTPRequestOperationWithMethod:(NSString *)method
                                                 URLString:(NSString *)URLString
                                                parameters:(NSDictionary *)parameters
                                          startImmediately:(BOOL)startImmediately
                                 constructingBodyWithBlock:(void (^)(id<AFMultipartFormData>))block
                                      configurationHandler:(MGJRequestManagerConfigurationHandler)configurationHandler
                                         completionHandler:(MGJRequestManagerCompletionHandler)completionHandler
{
    // 拿到 configuration 的副本，然后让调用方自定义该 configuration
    MGJRequestManagerConfiguration *configuration = [self.configuration copy];
    if (configurationHandler) {
        configurationHandler(configuration);
    }
    self.requestManager.requestSerializer = configuration.requestSerializer;
    self.requestManager.responseSerializer = configuration.responseSerializer;
    
    if (self.parametersHandler) {
        NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
        NSMutableDictionary *mutableBultinParameters = [NSMutableDictionary dictionaryWithDictionary:configuration.builtinParameters];
        self.parametersHandler(mutableParameters, mutableBultinParameters);
        parameters = [mutableParameters copy];
        configuration.builtinParameters = [mutableBultinParameters copy];
    }
    
    NSString *combinedURL = [URLString stringByAppendingString:[self serializeParams:configuration.builtinParameters]];
    NSMutableURLRequest *request;
    
    if (block) {
        request = [self.requestManager.requestSerializer multipartFormRequestWithMethod:@"POST" URLString:[[NSURL URLWithString:combinedURL relativeToURL:[NSURL URLWithString:configuration.baseURL]] absoluteString] parameters:parameters constructingBodyWithBlock:block error:nil];
    } else {
        request = [self.requestManager.requestSerializer requestWithMethod:method URLString:[[NSURL URLWithString:combinedURL relativeToURL:[NSURL URLWithString:configuration.baseURL]] absoluteString] parameters:parameters error:nil];
    }
    
    AFHTTPRequestOperation *operation = [self createOperationWithConfiguration:configuration request:request];
    
    if (!startImmediately) {
        NSMutableDictionary *methodParameters = [NSMutableDictionary dictionaryWithDictionary:@{
                                           @"method": method,
                                           @"URLString": URLString,
                                           }];
        if (parameters) {
            methodParameters[@"parameters"] = parameters;
        }
        if (block) {
            methodParameters[@"constructingBodyWithBlock"] = block;
        }
        if (configurationHandler) {
            methodParameters[@"configurationHandler"] = configurationHandler;
        }
        if (completionHandler) {
            methodParameters[@"completionHandler"] = completionHandler;
        }
        
        [self.operationMethodParameters setObject:methodParameters forKey:operation];
        return operation;
    }
    
    // 如果设置为使用缓存，那么先去缓存里看一下
    if (configuration.resultCacheDuration > 0 && [method isEqualToString:@"GET"]) {
        NSString *urlKey = [URLString stringByAppendingString:[self serializeParams:parameters]];
        id result = [self.cache objectForKey:urlKey];
        if (result) {
            completionHandler(nil, result, YES, nil);
        }
    }
    
    __weak typeof(self) weakSelf = self;
    
    void (^checkIfShouldDoChainOperation)(AFHTTPRequestOperation *) = ^(AFHTTPRequestOperation *operation){
        // TODO 不用每次都去找一下 ChainedOperations
        AFHTTPRequestOperation *nextOperation = [weakSelf findNextOperationInChainedOperationsBy:operation];
        if (nextOperation) {
            NSDictionary *methodParameters = [weakSelf.operationMethodParameters objectForKey:nextOperation];
            if (methodParameters) {
                [weakSelf HTTPRequestOperationWithMethod:methodParameters[@"method"]
                                               URLString:methodParameters[@"URLString"]
                                              parameters:methodParameters[@"parameters"]
                                        startImmediately:YES
                               constructingBodyWithBlock:methodParameters[@"constructingBodyWithBlock"]
                                    configurationHandler:methodParameters[@"configurationHandler"]
                                       completionHandler:methodParameters[@"completionHandler"]];
                [weakSelf.operationMethodParameters removeObjectForKey:nextOperation];
            } else {
                [weakSelf.requestManager.operationQueue addOperation:nextOperation];
            }
        }
    };
    
    // 对拿到的 response 再做一层处理
    BOOL (^handleResponse)(AFHTTPRequestOperation *, MGJResponse *, MGJRequestManagerConfiguration *) =  ^BOOL (AFHTTPRequestOperation *operation, MGJResponse *response, MGJRequestManagerConfiguration *configuration) {
        BOOL shouldStopProcessing = NO;
        
        // 先调用默认的处理
        if (weakSelf.configuration.responseHandler) {
            weakSelf.configuration.responseHandler(operation, response, &shouldStopProcessing);
        }
        
        // 如果客户端有定义过 responseHandler
        if (configuration.responseHandler) {
            configuration.responseHandler(operation, response, &shouldStopProcessing);
        }
        return shouldStopProcessing;
    };
    
    // 对 request 再做一层处理
    BOOL (^handleRequest)(AFHTTPRequestOperation *, id userInfo, MGJRequestManagerConfiguration *) =  ^BOOL (AFHTTPRequestOperation *operation, id userInfo, MGJRequestManagerConfiguration *configuration) {
        BOOL shouldStopProcessing = NO;
        
        // 先调用默认的处理
        if (weakSelf.configuration.requestHandler) {
            weakSelf.configuration.requestHandler(operation, userInfo, &shouldStopProcessing);
        }
        
        // 如果客户端有定义过 responseHandler
        if (configuration.requestHandler) {
            configuration.requestHandler(operation, userInfo, &shouldStopProcessing);
        }
        return shouldStopProcessing;
    };
    
    void (^handleFailure)(AFHTTPRequestOperation *, NSError *) = ^(AFHTTPRequestOperation *theOperation, NSError *error) {
        
        MGJResponse *response = [[MGJResponse alloc] init];
        response.error = error;
        response.result = nil;
        BOOL shouldStopProcessing = handleResponse(theOperation, response, configuration);
        if (shouldStopProcessing) {
            [weakSelf.completionBlocks removeObjectForKey:theOperation];
            return ;
        }
        
        completionHandler(response.error, response.result, NO, theOperation);
        [weakSelf.completionBlocks removeObjectForKey:theOperation];
        
        checkIfShouldDoChainOperation(theOperation);
    };
    
    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *theOperation, id responseObject){
        
        MGJResponse *response = [[MGJResponse alloc] init];
        response.error = nil;
        response.result = responseObject;
        BOOL shouldStopProcessing = handleResponse(theOperation, response, configuration);
        if (shouldStopProcessing) {
            [weakSelf.completionBlocks removeObjectForKey:theOperation];
            return ;
        }
        
        // 如果使用缓存，就把结果放到缓存中方便下次使用
        if (configuration.resultCacheDuration > 0 && [method isEqualToString:@"GET"] && !response.error) {
            // 不使用 builtinParameters
            NSString *urlKey = [URLString stringByAppendingString:[self serializeParams:parameters]];
            [weakSelf.cache setObject:response.result forKey:urlKey];
        }
        completionHandler(response.error, response.result, NO, theOperation);
        // 及时移除，避免循环引用
        [weakSelf.completionBlocks removeObjectForKey:theOperation];
        
        checkIfShouldDoChainOperation(theOperation);
    } failure:^(AFHTTPRequestOperation *theOperation, NSError *error){
        handleFailure(theOperation, error);
    }];
    
    if (!handleRequest(operation, configuration.userInfo, configuration)) {
        [self.requestManager.operationQueue addOperation:operation];
    } else {
        NSError *error = [NSError errorWithDomain:@"取消请求" code:-1 userInfo:nil];
        handleFailure(operation, error);
    }
    
    [self.completionBlocks setObject:operation.completionBlock forKey:operation];
    
    return operation;
}

- (void)startOperation:(AFHTTPRequestOperation *)operation
{
    NSDictionary *methodParameters = [self.operationMethodParameters objectForKey:operation];
    if (methodParameters) {
        [self HTTPRequestOperationWithMethod:methodParameters[@"method"]
                                       URLString:methodParameters[@"URLString"]
                                      parameters:methodParameters[@"parameters"]
                                startImmediately:YES
                       constructingBodyWithBlock:methodParameters[@"constructingBodyWithBlock"]
                            configurationHandler:methodParameters[@"configurationHandler"]
                               completionHandler:methodParameters[@"completionHandler"]];
        [self.operationMethodParameters removeObjectForKey:operation];
    } else {
        [self.requestManager.operationQueue addOperation:operation];
    }
}

- (NSArray *)runningRequests
{
    return self.requestManager.operationQueue.operations;
}

- (void)cancelAllRequest
{
    [self.requestManager.operationQueue cancelAllOperations];
}

- (void)cancelHTTPOperationsWithMethod:(NSString *)method url:(NSString *)url
{
    NSError *error;
    
    NSString *pathToBeMatched = [[[self.requestManager.requestSerializer requestWithMethod:method URLString:[[NSURL URLWithString:url] absoluteString] parameters:nil error:&error] URL] path];
    
    for (NSOperation *operation in [self.requestManager.operationQueue operations]) {
        if (![operation isKindOfClass:[AFHTTPRequestOperation class]]) {
            continue;
        }
        BOOL hasMatchingMethod = !method || [method  isEqualToString:[[(AFHTTPRequestOperation *)operation request] HTTPMethod]];
        BOOL hasMatchingPath = [[[[(AFHTTPRequestOperation *)operation request] URL] path] isEqual:pathToBeMatched];
        
        if (hasMatchingMethod && hasMatchingPath) {
            [operation cancel];
        }
    }
}

- (void)addOperation:(AFHTTPRequestOperation *)operation toChain:(NSString *)chain
{
    NSString *chainName = chain ? : @"";
    if (!self.chainedOperations[chainName]) {
        self.chainedOperations[chainName] = [[NSMutableArray alloc] init];
    }
    [self.chainedOperations[chainName] addObject:operation];
    if (((NSMutableArray *)self.chainedOperations[chainName]).count == 1) {
        [self.requestManager.operationQueue addOperation:operation];
    }
}

- (NSArray *)operationsInChain:(NSString *)chain
{
    return self.chainedOperations[chain];
}

- (void)removeOperation:(AFHTTPRequestOperation *)operation inChain:(NSString *)chain
{
    NSString *chainName = chain ? : @"";
    if (self.chainedOperations[chainName]) {
        NSMutableArray *chainedOperations = self.chainedOperations[chainName];
        [chainedOperations removeObject:operation];
    }
}

- (void)batchOfRequestOperations:(NSArray *)operations
                   progressBlock:(void (^)(NSUInteger, NSUInteger))progressBlock
                 completionBlock:(void (^)())completionBlock
{
    __block dispatch_group_t group = dispatch_group_create();
    [self.batchGroups addObject:group];
    __block NSInteger finishedOperationsCount = 0;
    NSInteger totalOperationsCount = operations.count;
    
    [operations enumerateObjectsUsingBlock:^(AFHTTPRequestOperation *operation, NSUInteger idx, BOOL *stop) {
        NSMutableDictionary *operationMethodParameters = [NSMutableDictionary dictionaryWithDictionary:[self.operationMethodParameters objectForKey:operation]];
        if (operationMethodParameters) {
            dispatch_group_enter(group);
            MGJRequestManagerCompletionHandler originCompletionHandler = [(MGJRequestManagerCompletionHandler) operationMethodParameters[@"completionHandler"] copy];
            
            MGJRequestManagerCompletionHandler newCompletionHandler = ^(NSError *error, id result, BOOL isFromCache, AFHTTPRequestOperation *theOperation) {
                if (!isFromCache) {
                    dispatch_group_leave(group);
                    if (progressBlock) {
                        progressBlock(++finishedOperationsCount, totalOperationsCount);
                    }
                    
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (originCompletionHandler) {
                        originCompletionHandler(error, result, isFromCache, theOperation);
                    }
                });
            };
            operationMethodParameters[@"completionHandler"] = newCompletionHandler;
            
            [self.operationMethodParameters setObject:operationMethodParameters forKey:operation];
            [self startOperation:operation];
            
        }
    }];
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self.batchGroups removeObject:group];
        if (completionBlock) {
            completionBlock();
        }
    });
}

- (AFHTTPRequestOperation *)reAssembleOperation:(AFHTTPRequestOperation *)operation
{
    AFHTTPRequestOperation *newOperation = [operation copy];
    newOperation.completionBlock = [self.completionBlocks objectForKey:operation];
    // 及时移除，避免循环引用
    [self.completionBlocks removeObjectForKey:operation];
    return newOperation;
}

#pragma mark - Utils

- (AFHTTPRequestOperation *)findNextOperationInChainedOperationsBy:(AFHTTPRequestOperation *)operation
{
    // 这个实现有优化的空间
    __block AFHTTPRequestOperation *theOperation;
    __weak typeof(self) weakSelf = self;
    
    [self.chainedOperations enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableArray *chainedOperations, BOOL *stop) {
        [chainedOperations enumerateObjectsUsingBlock:^(AFHTTPRequestOperation *requestOperation, NSUInteger idx, BOOL *stop) {
            if (requestOperation == operation) {
                if (idx < chainedOperations.count - 1) {
                    theOperation = chainedOperations[idx + 1];
                    *stop = YES;
                }
                [chainedOperations removeObject:requestOperation];
            }
        }];
        if (chainedOperations) {
            *stop = YES;
        }
        if (!chainedOperations.count) {
            [weakSelf.chainedOperations removeObjectForKey:key];
        }
    }];
    
    return theOperation;
}

- (AFHTTPRequestOperationManager *)requestManager
{
    if (!_requestManager) {
        _requestManager = [AFHTTPRequestOperationManager manager] ;
    }
    return _requestManager;
}

- (MGJRequestManagerConfiguration *)configuration
{
    if (!_configuration) {
        _configuration = [[MGJRequestManagerConfiguration alloc] init];
    }
    return _configuration;
}

- (void)setConfiguration:(MGJRequestManagerConfiguration *)configuration
{
    if (_configuration != configuration) {
        _configuration = configuration;
        if (_configuration.resultCacheDuration > 0) {
            double pastTimeInterval = [[NSDate date] timeIntervalSince1970] - _configuration.resultCacheDuration;
            NSDate *pastDate = [NSDate dateWithTimeIntervalSince1970:pastTimeInterval];
            [self.cache trimToDate:pastDate];
        }
    }
}

- (AFHTTPRequestOperation *)createOperationWithConfiguration:(MGJRequestManagerConfiguration *)configuration request:(NSURLRequest *)request
{
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = self.requestManager.responseSerializer;
    operation.shouldUseCredentialStorage = self.requestManager.shouldUseCredentialStorage;
    operation.credential = self.requestManager.credential;
    operation.securityPolicy = self.requestManager.securityPolicy;
    operation.completionQueue = self.requestManager.completionQueue;
    operation.completionGroup = self.requestManager.completionGroup;
    return operation;
}

-(NSString *)serializeParams:(NSDictionary *)params {
    NSMutableArray *parts = [NSMutableArray array];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id<NSObject> obj, BOOL *stop) {
        NSString *encodedKey = [key stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
        NSString *encodedValue = [obj.description stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
        NSString *part = [NSString stringWithFormat: @"%@=%@", encodedKey, encodedValue];
        [parts addObject: part];
    }];
    NSString *queryString = [parts componentsJoinedByString: @"&"];
    return queryString ? [NSString stringWithFormat:@"?%@", queryString] : @"";
}
@end
