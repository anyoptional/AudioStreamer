//
//  ARAudioDownloader.m
//  AudioKit
//
//  Created by Archer on 2017/5/16.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioDownloader.h"
#import <pthread.h>

@interface ARAudioDownloader ()
@property (copy) ARAudioDownloaderCompletedBlock completedBlock;
@property (copy) ARAudioDownloaderProgressBlock progressBlock;
@property (copy) ARAudioDownloaderDidReceiveResponseBlock didReceiveResponseBlock;
@property (copy) ARAudioDownloaderDidReceiveDataBlock didReceiveDataBlock;

@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, copy) NSString *responseString;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, assign) NSUInteger responseContentLength;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSString *statusMessage;
@property (nonatomic, assign) NSUInteger downloadSpeed;
@property (nonatomic, assign, getter=isFailed) BOOL failed;

@property (nonatomic, assign) CFHTTPMessageRef message;
@property (nonatomic, assign) CFReadStreamRef readStream;
@property (nonatomic, assign) CFAbsoluteTime startedTime;
@property (nonatomic, assign) NSUInteger receivedLength;

@end

@implementation ARAudioDownloader

+ (instancetype)loaderWithAudioURL:(NSURL *)audioURL
{
    if (!audioURL) return nil;
    
    return [[[self class] alloc] initWithAudioURL:audioURL];
}

- (instancetype)initWithAudioURL:(NSURL *)audioURL
{
    self = [super init];
    if (self) {
        _timeoutInterval = [self.class defaultTimeoutInterval];
        // 创建CFHTTPMessageRef
        _message = CFHTTPMessageCreateRequest(kCFAllocatorDefault, CFSTR("GET"), (__bridge CFURLRef)audioURL, kCFHTTPVersion1_1);
    }
    return self;
}

- (void)dealloc
{
    if (_readStream != NULL) {
        [self _closeResponseStream];
        CFRelease(_readStream);
    }
    
    CFRelease(_message);
}

+ (NSTimeInterval)defaultTimeoutInterval
{
    return 15.0;
}

- (NSString *)responseString
{
    if (_responseData == nil) {
        return nil;
    }
    
    if (_responseString == nil) {
        _responseString = [[NSString alloc] initWithData:_responseData encoding:NSUTF8StringEncoding];
    }
    
    return _responseString;
}

#pragma mark  --  HTTP

- (void)start
{
    // 上次请求未结束
    if (_readStream != NULL) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
    _readStream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, _message);
    CFReadStreamSetProperty(_readStream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
    CFReadStreamSetProperty(_readStream, CFSTR("_kCFStreamPropertyReadTimeout"), (__bridge CFNumberRef)[NSNumber numberWithDouble:_timeoutInterval]);
    CFReadStreamSetProperty(_readStream, CFSTR("_kCFStreamPropertyWriteTimeout"), (__bridge CFNumberRef)[NSNumber numberWithDouble:_timeoutInterval]);
    
    CFStreamClientContext context;
    memset(&context, 0, sizeof(context));
    context.info = (__bridge void *)self;
    CFReadStreamSetClient(_readStream, kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred, ARReadStreamClientCallBack, &context);
    
    // 让readStream运行在新建线程的运行循环上(即在新线程请求数据)
    CFReadStreamScheduleWithRunLoop(_readStream, scheduledRunloop(), kCFRunLoopDefaultMode);
    CFReadStreamOpen(_readStream);
#pragma clang diagnostic pop
   
    _startedTime = CFAbsoluteTimeGetCurrent();
    _downloadSpeed = 0;
}

// 下载的上下文
static struct {
    pthread_t tid;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    CFRunLoopRef runloop;
} downloadContext;

