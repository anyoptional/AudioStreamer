//
//  ARAudioRenderer.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioRenderer.h"
#import "ARAudioDecoder.h"
#import <AudioUnit/AudioUnit.h>
#import <Accelerate/Accelerate.h>
#import <mach/mach_time.h>
#import <sys/time.h>
#import <pthread.h>

#define kOutputBus 0 // 输出总线，播放
#define kInputBus 1 // 输入总线，录音

@interface ARAudioRenderer ()
@property (nonatomic) pthread_mutex_t mutex;
@property (nonatomic) pthread_cond_t cond;
// typedef AudioComponentInstance AudioUnit;
@property (nonatomic) AudioComponentInstance outputAudioUnit;
@property (nonatomic) uint8_t *buffer;
@property (nonatomic, assign) NSUInteger bufferByteCount;
@property (nonatomic, assign) NSUInteger firstValidByteOffset;
@property (nonatomic, assign) NSUInteger validByteCount;
@property (nonatomic, assign) NSUInteger bufferTime;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) uint64_t startedTime;
@property (nonatomic, assign) uint64_t interruptedTime;
@property (nonatomic, assign) uint64_t totalInterruptedInterval;
@end

@implementation ARAudioRenderer

- (instancetype)init
{
    self = [super init];
    if (self) {
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
        
        _volume = 0.5;
    }
    return self;
}

- (void)dealloc
{
    if (_outputAudioUnit != NULL) {
        [self _cleanup];
    }
    
    if (_buffer != NULL) {
        free(_buffer);
    }
    
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}

#pragma mark  --  properties

- (void)setInterrupted:(BOOL)interrupted
{
    pthread_mutex_lock(&_mutex);
    _interrupted = interrupted;
    pthread_mutex_unlock(&_mutex);
}

- (NSUInteger)currentTime
{
    if (_startedTime == 0) {
        return 0;
    }
    
    double base = [[self class] _absoluteTimeConversion] ;
    
    uint64_t interval;
    if (_interruptedTime == 0) {
        interval = mach_absolute_time() - _startedTime - _totalInterruptedInterval;
    }
    else {
        interval = _interruptedTime - _startedTime - _totalInterruptedInterval;
    }
    
    return base * interval / USEC_PER_SEC;
}

#pragma mark  --  public methods

