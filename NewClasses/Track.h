

#import <Foundation/Foundation.h>
#import "ARAudioFile.h"

@interface Track : NSObject <ARAudioFile>

@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSURL *audioURL;

@end
