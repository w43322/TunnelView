#import "SSHBridge.h"

#include <libssh/libssh.h>

@implementation SSHBridge

+ (NSString *)libraryVersion {
    const char *version = ssh_version(0);
    return version == nullptr ? @"unknown" : [NSString stringWithUTF8String:version];
}

@end
