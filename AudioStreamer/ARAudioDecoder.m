//
//  ARAudioDecoder.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioDecoder.h"
#import "ARAudioLPCM.h"
#import "ARAudioProvider.h"
#import "ARAudioFileInfo.h"
#import <AudioToolbox/AudioFile.h>
#import <AudioToolbox/AudioConverter.h>
#import <pthread.h>

@interface ARAudioFileInfo ()
@property (nonatomic, strong) ARAudioProvider *fileProvider;
@property (nonatomic) AudioFileID audioFileID;
@end

///=====================================================================
///     标准LPCM格式
///=====================================================================
AudioStreamBasicDescription standardLPCMFormat (void)
{
    static AudioStreamBasicDescription dstFormat;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 标识音频格式
        dstFormat.mFormatID = kAudioFormatLinearPCM;
        // 依据mFormatID而定
        dstFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        // 采样率
        dstFormat.mSampleRate = 44100;
        // 采样位数，对于压缩音频，此值为0
        dstFormat.mBitsPerChannel = 16;
        // 每帧的通道数
        dstFormat.mChannelsPerFrame = 2;
        // 每帧的数据量
        dstFormat.mBytesPerFrame = dstFormat.mChannelsPerFrame * (dstFormat.mBitsPerChannel / 8);
        // 每个数据包的帧数，对于无损格式，一包一帧，对于压缩格式，一包多帧
        dstFormat.mFramesPerPacket = 1;
        // 每个数据包的数据量 = 每个数据包的帧数 * 每帧的数据量
        dstFormat.mBytesPerPacket = dstFormat.mFramesPerPacket * dstFormat.mBytesPerFrame;
    });
    
    return dstFormat;
}

///=====================================================================
///     200ms内的数据量
///=====================================================================
UInt32 defaultBufferSize(void)
{
    // 单位时间内的数据量 = 时间（秒数） * 采样率 * 声道数 * 采样位数 / 8(bit-->byte)
    NSUInteger milliseconds = 200;
    AudioStreamBasicDescription lpcmFormat = standardLPCMFormat();
    return milliseconds * lpcmFormat.mSampleRate * lpcmFormat.mChannelsPerFrame * lpcmFormat.mBitsPerChannel / 8 / 1000;
}

///=====================================================================
///     源数据处理信息
///=====================================================================
typedef struct {
    // 源AudioFileID
    AudioFileID                  srcFileID;
    // 当前解码的位置
    SInt64                       srcFilePos;
    // 缓冲区
    char *                       srcBuffer;
    // 缓冲区大小
    UInt32                       srcBufferSize;
    // 源音频格式
    AudioStreamBasicDescription     srcFormat;
    // 源音频中每个数据包的大小（以字节计）
    UInt32                       srcSizePerPacket;
    // 在给定的bufferSize下能读取的数据包数
    UInt32                       numPacketsPerRead;
    // VBR音频的布局描述信息
    AudioStreamPacketDescription *packetDescriptions;
} AudioFileIO, *AudioFileIORef;

///=====================================================================
///     解码上下文信息
///=====================================================================
typedef struct {
    // 源输入格式
    AudioStreamBasicDescription  srcFormat;
    // 目的输出格式
    AudioStreamBasicDescription  dstFormat;
    
    AudioFileIO                  afio;
    // 输出音频的描述信息
    AudioStreamPacketDescription *outputPacketDescriptions;
    // 输出的缓冲区大小
    UInt32                       outputBufferSize;
    // 输出的缓冲区
    void                         *outputBuffer;
    // 输出的数据包数
    UInt32                       numOutputPackets;
    
    pthread_mutex_t              mutex;
} AudioCodecContext;

@interface ARAudioDecoder ()
@property (nonatomic, strong) ARAudioFileInfo *fileInfo;
@property (nonatomic, strong) ARAudioLPCM *lpcm;

@property (nonatomic) AudioConverterRef audioConverter;
// 缓冲区大小
@property (nonatomic, assign) NSUInteger bufferSize;

@property (nonatomic, assign) AudioCodecContext decodingCtx;
@property (nonatomic, assign) BOOL decodingCtxInitialized;
@end

@implementation ARAudioDecoder

+ (instancetype)decoderWithAudioFileInfo:(ARAudioFileInfo *)fileInfo
{
    return [[self alloc] initWithAudioFileInfo:fileInfo];
}