static CFRunLoopRef scheduledRunloop(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pthread_mutex_init(&downloadContext.mutex, NULL);
        pthread_cond_init(&downloadContext.cond, NULL);
        downloadContext.runloop = NULL;
        
        // 创建一个新线程
        void * thread_main(void *info);
        pthread_create(&downloadContext.tid, NULL, thread_main, NULL);
        // 等待runloop创建
        pthread_mutex_lock(&downloadContext.mutex);
        while (downloadContext.runloop == NULL) {
            pthread_cond_wait(&downloadContext.cond, &downloadContext.mutex);
        }
        pthread_mutex_unlock(&downloadContext.mutex);
    });
    return downloadContext.runloop;
}

static void * thread_main(void *info)
{
    pthread_setname_np("com.archer.downloader.thread");
    
    // 获取线程对应的runloop
    pthread_mutex_lock(&downloadContext.mutex);
    downloadContext.runloop = CFRunLoopGetCurrent();
    pthread_cond_signal(&downloadContext.cond);
    pthread_mutex_unlock(&downloadContext.mutex);
    
    // 添加一个Source，避免runloop退出
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(context));
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    CFRunLoopAddSource(downloadContext.runloop, source, kCFRunLoopDefaultMode);
    // 开启runloop
    CFRunLoopRun();
    
    // 退出runloop时清理
    CFRunLoopRemoveSource(downloadContext.runloop, source, kCFRunLoopDefaultMode);
    CFRelease(source);
    pthread_mutex_destroy(&downloadContext.mutex);
    pthread_cond_destroy(&downloadContext.cond);
    
    return NULL;
}

#pragma mark  --  CFReadStreamClientCallBack

static void ARReadStreamClientCallBack(CFReadStreamRef stream, CFStreamEventType type, void *clientCallBackInfo)
{
    ARAudioDownloader *downloder = (__bridge ARAudioDownloader *)(clientCallBackInfo);
    @autoreleasepool {
        @synchronized (downloder) {
            switch (type) {
                    // 有数据可拿
                case kCFStreamEventHasBytesAvailable:
                    [downloder _eventHasBytesAvailable];
                    break;
                    // 提取数据结束
                case kCFStreamEventEndEncountered:
                    [downloder _eventEndEncountered];
                    break;
                    // 请求发生错误
                case kCFStreamEventErrorOccurred:
                    [downloder _eventErrorOccurred];
                    break;
                    
                default:
                    break;
            }
        }
    }
}

- (void)_eventHasBytesAvailable
{
    // 获取返回头
    [self _readResponseHeaders];
    
    // 无数据可读
    if (!CFReadStreamHasBytesAvailable(_readStream)) return;
    
    // 设置读取的buffer大小
    CFIndex bufferSize;
    if (_responseContentLength > 100000) {
        bufferSize = 70560;
    }
    else if (_responseContentLength > 35280) {
        bufferSize = 35280;
    }
    else {
        bufferSize = 17640;
    }
    
    // 读取数据
    UInt8 buffer[bufferSize];
    CFIndex bytesRead = CFReadStreamRead(_readStream, buffer, bufferSize);
    if (bytesRead < 0) {// 获取数据失败
        [self _eventEndEncountered];
        return;
    }
    
    if (bytesRead > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)bytesRead];
        
        @synchronized(self) {
            if (_didReceiveDataBlock == NULL) {
                if (_responseData == nil) {
                    _responseData = [NSMutableData data];
                }
                
                [_responseData appendData:data];
            }
            else {
                [self _invokeDidReceiveDataBlockWithData:data];
            }
        }
        
        _receivedLength += (unsigned long)bytesRead;
        [self _updateProgress];
        [self _updateDownloadSpeed];
    }
}

- (void)_updateProgress
{
    double downloadProgress;
    if (_responseContentLength == 0) {
        if (_responseHeaders != nil) {
            downloadProgress = 1.0;
        }
        else {
            downloadProgress = 0.0;
        }
    }
    else {
        downloadProgress = (double)_receivedLength / _responseContentLength;
    }
    
    [self _invokeProgressBlockWithDownloadProgress:downloadProgress];
}

