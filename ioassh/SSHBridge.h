#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SSHStartCompletion)(NSInteger localPort, NSString *_Nullable errorMessage);

@interface SSHBridge : NSObject

+ (instancetype)sharedBridge;
+ (NSString *)libraryVersion;

- (NSDictionary<NSString *, id> *)savedConfiguration;
- (NSString *)savedPassword;
- (void)saveHost:(NSString *)host
         sshPort:(NSInteger)sshPort
        username:(NSString *)username
        password:(NSString *)password
     servicePort:(NSInteger)servicePort;

- (void)startWithHost:(NSString *)host
              sshPort:(NSInteger)sshPort
             username:(NSString *)username
             password:(NSString *)password
          servicePort:(NSInteger)servicePort
           completion:(SSHStartCompletion)completion;
- (void)stop;
- (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END