- (instancetype)initWithAudioFileInfo:(ARAudioFileInfo *)fileInfo
{
    self = [super init];
    if (self) {
        _fileInfo = fileInfo;
        _lpcm = [ARAudioLPCM new];
        _bufferSize = (NSUInteger)defaultBufferSize();

        if (![self _createAudioConverter]) return nil;
    }
    return self;
}

- (void)dealloc
{
    [self _cleanup];
}

#pragma mark  --  public methods

- (BOOL)prepare
{
    if (_decodingCtxInitialized) return YES;
    
    // 获取一下AudioFileID
    if (![_fileInfo isAvailable]) return NO;
    AudioFileID srcFileID = [_fileInfo audioFileID];
    
    // 赋值源输入格式和目的输出格式
    _decodingCtx.srcFormat = [_fileInfo highFormat];
    _decodingCtx.dstFormat = standardLPCMFormat();

    // 填充magic cookie
    [self _fillMagicCookie];
    
    // 获取完整的音频流格式描述信息
    if (![self _fillCompleteFormat]) return NO;
    
    // 基本格式
    AudioStreamBasicDescription baseFormat = [_fileInfo baseFormat];
    
    double high2baseSampleRateRatio = 1.0;
    if (_decodingCtx.srcFormat.mSampleRate != baseFormat.mSampleRate &&
        _decodingCtx.srcFormat.mSampleRate != 0.0 &&
        baseFormat.mSampleRate != 0.0) {
        high2baseSampleRateRatio = _decodingCtx.srcFormat.mSampleRate / baseFormat.mSampleRate;
    }
    
    double high2baseChannelCountRatio = 1.0;
    if (_decodingCtx.srcFormat.mChannelsPerFrame != baseFormat.mChannelsPerFrame &&
        _decodingCtx.srcFormat.mChannelsPerFrame != 0.0 &&
        baseFormat.mChannelsPerFrame != 0.0) {
        high2baseChannelCountRatio = _decodingCtx.srcFormat.mChannelsPerFrame / baseFormat.mChannelsPerFrame;
    }
    
    /**
     对于压缩音频数据，它的数据并不全是有效可播放的,AudioFilePacketTableInfo描述了这一情况
     比如对AAC文件，它有100个数据包，每个数据包包含1024个音频帧，那么它有100 * 1024 = 102400帧的数据。
     在这些数据中，前面的2112个音频帧可能填充的是启动信息，它不是可播放的音频数据
     同时为了对齐（最后一个数据包凑齐1024帧），它可能会填充一些无效帧到结尾处
     
     对于无损音频，因为它是一包一帧，所以整个音频文件都是可播放的音频包，也就存在启动信息和填充帧了
     
     这些信息都是相对于基准格式得出来的，而解码播放时我们肯定希望采用最高规格的音频流描述信息。对于分层的音频格式（ARAudioFileInfo的两个属性highFormat和baseFormat描述了音频文件的基准格式和最高规格格式）。
     
     我们知道，数据速率 = 采样率 * 声道数 * 采样位数 / 8
     一个采样率为44.1KHz，采样位数为16bit/s，双声道的PCM编码的音频文件，它的数据速率则为 44.1K * 16 * 2=1411.2 kbps。 将码率除以8（进制转换，1Byte=8Bit），就可以得到数据速率，即176.4KB/s。
     在采样位数相同的情况下，采样率 * 声道数 的大小就决定了数据速率的大小，时间再相同的话，就决定了音频文件大小，音频文件大小就决定了音频帧的数量。
     我们在解码的时候，不管是什么格式的音频，它的采样位数一定是不变的，它的时长也是不会变的，所以
     高规格下采样率 * 声道数对基准格式的比率，再乘以启动帧数量，就是高规格下需要填充的启动帧数量，尾部填充帧也一样。
     
     
     kAudioConverterPrimeInfo同样描述了这一情况，所以我们获取到AudioFilePacketTableInfo，算好需要填充的数量，初始化好kAudioConverterPrimeInfo再设置给AudioConverter就可以了
     
     struct AudioFilePacketTableInfo
     {
        // 音频文件可播放的帧数
        SInt64  mNumberValidFrames;
        // 音频文件开头的无效帧数
        SInt32  mPrimingFrames;
        // 音频文件结尾的无效帧数
        SInt32  mRemainderFrames;
     };
     typedef struct AudioFilePacketTableInfo AudioFilePacketTableInfo;
     */
    AudioFilePacketTableInfo srcPti = {};
    UInt32 size = 0;
    OSStatus status = noErr;
    // mBitsPerChannel == 0,说明是压缩音频
    // 启动信息只对压缩音频有效
    if (_decodingCtx.srcFormat.mBitsPerChannel == 0) {
        // 获取PacketTableInfo
        size = sizeof(srcPti);
        status = AudioFileGetProperty(srcFileID, kAudioFilePropertyPacketTableInfo, &size, &srcPti);
        if (status == noErr) {
            // 先确保可写
            UInt32 dataSize = 0;
            Boolean isWritable = NO;
            status = AudioConverterGetPropertyInfo(_audioConverter, kAudioConverterPrimeInfo, &dataSize, &isWritable);
            if (status == noErr && isWritable) {
                // 设置AudioConverter启动信息
                // 填充启动信息，可以获得可高质量的输出
                AudioConverterPrimeInfo primeInfo;
                primeInfo.leadingFrames = (UInt32)(srcPti.mPrimingFrames * high2baseSampleRateRatio * high2baseChannelCountRatio);
                primeInfo.trailingFrames = (UInt32)srcPti.mRemainderFrames * high2baseSampleRateRatio * high2baseChannelCountRatio;
                status = AudioConverterSetProperty(_audioConverter, kAudioConverterPrimeInfo, sizeof(primeInfo), &primeInfo);
                if (status != noErr) {
                    return NO;
                }
            }
        }
    }
    
    // 赋值AudioFileIO
    _decodingCtx.afio.srcFilePos = 0;
    _decodingCtx.afio.srcFileID = srcFileID;
    _decodingCtx.afio.srcFormat = _decodingCtx.srcFormat;
    _decodingCtx.afio.srcBufferSize = (UInt32)_bufferSize;
    _decodingCtx.afio.srcBuffer = malloc(_decodingCtx.afio.srcBufferSize * sizeof(char));
    if (_decodingCtx.afio.srcBuffer == NULL) return NO;
    
    // mBytesPerPacket == 0，说明源音频是VBR编码
    if (_decodingCtx.srcFormat.mBytesPerPacket == 0) {
        /**
         VBR因为是动态码率，所以每个数据包的大小是不定的
         
         使用kAudioFilePropertyPacketSizeUpperBound返回音频文件理论上的最大数据包大小
        （并没有实际扫描整个文件找到最大的数据包，也可以用kAudioFilePropertyMaximumPacketSize，不过流播时是不可能扫描完所有数据包的），
         只要按照最大的包大小来分配内存，就可以hold住音频文件中的所有包了
         */

        size = sizeof(_decodingCtx.afio.srcSizePerPacket);
        status = AudioFileGetProperty(srcFileID, kAudioFilePropertyPacketSizeUpperBound, &size, &_decodingCtx.afio.srcSizePerPacket);
        if (status != noErr) {
            free(_decodingCtx.afio.srcBuffer);
            return NO;
        }
        
        // 此时srcSizePerPacket已经是最大包的大小了，以它最为包大小的基准就可以hold住所有包了
        // 计算在我们设定的bufferSize下能读取的数据包数
        _decodingCtx.afio.numPacketsPerRead = _decodingCtx.afio.srcBufferSize / _decodingCtx.afio.srcSizePerPacket;
        // 为描述每个数据包布局的PacketDescription结构分配内存。
        _decodingCtx.afio.packetDescriptions = malloc(_decodingCtx.afio.numPacketsPerRead * sizeof(AudioStreamPacketDescription));
        if (_decodingCtx.afio.packetDescriptions == NULL) {
            free(_decodingCtx.afio.srcBuffer);
            return NO;
        }
    }else{
        // 处理CBR编码的情况
        _decodingCtx.afio.srcSizePerPacket = _decodingCtx.srcFormat.mBytesPerPacket;
        _decodingCtx.afio.numPacketsPerRead = _decodingCtx.afio.srcBufferSize / _decodingCtx.afio.srcSizePerPacket;
        // CBR是固定的，不需要此描述信息
        _decodingCtx.afio.packetDescriptions = NULL;
    }
    
    // 设置输出的缓冲区
    _decodingCtx.outputBufferSize = (UInt32)_bufferSize;
    _decodingCtx.outputBuffer = malloc(_decodingCtx.outputBufferSize * sizeof(char));
    if (_decodingCtx.outputBuffer == NULL) {
        free(_decodingCtx.afio.srcBuffer);
        return NO;
    }
    
    _decodingCtx.outputPacketDescriptions = NULL;
    // 如果outputSizePerPacket == 0，说明转化的目的格式是VBR编码格式，而我们转化的目标是LPCM
    // 对PCM来说，一包一帧，也就是说不用处理outputSizePerPacket == 0的情况
    UInt32 outputSizePerPacket = _decodingCtx.dstFormat.mBytesPerPacket;
    // 在给定的bufferSize下能输出的数据包数
    _decodingCtx.numOutputPackets = _decodingCtx.outputBufferSize / outputSizePerPacket;
    
    pthread_mutex_init(&_decodingCtx.mutex, NULL);
    _decodingCtxInitialized = YES;
    
    return YES;
}