- (BOOL)prepare
{
    if (_outputAudioUnit != NULL) return YES;

    /** 
     AudioComponentDescription是描述一个AudioComponent的结构体
     
     typedef struct AudioComponentDescription {
        OSType  componentType; 一个音频组件的通用标识
        OSType  componentSubType; 根据componentType设置相应的类型
        OSType  componentManufacturer; 厂商的身份验证
        UInt32  componentFlags; 如果没有一个明确指定的值，那么它必须被设置为0
        UInt32  componentFlagsMask; 如果没有一个明确指定的值，那么它必须被设置为0
     } AudioComponentDescription;
     
     如果是VOIP服务，可描述如下
     AudioComponentDescription desc = {};
     desc.componentType = kAudioUnitType_Output;
     desc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
     desc.componentManufacturer = kAudioUnitManufacturer_Apple;
     desc.componentFlags = 0;
     desc.componentFlagsMask = 0;
     
     对于播放和录制音频，描述如下
     */
    AudioComponentDescription desc = {};
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    /**
     根据提供的描述信息寻找一个可用的AudioComponent
     第一个参数如果为NULL，就会从头开始直到寻找到可用的AudioComponent，如果不为NULL，就会从给定的AudioComponent往后寻找一个可用的
     第二个参数，desc的componentSubType和componentManufacturer标识了寻找AudioComponent的条件，如果是0表示通配。
     */
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    
    /** 
     根据指定的comp初始化一个AudioUnit
     第一个参数不能为NULL，这里也可以看出comp和AudioUnit的关系，个人感觉AudioUnit就像是comp的代理，用它来处理任务
     第二个参数输出AudioUnit对象
     */
    OSStatus status = AudioComponentInstanceNew(comp, &_outputAudioUnit);
    if (status != noErr) {
        _outputAudioUnit = NULL;
        return NO;
    }
    
    /**
     property、scope和element
     property是AudioUnit的属性信息
     scope是AudioUnit编程的上下文对象，不能嵌套
     element嵌套在scope之中，比如element如果是input scope或output scope中的一部分，它类似于物理音频设备中的总线(bus)，表示音频的流向
     总的来说 property有其生效的scope，scope关联着element

     */
    AudioStreamBasicDescription dstFormat = standardLPCMFormat();
    status = AudioUnitSetProperty(_outputAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &dstFormat, sizeof(dstFormat));
    
    // 设置render的回调
    // AURenderCallbackStruct是提供输入的结构体
    // inputProc是录音或播放的回调
    // inputProcRefCon上下文信息
    AURenderCallbackStruct input;
    input.inputProc = mAURenderCallback;
    input.inputProcRefCon = (__bridge void *)self;
    
    status = AudioUnitSetProperty(_outputAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &input, sizeof(input));
    if (status != noErr) {
        AudioComponentInstanceDispose(_outputAudioUnit);
        _outputAudioUnit = NULL;
        return NO;
    }
    
    // 调用AudioUnitInitialize让设置生效
    status = AudioUnitInitialize(_outputAudioUnit);
    if (status != noErr) {
        AudioComponentInstanceDispose(_outputAudioUnit);
        _outputAudioUnit = NULL;
        return NO;
    }
    
    if (_buffer == NULL) {
        _bufferByteCount = defaultBufferSize();
        _firstValidByteOffset = 0;
        _validByteCount = 0;
        // 根据_bufferByteCount初始化缓冲区大小
        _buffer = (uint8_t *)calloc(1, _bufferByteCount);
    }
    
    return YES;
}

- (void)renderBytes:(const void *)bytes length:(NSUInteger)length
{
    if (_outputAudioUnit == NULL) {
        return;
    }
    
    // 将length长的数据全部在AURenderCallBack中消耗掉
    while (length > 0) {
        pthread_mutex_lock(&_mutex);
        
        /**
         AudioOutputUnitStart()之后，在mAURenderCallback会消耗缓冲区的音频数据，也就是
         _validByteCount每次递减消耗掉的数量
         
         _validByteCount是已经填充到缓冲区的量
         emptyByteCount缓冲区剩余的未被填充的量
         */
        NSUInteger emptyByteCount = _bufferByteCount - _validByteCount;
        while (emptyByteCount == 0) {
            if (!_started) {
                if (_interrupted) {
                    pthread_mutex_unlock(&_mutex);
                    return;
                }
                
                pthread_mutex_unlock(&_mutex);
                // 调用start之后，同步进入AURenderCallBack
                AudioOutputUnitStart(_outputAudioUnit);
                pthread_mutex_lock(&_mutex);
                _started = YES;
            }
            
            struct timeval tv;
            struct timespec ts;
            gettimeofday(&tv, NULL);
            ts.tv_sec = tv.tv_sec + 1;
            ts.tv_nsec = 0;
            // 线程等待一秒钟，让出锁给mAURenderCallback执行，回调消耗了_validByteCount也就退了此while循环
            pthread_cond_timedwait(&_cond, &_mutex, &ts);
            emptyByteCount = _bufferByteCount - _validByteCount;
        }
        
        /**
         _firstValidByteOffset：缓冲区长度是_bufferByteCount，_firstValidByteOffset是指从缓冲区哪里开始render，也就是说是缓冲区里还没有被render的音频数据的起始地址（_buffer + _firstValidByteOffset）
         _validByteCount是已经填充到缓冲区但暂未被render的音频数据量
         因此firstEmptyByteOffset是可用于render的音频数据填充数个缓冲区后的剩余量，这个剩余量就是已经填充了缓冲区的部分
         */
        NSUInteger firstEmptyByteOffset = (_firstValidByteOffset + _validByteCount) % _bufferByteCount;
        
        NSUInteger bytesToCopy;
        // 已经填充的量 + 剩余的未被填充的量 > 缓冲区总量
        if (firstEmptyByteOffset + emptyByteCount > _bufferByteCount) {
            // _bufferByteCount - firstEmptyByteOffset剩余的可用于填充的量
            bytesToCopy = MIN(length, _bufferByteCount - firstEmptyByteOffset);
        }
        else {
            bytesToCopy = MIN(length, emptyByteCount);
        }
        
        // 接着已经填充的量继续填充
        memcpy(_buffer + firstEmptyByteOffset, bytes, bytesToCopy);
        
        // 重置一下剩余的音频数据
        length -= bytesToCopy;
        bytes = (const uint8_t *)bytes + bytesToCopy;
        
        // 由此得出_validByteCount是已经memcpy
        _validByteCount += bytesToCopy;
        
        pthread_mutex_unlock(&_mutex);
    }
}

