//
//  ARAudioEventLoop.m
//  AudioStreamer
//
//  Created by Archer on 2017/5/20.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioEventLoop.h"
#import "ARAudioLPCM.h"
#import "ARAudioStreamer.h"
#import "ARAudioProvider.h"
#import "ARAudioRenderer.h"
#import "ARAudioDecoder.h"
#import "ARAudioFileInfo.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIApplication.h>
#import <sys/event.h>
#import <pthread.h>

///=====================================================================
/// 用来引用一些私有属性
@interface ARAudioStreamer ()
@property (nonatomic) pthread_mutex_t mutex;
@property (nonatomic, assign) ARAudioStreamerStatus status;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) ARAudioProvider *fileProvider;
@property (nonatomic, strong) ARAudioRenderer *renderer;
@property (nonatomic, strong) ARAudioFileInfo *fileInfo;
@property (nonatomic, strong) ARAudioDecoder *decoder;
@property (nonatomic, assign) NSInteger timingOffset;
@property (nonatomic, assign) double bufferingRatio;
@property (nonatomic, assign, getter=isPausedByInterruption) BOOL pausedByInterruption;
@end
///=====================================================================

static UIBackgroundTaskIdentifier oldTaskId;
static void executeInBackground(void(^bgTask)(void))
{
    // 申请一点后台执行时间
    UIBackgroundTaskIdentifier newTaskId = UIBackgroundTaskInvalid;
    // 在这里进行播放下一曲操作
    bgTask();
    newTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
    if (newTaskId != UIBackgroundTaskInvalid && oldTaskId != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask: oldTaskId];
    }
    oldTaskId = newTaskId;
}

/**
 *  这个枚举定义了播放过程中可能出现的各种情况
 */
typedef NS_ENUM(uint64_t, event_type) {
    // 播放
    event_play,
    // 暂停
    event_pause,
    // 停止
    event_stop,
    // seek
    event_seek,
    // 切换上下曲
    event_streamer_changed,
    // 来自audioProvider，用于更新下载进度等
    event_provider_events,
    // 打断开始
    event_interruption_begin,
    // 打断结束
    event_interruption_end,
    // 拔出耳机
    event_old_device_unavailable,
    // 清理
    event_finalizing,
    // 占位
    event_timeout
};

@interface ARAudioEventLoop ()
@property (nonatomic, strong) ARAudioRenderer *renderer;
@property (nonatomic, assign) NSUInteger decoderBufferSize;
@property (nonatomic, copy) ARAudioProviderEventBlock fileProviderEventBlock;
@property (nonatomic, assign) int kq;
@property (nonatomic) void *lastKQUserData;
@property (nonatomic) pthread_mutex_t mutex;
@property (nonatomic) pthread_t thread;
@end

@implementation ARAudioEventLoop

+ (instancetype)sharedEventLoop
{
    static ARAudioEventLoop *sharedEventLoop = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedEventLoop = [[ARAudioEventLoop alloc] init];
    });
    
    return sharedEventLoop;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        // 初始化kernel queue
        _kq = kqueue();
        // 初始化互斥锁
        pthread_mutex_init(&_mutex, NULL);
        // 设置audio session
        [self _setupAudioSession];
        [self _registerAudioSessionNotifications];
        [self _setupFileProviderEventBlock];
        _renderer = [ARAudioRenderer new];
        [_renderer prepare];
        
        // 注册播放事件
        [self _enableEvents];
        // 启动播放线程
        [self _createThread];
    }
    return self;
}

- (void)_setupFileProviderEventBlock
{
    __unsafe_unretained ARAudioEventLoop *eventloop = self;
    _fileProviderEventBlock = ^{
        [eventloop _sendEvent:event_provider_events];
    };
}

- (void)dealloc
{
    [self _sendEvent:event_finalizing];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
    
    pthread_join(_thread, NULL);
    close(_kq);
    pthread_mutex_destroy(&_mutex);
}

#pragma mark  --  Property's Getter && Setter


#pragma mark  --  public methods

- (void)play
{
    [self _sendEvent:event_play];
}

- (void)pause
{
    [self _sendEvent:event_pause];
}

- (void)stop
{
    [self _sendEvent:event_stop];
}

#pragma mark  --  audio session

- (BOOL)_setupAudioSession
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    NSError *sessionError = nil;
    BOOL status = [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&sessionError];
    if (sessionError != nil) {
        NSLog(@"error happens,audio session init failed:%@",sessionError);
    }
    return status;
}

