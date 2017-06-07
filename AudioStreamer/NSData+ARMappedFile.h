//
//  NSData+ARMappedFile.h
//  AudioKit
//
//  Created by Archer on 2017/5/16.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface NSData (ARMappedFile)

+ (NSData *)yo_dataWithMappedContentsOfFile:(NSString *)path;

+ (NSData *)yo_modifiableDataWithMappedContentsOfFile:(NSString *)path;

// 同步磁盘和内存中的数据
- (void)yo_synchronizeMappedFile;

@end
NS_ASSUME_NONNULL_END
