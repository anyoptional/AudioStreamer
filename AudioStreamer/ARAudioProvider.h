//
//  ARAudioProvider.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ARAudioFile.h"

NS_ASSUME_NONNULL_BEGIN
typedef void (^ARAudioProviderEventBlock)(void);
///=====================================================================
///     这个类封装了播放流程中的第一步 ---> 读取音频数据
/// ARAudioProvider 作为虚拟基类，提供对外接口，从而屏蔽了几种不同来源的音频
/// iOS端可用的音频来源一般来说有三种：
///     1、本地音频，存在于NSBundle或应用程序沙盒中
///     2、iPod音频，可通过AVAssetExportSession导出
///     3、远程音乐，在远程服务器上
///=====================================================================
@interface ARAudioProvider : NSObject

@property (nonatomic, readonly, strong) id<ARAudioFile> audioFile;
@property (nullable, nonatomic, copy) ARAudioProviderEventBlock eventBlock;
// 缓存路径
@property (nonatomic, readonly, copy) NSString *cachedPath;
// 音频长度
@property (nonatomic, readonly, assign) NSUInteger expectedLength;
// 已接收的长度
@property (nonatomic, readonly, assign) NSUInteger receivedLength;
// 通过 <sys/mman.h> 调用 mmap() 返回的映射数据
@property (nonatomic, readonly, strong) NSData *mappedData;
// 下载速度
@property (nonatomic, readonly) NSUInteger downloadSpeed;
// 下载是否失败
@property (nonatomic, readonly, getter=isFailed) BOOL failed;
// 音频信息是否完整的标志
@property (nonatomic, readonly, getter=isReady) BOOL ready;
// 是否读取完所有音频数据
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
// 扩展名，如mp3
@property (nullable, nonatomic, readonly, copy) NSString *fileExtension;
/**
 与文件扩展名有关，用于确定文件的类型。
 在HTTP请求中，mimeType通过 Content-Type 表示。
 iOS中可通过 <MobileCoreServices/UTType.h> 中定义的相关方法可以实现 fileExtension <--> UTType <--> mimeType 的互转
 的互转。
 我们获取 fileExtension 和 mimeType，是为了保证AudioFileStream 和 AudioFile 的正确初始
 化（指定正确的AudioFileTypeID）
 */
@property (nullable, nonatomic, readonly, copy) NSString *mimeType;

+ (nullable instancetype)providerWithAudioFile:(id<ARAudioFile>)audioFile;

@end
NS_ASSUME_NONNULL_END