- (void)_registerAudioSessionNotifications
{
    // 注册打断监听
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_audioSessionInterruptionListener:) name:AVAudioSessionInterruptionNotification object:nil];
    // 注册切换路由的监听
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_audioSessionRouteChangeListener:) name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)_audioSessionInterruptionListener:(NSNotification *)notification
{
    // 获取打断的描述信息
    NSDictionary *infoMap = [notification userInfo];
    // 获取打断的状态
    AVAudioSessionInterruptionType type =
    [infoMap [AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    // 能否重新激活AudioSession
    AVAudioSessionInterruptionOptions option = [infoMap [AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    // 打断开始
    if (type == AVAudioSessionInterruptionTypeBegan) {
        // 更新UI，暂停播放
        [_renderer setInterrupted:YES];
        [_renderer stop];
        [self _sendEvent:event_interruption_begin];
    } else if (type == AVAudioSessionInterruptionTypeEnded){
        [self _sendEvent:event_interruption_end
                userData:(void *)(uintptr_t)option];
    } 
}

- (void)_audioSessionRouteChangeListener:(NSNotification *)notification
{
    // 取出描述信息
    NSDictionary *routeChangeMap = notification.userInfo;
    // 取出音频输出方式改变的原因
    NSInteger routeChangeReason = [[routeChangeMap
                                    valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    if (routeChangeReason != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        return;
    }
    
    AVAudioSessionRouteDescription *previousRouteDescription = [routeChangeMap objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    NSArray *previousOutputRoutes =[previousRouteDescription outputs];
    if ([previousOutputRoutes count] == 0) {
        return;
    }
    
    NSString *previousOutputRouteType = [[previousOutputRoutes objectAtIndex:0] portType];
    if (previousOutputRouteType == nil ||
        (![previousOutputRouteType isEqualToString:AVAudioSessionPortHeadphones] &&
         ![previousOutputRouteType isEqualToString:AVAudioSessionPortBluetoothA2DP])) {
            return;
        }
        
    [self _sendEvent:event_old_device_unavailable];
}

#pragma mark  --  kqueue

//struct event就是kevent()操作的最基本的事件结构。
//kevent()是一个系统调用syscall，而kqueue是freebsd内核中的一个事件队列kernel queue。
//kevent()是kqueue的用户接口，是对kqueue进行添加，删除操作的用户态的接口。

- (void)_enableEvents
{
    /**
     1、 struct event 结构体定义如下：
     
     struct kevent {
     uintptr_t	ident;		identifier for this event
     int16_t		filter;		filter for event
     uint16_t	flags;		general flags
     uint32_t	fflags;		filter-specific flags
     intptr_t	data;		filter-specific data
     void		*udata;		opaque user data identifier
     };
     
     ident     – 标记事件的描述符, socket fd, file fd
     filter    – 事件的类型, 读事件:EVFILT_READ, 写事件:EVFILT_WRITE, 用户事
     件:EVFILT_USER
     flags     – 事件的行为, 对kqueue的操作:
     添加到kqueue中:EV_ADD, 从kqueue中删除:EV_DELETE, 这两种是主要的行为。
     响应事件EV_ENABLE， 不响应事件EV_DISABLE
     一次性事件:EV_ONESHOT, 此事件是或操作, 指定了该事件, kevent()返回后, 事件会从kqueue中删除。
     更新事件: EV_CLEAR,此事件是或操作, 手册上的解释是，当事件通知给用户后，事件的状态会被重置。可以用在类似于epoll的ET模式，也可以用在描述符有时会出错的情况。
     其他事件: EOF事件:EV_EOF, 错误事件:EV_ERROR(返回值)。
     fflags    -
     data      -
     udata     – 用户指定的数据
     
     
     2、kevent()调用参数解读:
     函数声明如下：
     int kevent(int kq,
     const struct kevent *changelist,
     int nchanges,
     struct kevent *eventlist,
     int nevents,
     const struct timespec *timeout);
     
     kq           - kqueue() 返回的唯一描述符, 标记着一个内核队列
     changelist   – 需要对kqueue进行修改的事件集合, 此参数就是kevent()对目前kqueue中的事件的
     操作，比如删除kqueue中已经存在的事件，或者向kqueue中添加新的事件，也就是说，
     kevent()通过此参数对kqueue的修改
     nchanges     – 需要修改的事件的个数
     eventlist    – kevent()会把所有事件存储在events中
     nevents      – kevent()需要知道存储空间有多大, 若nevents == 0 : kevent()会立即返回
     timeout      – 超时控制, 若timeout == NULL，kevent()会一直等到有关注的事件发生;若
     timeout != NULLkevent()会等待指定的时间
     
     3、注意点
     1) 指定EV_ADD|EV_ONESHOT或者EV_DELETE|EV_ONESHOT的行为, kevent()返回后, 会把事件从kqueue中删除;
     2) 当事件类型指定为EVFILT_SIGNAL的时候, struct event 中data会返回此时信号发生了多少次
     3) 如果 nevents == 0, kevent()会立即返回, 不会理会timeout指定的超时时间, 这是一种直接注册事件的方法.
     
     4、如何使用
     1）注册 / 反注册
     注意 kevent() 中的 nevents 这个输入参数，当将其设为 0，且传入合法的 changelist 和 nchanges，就会将 changelist 中的事件注册到 kqueue 中。
     当关闭某文件描述符时，与之关联的事件会被自动地从 kqueue 移除。
     2）允许 / 禁止过滤器事件
     通过 flags EV_ENABLE 和 EV_DISABLE 使过滤器事件有效或无效。这个功能在利用 EVFILT_WRITE 发送数据时非常有用。
     3）等待事件通知
     将 nchange 设置成 0，当然要传入其它合法的参数，当 kevent 非错误和超时返回时，在 eventlist 和 nevents 中就保存可用事件集合。
     
     */
    
    for (uint64_t event = event_play; event <= event_finalizing; ++event) {
        struct kevent kev;
        /**
         EV_SET宏其实是展开kevent结构体对每个结构体成员赋值。
         
         ident是我们自定义的事件，由event_type枚举指定
         filter是用户自定义事件
         flags指定响应此事件并将其添加进kqueue,并且响应后清空事件状态
         udata为NULL，没有附加数据
         */
        EV_SET(&kev, event, EVFILT_USER, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, NULL);
        /**
         eventlist == NULL
         nevents == 0,并且指定了有效的changelist和nchanges,
         所以我们的自定义事件可以注册到kqueue中
         */
        kevent(_kq, &kev, 1, NULL, 0, NULL);
    }
}

- (void)_sendEvent:(event_type)event
{
    [self _sendEvent:event userData:NULL];
}

- (void)_sendEvent:(event_type)event userData:(void *)userData
{
    // NOTE_TRIGGER:此标志会触发输入事件，并将其输出，此标志用于EVFILT_USER
    // 使用NOTE_TRIGGER之后事件会被触发，存储到eventlist
    struct kevent kev;
    EV_SET(&kev, event, EVFILT_USER, 0, NOTE_TRIGGER, 0, userData);
    // 此前所有自定义事件已经注册好了，以下相当于触发事件
    kevent(_kq, &kev, 1, NULL, 0, NULL);
}

- (event_type)_waitForEventWithTimeout:(NSUInteger)timeout
{
    struct timespec _ts;
    struct timespec *ts = NULL;
    if (timeout != NSUIntegerMax) {
        ts = &_ts;
        
        ts->tv_sec = timeout / 1000;
        ts->tv_nsec = (timeout % 1000) * 1000;
    }
    
    while (1) {
        struct kevent kev;
        // changelist == NULL,nchanged == 0,表示等待事件的发生
        // kevent 调用会阻塞当前线程
        // 经过NOTE_TRIGGER的设置之后，事件触发了被存储到kev里面
        int n = kevent(_kq, NULL, 0, &kev, 1, ts);
        // 返回值大于0表示成功执行
        if (n > 0) {
            // 判断一下是不是我们的自定义事件
            if (kev.filter == EVFILT_USER &&
                kev.ident >= event_play &&
                kev.ident <= event_finalizing) {
                _lastKQUserData = kev.udata;
                return kev.ident;
            }
        } else {
            break;
        }
    }
    
    return event_timeout;
}

#pragma mark  --  thread

- (void)_createThread
{
    pthread_create(&_thread, NULL, eventLoopMain, (__bridge void *)(self));
}

static void *eventLoopMain(void *info)
{
    pthread_setname_np("com.archer.eventloop");
    ARAudioEventLoop *eventloop = (__bridge ARAudioEventLoop *)(info);
    @autoreleasepool {
        [eventloop _eventLoop];
    }
    return NULL;
}

- (void)_eventLoop
{
    // 第一次播放 streamer为nil,
    // play调用会设置currentStreamer，发出streamer_changed事件
    // streamer_changed事件也发生在切换上下曲（其实也是在play调用中）和stop时
    ARAudioStreamer *streamer = nil;
    
    // 循环开始
    while (1) {
        // 用@autoreleasepool{}释放产生的大量临时对象
        @autoreleasepool {
            // streamer不为空，说明至少播放过了
            if (streamer != nil) {
                switch ([streamer status]) {
                    case ARAudioStreamerPaused:
                    case ARAudioStreamerIdle:
                    case ARAudioStreamerFinished:
                    case ARAudioStreamerBuffering:
                    case ARAudioStreamerErrorOccured:
                        // 阻塞，直到等到有事件发生
                        if (![self _handleEvent:[self _waitForEventWithTimeout:NSUIntegerMax]
                                   withStreamer:&streamer]) {
                            return;
                        }
                        break;
                    default:
                        break;
                }
            }else {
                // 第一次播放 || stop之后再次播放 || 切换上下曲
                if (![self _handleEvent:[self _waitForEventWithTimeout:NSUIntegerMax] withStreamer:&streamer]) {
                    return;
                }
            }
            // timeout为0，不等待事件产生 所以会返回没有注册的event_timeout
            if (![self _handleEvent:[self _waitForEventWithTimeout:0]
                       withStreamer:&streamer]) { // 关系到seek
                return;
            }
            
            if (streamer != nil) {
                [self _handleStreamer:streamer];
            }
        }
    }
}

- (BOOL)_handleEvent:(event_type)event withStreamer:(ARAudioStreamer **)streamer
{
    if (event == event_play) {
        if (*streamer != nil &&
            ([*streamer status] == ARAudioStreamerPaused ||
             [*streamer status] == ARAudioStreamerIdle ||
             [*streamer status] == ARAudioStreamerFinished)) {
                if ([_renderer isInterrupted]) {
                    if ([self _setupAudioSession]) {
                        [*streamer setStatus:ARAudioStreamerPlaying];
                        [_renderer setInterrupted:NO];
                    }
                }
                else {
                    [*streamer setStatus:ARAudioStreamerPlaying];
                }
            }
    }
    else if (event == event_pause) {
        if (*streamer != nil &&
            ([*streamer status] != ARAudioStreamerPaused &&
             [*streamer status] != ARAudioStreamerIdle &&
             [*streamer status] != ARAudioStreamerFinished)) {
                [_renderer stop];
                [*streamer setStatus:ARAudioStreamerPaused];
            }
    }
    else if (event == event_stop) {
        if (*streamer != nil &&
            [*streamer status] != ARAudioStreamerIdle) {
            if ([*streamer status] != ARAudioStreamerPaused) {
                [_renderer stop];
            }
            [_renderer flush];
            [*streamer setDecoder:nil];
            [*streamer setFileInfo:nil];
            [*streamer setStatus:ARAudioStreamerIdle];
        }
    }
    else if (event == event_seek) {
        if (*streamer != nil &&
            [*streamer decoder] != nil) {
            NSUInteger milliseconds = MIN((NSUInteger)(uintptr_t)_lastKQUserData,[[*streamer fileInfo] estimatedDuration] * 1000.0);
            [*streamer setTimingOffset:(NSInteger)milliseconds - (NSInteger)[_renderer currentTime]];
            [[*streamer decoder] seekToTime:milliseconds];
            [_renderer flushShouldResetTiming:NO];
        }
    }
    else if (event == event_streamer_changed) {
        [_renderer stop];
        [_renderer flush];
        
        [[*streamer fileProvider] setEventBlock:NULL];
        *streamer = _currentStreamer;
        [[*streamer fileProvider] setEventBlock:_fileProviderEventBlock];
    }
    else if (event == event_provider_events) {
        if (*streamer != nil &&
            [*streamer status] == ARAudioStreamerBuffering) {
            [*streamer setStatus:ARAudioStreamerPlaying];
        }
        
        [*streamer setBufferingRatio:(double)[[*streamer fileProvider] receivedLength] / [[*streamer fileProvider] expectedLength]];
    }
    else if (event == event_finalizing) {
        return NO;
    }
    else if (event == event_interruption_begin) {
        if (*streamer != nil &&
            ([*streamer status] != ARAudioStreamerPaused &&
             [*streamer status] != ARAudioStreamerIdle &&
             [*streamer status] != ARAudioStreamerFinished)) {
                [self performSelector:@selector(pause) onThread:[NSThread mainThread] withObject:nil waitUntilDone:NO];
                [*streamer setPausedByInterruption:YES];
            }
    }
    else if (event == event_interruption_end) {
        const AVAudioSessionInterruptionOptions options = (AVAudioSessionInterruptionOptions)(uintptr_t)_lastKQUserData;
        
        if (options == AVAudioSessionInterruptionOptionShouldResume) {
            executeInBackground(^{
                if ([self _setupAudioSession]) {
                    [_renderer setInterrupted:NO];
                    
                    if (*streamer != nil &&
                        [*streamer status] == ARAudioStreamerPaused &&
                        [*streamer isPausedByInterruption]) {
                        [*streamer setPausedByInterruption:NO];
                        [self performSelector:@selector(play) onThread:[NSThread mainThread] withObject:nil waitUntilDone:NO];
                    }
                }
            });
        }
    }
    else if (event == event_old_device_unavailable) {
        if (*streamer != nil) {
            if ([*streamer status] != ARAudioStreamerPaused &&
                [*streamer status] != ARAudioStreamerIdle &&
                [*streamer status] != ARAudioStreamerFinished) {
                [self performSelector:@selector(pause)
                             onThread:[NSThread mainThread]
                           withObject:nil
                        waitUntilDone:NO];
            }
            
            [*streamer setPausedByInterruption:NO];
        }
    }
    else if (event == event_timeout) {
    }
    
    return YES;
}

- (void)_handleStreamer:(ARAudioStreamer *)streamer
{
    // streamer 为空，没有必要继续处理了
    if (!streamer) return;
    
    // 前面已经处理了除playing之外的所以状态
    if ([streamer status] != ARAudioStreamerPlaying) {
        return;
    }
    
    // 无法获取音频数据
    if ([[streamer fileProvider] isFailed]) {
        [streamer setStatus:ARAudioStreamerErrorOccured];
        return;
    }
    
    // 如果数据未准备完毕，更改状态为buffering
    if (![[streamer fileProvider] isReady]) {
        [streamer setStatus:ARAudioStreamerBuffering];
        return;
    }
    
    // 获取音频信息
    if ([streamer fileInfo] == nil) {
        [streamer setFileInfo:[ARAudioFileInfo fileInfoWithProvider:[streamer fileProvider]]];
        if (![[streamer fileInfo] isAvailable]) {
            [streamer setStatus:ARAudioStreamerErrorOccured];
            return;
        }
        
        [streamer setDuration:(NSTimeInterval)[[streamer fileInfo] estimatedDuration]];
    }
    
    // 获取解码器
    if ([streamer decoder] == nil) {
        [streamer setDecoder:[ARAudioDecoder decoderWithAudioFileInfo:[streamer fileInfo]]];
        if (![[streamer decoder] prepare]) {

            [streamer setStatus:ARAudioStreamerErrorOccured];
            return;
        }
    }
    
    // 准备就绪，开始解码
    switch ([[streamer decoder] decodeOnce]) {
        case AudioDecodingSucceeded:
            break;
            
        case AudioDecodingFailed:
        {
            [streamer setStatus:ARAudioStreamerErrorOccured];
            return;
        }
        case AudioDecodingEndEncountered:
            [_renderer stop];
            [streamer setDecoder:nil];
            [streamer setFileInfo:nil];
            [streamer setStatus:ARAudioStreamerFinished];
            return;
            
        case AudioDecodingWaiting:
            [streamer setStatus:ARAudioStreamerBuffering];
            return;
    }
    
    void *bytes = NULL;
    NSUInteger length = 0;
    [[[streamer decoder] lpcm] readBytes:&bytes length:&length];
    if (bytes != NULL) {
        [_renderer renderBytes:bytes length:length];
        free(bytes);
    }
}

- (void)setCurrentStreamer:(ARAudioStreamer *)currentStreamer
{
    if (_currentStreamer != currentStreamer) {
        _currentStreamer = currentStreamer;
        [self _sendEvent:event_streamer_changed];
    }
}

- (NSTimeInterval)currentTime
{
    return (NSTimeInterval)((NSUInteger)[[self currentStreamer] timingOffset] + [_renderer currentTime]) / 1000.0;
}

- (void)setCurrentTime:(NSTimeInterval)currentTime
{
    NSUInteger milliseconds = (NSUInteger)lrint(currentTime * 1000.0);
    [self _sendEvent:event_seek userData:(void *)(uintptr_t)milliseconds];
}

- (double)volume
{
    return [_renderer volume];
}

- (void)setVolume:(double)volume
{
    [_renderer setVolume:volume];
}

@end
