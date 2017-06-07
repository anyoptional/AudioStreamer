//
//  ARAudioDownloader.h
//  AudioKit
//
//  Created by Archer on 2017/5/16.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^ARAudioDownloaderDidReceiveResponseBlock)(void);
typedef void (^ARAudioDownloaderDidReceiveDataBlock)(NSData *data);
typedef void (^ARAudioDownloaderProgressBlock)(double downloadProgress);
typedef void (^ARAudioDownloaderCompletedBlock)(void);

@interface ARAudioDownloader : NSObject

/** 超时时间 */
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
/** 返回的数据 */
@property (nonatomic, readonly) NSData *responseData;
/** 返回数据 data -->  string */
@property (nonatomic, readonly) NSString *responseString;
/** 返回的http请求头 */
@property (nonatomic, readonly) NSDictionary *responseHeaders;
/** 文件大小 */
@property (nonatomic, readonly) NSUInteger responseContentLength;
/** http状态码 */
@property (nonatomic, readonly) NSInteger statusCode;
/** http状态信息 */
@property (nonatomic, readonly) NSString *statusMessage;
/** 下载速度 */
@property (nonatomic, readonly) NSUInteger downloadSpeed;
/** 下载是否失败 */
@property (nonatomic, readonly, getter=isFailed) BOOL failed;


+ (instancetype)loaderWithAudioURL:(NSURL *)audioURL;

/** 在CFReadStream有数据返回时调用 */
- (void)updateDidReceiveResponseBlock:(ARAudioDownloaderDidReceiveResponseBlock)didReceiveResponseBlock;
/** 接收到数据返回时调用 */
- (void)updateDidRecievedDataBlock:(ARAudioDownloaderDidReceiveDataBlock)didReceiveDataBlock;
/** 更新下载速度 */
- (void)updateProgressBlock:(ARAudioDownloaderProgressBlock)progressBlock;
/** 下载结束 */
- (void)updateCompletedBlock:(ARAudioDownloaderCompletedBlock)completedBlock;

/** 开始请求 */
- (void)start;
/** 取消请求 */
- (void)cancel;

@end
