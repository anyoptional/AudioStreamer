//
//  ARAudioFile.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
///=====================================================================
///     遵守此协议并实现协议方法以提供音频文件路径
///=====================================================================
@protocol ARAudioFile <NSObject>

@required
///===========================
/// @property audioURL 音频地址
///===========================
@property (nonatomic, strong) NSURL *audioURL;

@end
NS_ASSUME_NONNULL_END
