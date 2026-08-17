#import "SSHBridge.h"

#import <Security/Security.h>

#include <libssh/libssh.h>
#include "SSHTunnel.hpp"

namespace {

NSString *const SSHHostKey = @"ssh.host";
NSString *const SSHPortKey = @"ssh.port";
NSString *const SSHUsernameKey = @"ssh.username";
NSString *const ServicePortKey = @"service.port";
NSString *const PasswordAccount = @"ssh.password";

NSDictionary *passwordQuery(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NSBundle.mainBundle.bundleIdentifier ?: @"ioassh",
        (__bridge id)kSecAttrAccount: PasswordAccount,
    };
}

std::string utf8(NSString *value) {
    const char *characters = value.UTF8String;
    return characters == nullptr ? std::string() : std::string(characters);
}

} // namespace

@interface SSHBridge ()
@property(nonatomic) void *tunnelStorage;
@property(nonatomic) dispatch_queue_t tunnelQueue;
@end

@implementation SSHBridge

+ (instancetype)sharedBridge {
    static SSHBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bridge = [[SSHBridge alloc] init];
    });
    return bridge;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _tunnelStorage = new SSHTunnel();
        _tunnelQueue = dispatch_queue_create("wang.yln.ioassh.tunnel", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    delete static_cast<SSHTunnel *>(_tunnelStorage);
}

+ (NSString *)libraryVersion {
    const char *version = ssh_version(0);
    return version == nullptr ? @"unknown" : [NSString stringWithUTF8String:version];
}

- (NSDictionary<NSString *, id> *)savedConfiguration {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return @{
        @"host": [defaults stringForKey:SSHHostKey] ?: @"",
        @"sshPort": @([defaults integerForKey:SSHPortKey] ?: 22),
        @"username": [defaults stringForKey:SSHUsernameKey] ?: @"",
        @"servicePort": @([defaults integerForKey:ServicePortKey] ?: 8188),
    };
}

- (NSString *)savedPassword {
    NSMutableDictionary *query = [passwordQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == nullptr) {
        return @"";
    }
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)saveHost:(NSString *)host
         sshPort:(NSInteger)sshPort
        username:(NSString *)username
        password:(NSString *)password
     servicePort:(NSInteger)servicePort {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:host forKey:SSHHostKey];
    [defaults setInteger:sshPort forKey:SSHPortKey];
    [defaults setObject:username forKey:SSHUsernameKey];
    [defaults setInteger:servicePort forKey:ServicePortKey];

    NSDictionary *query = passwordQuery();
    NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = data;
        SecItemAdd((__bridge CFDictionaryRef)item, nullptr);
    }
}

- (void)startWithHost:(NSString *)host
              sshPort:(NSInteger)sshPort
             username:(NSString *)username
             password:(NSString *)password
          servicePort:(NSInteger)servicePort
           completion:(SSHStartCompletion)completion {
    [self saveHost:host
           sshPort:sshPort
          username:username
          password:password
       servicePort:servicePort];

    SSHTunnel::Configuration configuration;
    configuration.host = utf8(host);
    configuration.username = utf8(username);
    configuration.password = utf8(password);
    configuration.sshPort = static_cast<uint16_t>(sshPort);
    configuration.servicePort = static_cast<uint16_t>(servicePort);

    SSHTunnel *tunnel = static_cast<SSHTunnel *>(self.tunnelStorage);
    dispatch_async(self.tunnelQueue, ^{
        uint16_t localPort = 0;
        std::string error;
        bool success = tunnel->start(std::move(configuration), localPort, error);
        NSString *message = success ? nil : [NSString stringWithUTF8String:error.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success ? localPort : 0, message ?: @"SSH 隧道启动失败");
        });
    });
}

- (void)stop {
    SSHTunnel *tunnel = static_cast<SSHTunnel *>(self.tunnelStorage);
    dispatch_async(self.tunnelQueue, ^{
        tunnel->stop();
    });
}

- (BOOL)isRunning {
    return static_cast<SSHTunnel *>(self.tunnelStorage)->isRunning();
}

@end
