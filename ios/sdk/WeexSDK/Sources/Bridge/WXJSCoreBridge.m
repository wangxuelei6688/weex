/**
 * Created by Weex.
 * Copyright (c) 2016, Alibaba, Inc. All rights reserved.
 *
 * This source code is licensed under the Apache Licence 2.0.
 * For the full copyright and license information,please view the LICENSE file in the root directory of this source tree.
 */

#import "WXJSCoreBridge.h"
#import "WXDefine.h"
#import "WXAssert.h"
#import "WXLog.h"
#import "WXDefine.h"
#import "WXUtility.h"
#import "WXSDKEngine.h"
#import "WXSDKError.h"
#import "WXMonitor.h"
#import "WXAppMonitorProtocol.h"
#import "WXHandlerFactory.h"
#import <sys/utsname.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import "WXPolyfillSet.h"

@interface WXJSCoreBridge ()

@property (nonatomic, strong)  JSContext *jsContext;

@end

@implementation WXJSCoreBridge

- (instancetype)init
{
    self = [super init];
    
    if(self){
        _jsContext = [[JSContext alloc] init];
        if (WX_SYS_VERSION_GREATER_THAN_OR_EQUAL_TO(@"8.0")) {
            _jsContext.name = @"Weex Context";
        }
        
        __weak typeof(self) weakSelf = self;
        
        NSDictionary *data = [WXUtility getEnvironment];
        _jsContext[@"WXEnvironment"] = data;
        
        _jsContext[@"setTimeout"] = ^(JSValue *function, JSValue *timeout) {
            // this setTimeout is used by internal logic in JS framework, normal setTimeout called by users will call WXTimerModule's method;
            [weakSelf performSelector: @selector(triggerTimeout:) withObject:^() {
                [function callWithArguments:@[]];
            } afterDelay:[timeout toDouble] / 1000];
        };
        
        _jsContext[@"nativeLog"] = ^() {
            static NSDictionary *levelMap;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                levelMap = @{
                             @"__ERROR": @(WXLogFlagError),
                             @"__WARN": @(WXLogFlagWarning),
                             @"__INFO": @(WXLogFlagInfo),
                             @"__DEBUG": @(WXLogFlagDebug),
                             @"__LOG": @(WXLogFlagLog)
                             };
            });
            NSMutableString *string = [NSMutableString string];
            [string appendString:@"jsLog: "];
            NSArray *args = [JSContext currentArguments];
            
            [args enumerateObjectsUsingBlock:^(JSValue *jsVal, NSUInteger idx, BOOL *stop) {
                if (idx == args.count - 1) {
                    NSNumber *flag = levelMap[[jsVal toString]];
                    if (flag) {
                        if ([flag isEqualToNumber:[NSNumber numberWithInteger:WXLogFlagWarning]]) {
                            id<WXAppMonitorProtocol> appMonitorHandler = [WXHandlerFactory handlerForProtocol:@protocol(WXAppMonitorProtocol)];
                            if ([appMonitorHandler respondsToSelector:@selector(commitAppMonitorAlarm:monitorPoint:success:errorCode:errorMsg:arg:)]) {
                                [appMonitorHandler commitAppMonitorAlarm:@"weex" monitorPoint:@"jswarning" success:FALSE errorCode:@"99999" errorMsg:string arg:[WXSDKEngine topInstance].pageName];
                            }
                        }
                        WX_LOG([flag unsignedIntegerValue], @"%@", string);
                    } else {
                        [string appendFormat:@"%@ ", jsVal];
                        WXLogInfo(@"%@", string);
                    }
                }
                [string appendFormat:@"%@ ", jsVal ];
            }];
        };
        
        _jsContext.exceptionHandler = ^(JSContext *context, JSValue *exception){
            context.exception = exception;
            NSString *message = [NSString stringWithFormat:@"[%@:%@:%@] %@\n%@", exception[@"sourceURL"], exception[@"line"], exception[@"column"], exception, [exception[@"stack"] toObject]];
            
            WX_MONITOR_FAIL(WXMTJSBridge, WX_ERR_JS_EXECUTE, message);
        };
        
        if (WX_SYS_VERSION_LESS_THAN(@"8.0")) {
            // solve iOS7 memory problem
            _jsContext[@"nativeSet"] = [WXPolyfillSet class];
        }
    }
    return self;
}

#pragma mark - WXBridgeProtocol

- (void)executeJSFramework:(NSString *)frameworkScript
{
    WXAssertParam(frameworkScript);
    if (WX_SYS_VERSION_GREATER_THAN_OR_EQUAL_TO(@"8.0")) {
        [_jsContext evaluateScript:frameworkScript withSourceURL:[NSURL URLWithString:@"main.js"]];
    }else{
        [_jsContext evaluateScript:frameworkScript];
    }
}

- (JSValue *)callJSMethod:(NSString *)method args:(NSArray *)args
{
    WXLogDebug(@"Calling JS... method:%@, args:%@", method, args);
    return [[_jsContext globalObject] invokeMethod:method withArguments:args];
}

- (void)registerCallNative:(WXJSCallNative)callNative
{
    NSInteger (^callNativeBlock)(JSValue *, JSValue *, JSValue *) = ^(JSValue *instance, JSValue *tasks, JSValue *callback){
        NSString *instanceId = [instance toString];
        NSArray *tasksArray = [tasks toArray];
        NSString *callbackId = [callback toString];
        
        WXLogDebug(@"Calling native... instance:%@, tasks:%@, callback:%@", instanceId, tasksArray, callbackId);
        return callNative(instanceId, tasksArray, callbackId);
    };
    
    _jsContext[@"callNative"] = callNativeBlock;
}

- (void)registerCallAddElement:(WXJSCallAddElement)callAddElement
{
    id callAddElementBlock = ^(JSValue *instanceId, JSValue *ref, JSValue *element, JSValue *index, JSValue *ifCallback) {
        
        // Temporary here , in order to improve performance, will be refactored next version.
        WXLogDebug(@"callAddElement...%@, %@, %@, %@", instanceId, ref, element, index);
        NSString *instanceIdString = [instanceId toString];
        NSDictionary *componentData = [element toDictionary];
        NSString *parentRef = [ref toString];
        NSInteger insertIndex = [[index toNumber] integerValue];
        
        return callAddElement(instanceIdString, parentRef, componentData, insertIndex);
    };

    _jsContext[@"callAddElement"] = callAddElementBlock;
}

- (JSValue*)exception
{
    return _jsContext.exception;
}

- (void)resetEnvironment
{
    NSDictionary *data = [WXUtility getEnvironment];
    _jsContext[@"WXEnvironment"] = data;
}

JS_EXPORT void JSSynchronousGarbageCollectForDebugging(JSContextRef ctx);

- (void)garbageCollect
{
    JSSynchronousGarbageCollectForDebugging(_jsContext.JSGlobalContextRef);
}

#pragma mark - Private

- (void)triggerTimeout:(void(^)())block
{
    block();
}

@end