- (void)stop
{
    if (_outputAudioUnit == NULL) {
        return;
    }
    
    pthread_mutex_lock(&_mutex);
    if (_started) {
        pthread_mutex_unlock(&_mutex);
        AudioOutputUnitStop(_outputAudioUnit);
        pthread_mutex_lock(&_mutex);
        
        [self _setShouldInterceptTiming:YES];
        _started = NO;
    }
    pthread_mutex_unlock(&_mutex);
    pthread_cond_signal(&_cond);
}

- (void)flush
{
    [self flushShouldResetTiming:YES];
}

- (void)flushShouldResetTiming:(BOOL)shouldResetTiming
{
    if (_outputAudioUnit == NULL) {
        return;
    }
    
    pthread_mutex_lock(&_mutex);
    
    _firstValidByteOffset = 0;
    _validByteCount = 0;
    if (shouldResetTiming) {
        [self _resetTiming];
    }
    
    pthread_mutex_unlock(&_mutex);
    pthread_cond_signal(&_cond);
}

#pragma mark  --  private methods

- (void)_cleanup
{
    if (_outputAudioUnit == NULL) {
        return;
    }
    
    [self stop];
    [self _cleanupWithoutStop];
}

+ (double)_absoluteTimeConversion
{
    static double conversion;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        conversion = info.numer / info.denom;
    });
    
    return conversion;
}

- (void)_resetTiming
{
    _startedTime = 0;
    _interruptedTime = 0;
    _totalInterruptedInterval = 0;
}

- (void)_cleanupWithoutStop
{
    AudioUnitUninitialize(_outputAudioUnit);
    AudioComponentInstanceDispose(_outputAudioUnit);
    _outputAudioUnit = NULL;
}

- (void)_setShouldInterceptTiming:(BOOL)shouldInterceptTiming
{
    if (_startedTime == 0) {
        // 获取到现在的纳秒数
        _startedTime = mach_absolute_time();
    }
    
    // 连续数据不足时，以第一次暂停的时间点为基准
    if ((_interruptedTime != 0) == shouldInterceptTiming) {
        return;
    }
    
    if (shouldInterceptTiming) {
        // 记录暂停的时间点
        _interruptedTime = mach_absolute_time();
    }
    else {
        // 计算暂停的时间间隔
        _totalInterruptedInterval += mach_absolute_time() - _interruptedTime;
        _interruptedTime = 0;
    }
}

#pragma mark  --  callback

/**
 为AudioUnit提供数据输入的回调
 因为我们render的是解码后的LPCM数据，并且设置在inputScope，bus0
 所以inBusNumber = 0
 ioData代表本次render的数据 ioData->mBuffers[0].mDataByteSize / pcmFormat.mBytesPerFrame = 本次render的音频帧数量 也就是回调中inNumberFrames的值
 inTimeStamp不太清楚
 */