- (AudioDecodingStatus)decodeOnce
{
    if (!_decodingCtxInitialized) return AudioDecodingFailed;
    
    pthread_mutex_lock(&_decodingCtx.mutex);
    // 如果下载或者从ipod中导出音频失败，就不必继续解码了
    ARAudioProvider *fileProvider = [_fileInfo fileProvider];
    if ([fileProvider isFailed]) {
        [_lpcm setEnd:YES];
        pthread_mutex_unlock(&_decodingCtx.mutex);
        return AudioDecodingFailed;
    }
    
    // 如果还在下载
    if (![fileProvider isFinished]) {
        // 音频头信息长度
        NSUInteger dataOffset = [_fileInfo dataOffset];
        // 音频总长度
        NSUInteger expectedDataLength = [fileProvider expectedLength];
        // 已接收的数据总量减去头信息是真正可播放的音频数据
        NSInteger receivedDataLength  = (NSInteger)([fileProvider receivedLength] - dataOffset);
        
        // 上次读取到的数据包的位置加上本次读取的数据包数，是接下来理论上总共读取的数据包数
        SInt64 packetNumber = _decodingCtx.afio.srcFilePos + _decodingCtx.afio.numPacketsPerRead;
        // 理论上总共读取的数据总量
        SInt64 packetBytesOffset = packetNumber * _decodingCtx.afio.srcSizePerPacket;
        
        // 每个数据包的数据量(理论上的最大量)
        SInt64 bytesPerPacket = _decodingCtx.afio.srcSizePerPacket;
        // 理论上每次读取的数据量
        SInt64 bytesPerRead = bytesPerPacket * _decodingCtx.afio.numPacketsPerRead;
        
        // 源格式中每个数据包的帧数
        SInt64 framesPerPacket = _decodingCtx.srcFormat.mFramesPerPacket;
        
        // 每帧持续时间(毫秒) = 每数据包的帧数 / 采样频率 * 1000
        // 例如对MP3 每帧持续时间(毫秒) = 1152 / 44100 * 1000 约等于 26.2ms
        double intervalPerPacket = 1000.0 / _decodingCtx.srcFormat.mSampleRate * framesPerPacket;
        // 目前为止这么多字节的持续时间
        double intervalPerRead = intervalPerPacket / bytesPerPacket * bytesPerRead;
        
        // receivedDataLength - packetBytesOffset 接收的数据总量减去理论上已经读取的数据总量,得到剩余量
        // bytesPerRead - (receivedDataLength - packetBytesOffset) 本次需要读取的量减去剩余量
        // 比如，receivedDataLength = 1000bit，packetBytesOffset = 2000bit，它们的差值是个空缺，是需要下载的，目前并没有。
        //
        // 所以downloadTime是计算出到目前为止
        double downloadTime = 1000.0 * (bytesPerRead - (receivedDataLength - packetBytesOffset)) / [fileProvider downloadSpeed];
        SInt64 bytesRemaining = (SInt64)(expectedDataLength - (NSUInteger)receivedDataLength);
        
        if (receivedDataLength < packetBytesOffset ||
            (bytesRemaining > 0 &&
             downloadTime > intervalPerRead)) {
                pthread_mutex_unlock(&_decodingCtx.mutex);
                return AudioDecodingWaiting;
            }
    }
    
    // 设置输出的buffer list
    AudioBufferList fillBufferList = {};
    // 一个buffer
    fillBufferList.mNumberBuffers = 1;
    // 双双声道
    fillBufferList.mBuffers[0].mNumberChannels = _decodingCtx.dstFormat.mChannelsPerFrame;
    // 200ms数据量
    fillBufferList.mBuffers[0].mDataByteSize = _decodingCtx.outputBufferSize;
    //
    fillBufferList.mBuffers[0].mData = _decodingCtx.outputBuffer;
    
    // 开始解码
    UInt32 ioOutputDataPackets = _decodingCtx.numOutputPackets;
    /**
     第一个参数，是使用的AudioConverter
     第二个参数，mAudioConverterComplexInputDataProc是一个提供输入数据的回调函数
     第三个参数，上下文对象
     第四个参数，ioOutputDataPackets是一个输入输出参数，输入时，表示输出的数据包数量，它的大小应该能容纳输出数据的大小，输出时，表示已经转换好的数据包数
     第四个参数，fillBufferList，转换好的数据会写入此缓冲区
     第五个参数，outputPacketDescriptions，VBR格式需要，如果有的话会写入这里，大小应该能容纳ioOutputDataPackets个AudioStreamPacketDescription
     */
    OSStatus status = AudioConverterFillComplexBuffer(_audioConverter, mAudioConverterComplexInputDataProc, &_decodingCtx.afio, &ioOutputDataPackets, &fillBufferList, _decodingCtx.outputPacketDescriptions);
    if (status != noErr) {
        pthread_mutex_unlock(&_decodingCtx.mutex);
        return AudioDecodingFailed;
    }
    
    // EOF
    if (ioOutputDataPackets == 0) {
        [_lpcm setEnd:YES];
        pthread_mutex_unlock(&_decodingCtx.mutex);
        return AudioDecodingEndEncountered;
    }
    
    
    UInt32 inNumBytes = fillBufferList.mBuffers[0].mDataByteSize;
    [_lpcm writeBytes:_decodingCtx.outputBuffer length:inNumBytes];
    
    pthread_mutex_unlock(&_decodingCtx.mutex);
    return AudioDecodingSucceeded;
}