- (void)_updateDownloadSpeed
{
    _downloadSpeed = _receivedLength / (CFAbsoluteTimeGetCurrent() - _startedTime);
}

- (void)_readResponseHeaders
{
    if (_responseHeaders != nil) return;
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
    CFHTTPMessageRef message = (CFHTTPMessageRef)CFReadStreamCopyProperty(_readStream, kCFStreamPropertyHTTPResponseHeader);
#pragma clang diagnostic pop

    if (message == NULL) return;
    
    if (!CFHTTPMessageIsHeaderComplete(message)) {
        CFRelease(message);
        return;
    }
    
    _responseHeaders = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(message));
    _statusCode = CFHTTPMessageGetResponseStatusCode(message);
    _statusMessage = CFBridgingRelease(CFHTTPMessageCopyResponseStatusLine(message));
    CFRelease(message);
    
    [self _checkResponseContentLength];
    [self _invokeDidReceiveResponseBlock];
}

- (void)_checkResponseContentLength
{
    if (_responseHeaders == nil) return;
    
    NSString *string = [_responseHeaders objectForKey:@"Content-Length"];
    if (string == nil) return;
    
    _responseContentLength = (NSUInteger)[string integerValue];
}

- (void)_eventEndEncountered
{
    [self _readResponseHeaders];
    [self _invokeProgressBlockWithDownloadProgress:1.0];
    [self _invokeCompletedBlock];
}

- (void)_eventErrorOccurred
{
    [self _readResponseHeaders];
    
    _failed = YES;
    [self _closeResponseStream];
    [self _invokeCompletedBlock];
}

- (void)cancel
{
    if (_readStream == NULL || _failed) return;
    
    __block CFTypeRef __downloader = CFBridgingRetain(self);
    CFRunLoopPerformBlock(scheduledRunloop(), kCFRunLoopDefaultMode, ^{
        @autoreleasepool {
            [(__bridge ARAudioDownloader *)__downloader _closeResponseStream];
            CFBridgingRelease(__downloader);
        }
    });
}

- (void)_closeResponseStream
{
    CFReadStreamClose(_readStream);
    CFReadStreamUnscheduleFromRunLoop(_readStream, scheduledRunloop(), kCFRunLoopDefaultMode);
    CFReadStreamSetClient(_readStream, kCFStreamEventNone, NULL, NULL);
}

#pragma mark  --  设置回调的block

- (void)updateDidReceiveResponseBlock:(ARAudioDownloaderDidReceiveResponseBlock)didReceiveResponseBlock
{
    _didReceiveResponseBlock = didReceiveResponseBlock;
}

- (void)updateDidRecievedDataBlock:(ARAudioDownloaderDidReceiveDataBlock)didReceiveDataBlock
{
    _didReceiveDataBlock = didReceiveDataBlock;
}

- (void)updateProgressBlock:(ARAudioDownloaderProgressBlock)progressBlock
{
    _progressBlock = progressBlock;
}

- (void)updateCompletedBlock:(ARAudioDownloaderCompletedBlock)completedBlock
{
    _completedBlock = completedBlock;
}

- (void)_invokeCompletedBlock
{
    @synchronized(self) {
        if (_completedBlock != NULL) {
            _completedBlock();
        }
    }
}

- (void)_invokeProgressBlockWithDownloadProgress:(double)downloadProgress
{
    @synchronized(self) {
        if (_progressBlock != NULL) {
            _progressBlock(downloadProgress);
        }
    }
}

- (void)_invokeDidReceiveResponseBlock
{
    @synchronized(self) {
        if (_didReceiveResponseBlock != NULL) {
            _didReceiveResponseBlock();
        }
    }
}

- (void)_invokeDidReceiveDataBlockWithData:(NSData *)data
{
    @synchronized(self) {
        if (_didReceiveDataBlock != NULL) {
            _didReceiveDataBlock(data);
        }
    }
}

@end