static OSStatus
mAURenderCallback(	void *							inRefCon,
                  AudioUnitRenderActionFlags *	ioActionFlags,
                  const AudioTimeStamp *			inTimeStamp,
                  UInt32							inBusNumber,
                  UInt32							inNumberFrames,
                  AudioBufferList * __nullable	ioData)
{
    // 另外的线程
    ARAudioRenderer *renderer = (__bridge ARAudioRenderer *)inRefCon;
    pthread_mutex_lock(&renderer->_mutex);
    @autoreleasepool {
        // 本次渲染的数据长度
        NSUInteger totalBytesToCopy = ioData->mBuffers[0].mDataByteSize;
        // 可用于渲染的数据长度，memcpy进buffer的量
        NSUInteger validByteCount = renderer->_validByteCount;
        
        // 数据不足
        if (validByteCount < totalBytesToCopy) {
            
            [renderer _setShouldInterceptTiming:YES];
            // 表示缓冲区不需要处理
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
            // 清空缓冲区
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
            pthread_mutex_unlock(&renderer->_mutex);
            return noErr;
        }
        else {
            // 有充足的数据
            [renderer _setShouldInterceptTiming:NO];
        }
        
        // 还没有被render的数据
        Byte *bytes = renderer->_buffer + renderer->_firstValidByteOffset;
        // 本次渲染的数据
        Byte *outBuffer = (uint8_t *)ioData->mBuffers[0].mData;
        NSUInteger outBufSize = ioData->mBuffers[0].mDataByteSize;
        // 需要render的数据量
        NSUInteger bytesToCopy = MIN(outBufSize, validByteCount);
        
        NSUInteger firstFrag = bytesToCopy;
        // 偏移量 + 数据长度 > 缓冲区大小
        if (renderer->_firstValidByteOffset + bytesToCopy > renderer->_bufferByteCount) {
            // first是缓冲区内剩余的所有数据
            firstFrag = renderer->_bufferByteCount - renderer->_firstValidByteOffset;
        }
        
        if (firstFrag < bytesToCopy) {
            // dst   src   length
            // 将缓冲区剩余的数据拷贝进outBuffer
            memcpy(outBuffer, bytes, firstFrag);
            // bytesToCopy - firstFrag 是剩余没有拷贝的数据量
            // 从renderer的buffer里读出剩余的没有拷贝的数据长度接着上一次拷贝的位置继续拷贝
            memcpy(outBuffer + firstFrag, renderer->_buffer, bytesToCopy - firstFrag);
        } else {
            memcpy(outBuffer, bytes, bytesToCopy);
        }
        
        // 傅里叶变换 16表示16位采样位数 另有8位32位 根据dstFormat选择
        if (renderer->_volume != 1.0) {
            int16_t *samples = (int16_t *)outBuffer;
            size_t samplesCount = bytesToCopy / sizeof(int16_t);
            
            float floatSamples[samplesCount];
            vDSP_vflt16(samples, 1, floatSamples, 1, samplesCount);
            
            float volume = renderer->_volume;
            vDSP_vsmul(floatSamples, 1, &volume, floatSamples, 1, samplesCount);
            
            vDSP_vfix16(floatSamples, 1, samples, 1, samplesCount);
        }
        
        if (bytesToCopy < outBufSize) {
            bzero(outBuffer + bytesToCopy, outBufSize - bytesToCopy);
        }
        
        // bytesToCopy是已经render完了的数据长度
        // _validByteCount是手头可用于render的数据长度
        renderer->_validByteCount -= bytesToCopy;
        // _firstValidByteOffset是buffer中的偏移量
        // bytesToCopy是每次渲染的实际数据长度
        renderer->_firstValidByteOffset = (renderer->_firstValidByteOffset + bytesToCopy) % renderer->_bufferByteCount;
    }
    
    pthread_mutex_unlock(&renderer->_mutex);
    pthread_cond_signal(&renderer->_cond);
    
    return noErr;
}


@end