-(void)seekToTime:(NSUInteger)milliseconds
{
    if (!_decodingCtxInitialized) return;
    
    pthread_mutex_lock(&_decodingCtx.mutex);
    // packetDuration = framesPerPacket / sampleRate * 1000，也就是说单个包的持续时间(毫秒) = 单个包的帧数 / 采样频率 * 1000
    // 根据公式，frames就是milliseconds时间内的音频帧数
    double frames = (double)milliseconds * _decodingCtx.srcFormat.mSampleRate / 1000.0;
    // 再获取对应的数据包位置
    double packets = frames / _decodingCtx.srcFormat.mFramesPerPacket;
    // double floor( double arg ) 向下取整，取不大于arg的最大整数
    SInt64 packetNumebr = (SInt64)floor(packets);
    // 用户seek的是时间，编码时seek的是数据包的位置
    _decodingCtx.afio.srcFilePos = packetNumebr;
    
    pthread_mutex_unlock(&_decodingCtx.mutex);
}

#pragma mark  --  private methods

- (BOOL)_createAudioConverter
{
    // 获取源输入格式和目的输出格式
    AudioStreamBasicDescription srcFormat = [_fileInfo highFormat];
    AudioStreamBasicDescription dstFormat = standardLPCMFormat();
    
    OSStatus status = AudioConverterNew(&srcFormat, &dstFormat, &_audioConverter);
    if (status != noErr) {
        _audioConverter = NULL;
    }
    
    return status == noErr;
}

- (void)_fillMagicCookie
{
    /** 
     有的音频会有magic cookie附加在音频数据上
     magic cookie可以提供一些解码细节，从而帮助AudioConverter正确解码
     如果有的话就获取出来设置给AudioConverter    
     */
    if ([_fileInfo magicCookie]) {
        NSData *magicCookie = [_fileInfo magicCookie];
        AudioConverterSetProperty(_audioConverter, kAudioConverterDecompressionMagicCookie, (UInt32)[magicCookie length], [magicCookie bytes]);
    }
}

- (BOOL)_fillCompleteFormat
{
    // 从AudioConverter获取源输入格式和目的输出格式的完整格式
    // 比如在解码AAC时，原始的srcFormat可能并没有被完全填写（见ARAudioFileInfo.m）
    UInt32 size = sizeof(_decodingCtx.srcFormat);
    OSStatus status = AudioConverterGetProperty(_audioConverter, kAudioConverterCurrentInputStreamDescription, &size, &_decodingCtx.srcFormat);
    if (status != noErr) return NO;
    
    size = sizeof(_decodingCtx.dstFormat);
    status = AudioConverterGetProperty(_audioConverter, kAudioConverterCurrentOutputStreamDescription, &size, &_decodingCtx.dstFormat);
    if (status != noErr) return NO;
    
    return YES;
}

- (void)_cleanup
{
    if (!_decodingCtxInitialized) return;
    
    free(_decodingCtx.afio.srcBuffer);
    free(_decodingCtx.outputBuffer);
    
    if (_decodingCtx.afio.packetDescriptions != NULL) {
        free(_decodingCtx.afio.packetDescriptions);
    }
    
    if (_decodingCtx.outputPacketDescriptions != NULL) {
        free(_decodingCtx.outputPacketDescriptions);
    }
    
    pthread_mutex_destroy(&_decodingCtx.mutex);
    _decodingCtxInitialized = NO;
    
    if (_audioConverter != NULL) {
        AudioConverterDispose(_audioConverter);
    }
}

#pragma mark  --  callback

static OSStatus mAudioConverterComplexInputDataProc(
                                                    AudioConverterRef inAudioConverter,
                                                    UInt32 *            ioNumberDataPackets,
                                                    AudioBufferList *               ioData,
                                                    AudioStreamPacketDescription * __nullable * __nullable outDataPacketDescription,
                                                    void * __nullable               inUserData)
{
    AudioFileIORef afio = (AudioFileIORef)inUserData;
    
    // 理论上读取的数据包数
    if (*ioNumberDataPackets > afio->numPacketsPerRead) *ioNumberDataPackets = afio->numPacketsPerRead;
    
    // 理论上读取的数据量
    UInt32 outNumBytes = afio->numPacketsPerRead * afio->srcSizePerPacket;
    
    /**
     第一个参数是AudioFileID
     第二个参数表示是否需要缓存
     第三个参数，outNumBytes在输入时表示afio->arcBuffer的大小，输出时表示实际读取了多少数据
     第四个参数，数据包布局信息数据，在传递之前就必须分配足够的内存，大小必须能保存ioNumberDataPackets个AudioStreamPacketDescription（ioNumberDataPackets * sizeof(AudioStreamPacketDescription)）
     第五个参数，afio->srcFilePos是从第几个数据包开始读取
     第六个参数，ioNumberDataPackets在输入时表示需要读取多少个帧，在输出时表示实际读取了多少帧。
     第七个参数，afio->srcBuffer在传递之前就必须分配好足够内存。对于AudioFileReadPacketData()来说只要分配近似包大小 * 包数的内存空间即可，方法本身会针对给定的内存空间大小来决定最后输出多少个包，如果空间不够会适当减少出的数据包数
     
     这个方法读取后的音频数据就进行了数据包分离，AudioConverter可以直接使用来解码
     */
    OSStatus status = AudioFileReadPacketData(afio->srcFileID, false, &outNumBytes, afio->packetDescriptions, afio->srcFilePos, ioNumberDataPackets, afio->srcBuffer);
    if (status == kAudioFileEndOfFileError) status = noErr;
    if (status != noErr) return status;
    
    // 确认输入数据包的位置
    afio->srcFilePos += *ioNumberDataPackets;
    
    // 填充数据进缓冲区
    ioData->mBuffers[0].mData = afio->srcBuffer;
    ioData->mBuffers[0].mDataByteSize = outNumBytes;
    ioData->mBuffers[0].mNumberChannels = afio->srcFormat.mChannelsPerFrame;
    
    // don't forget the packet descriptions if required
    if (outDataPacketDescription) {
        if (afio->packetDescriptions) {
            *outDataPacketDescription = afio->packetDescriptions;
        } else {
            *outDataPacketDescription = NULL;
        }
    }
    
    return status;
}

@end
