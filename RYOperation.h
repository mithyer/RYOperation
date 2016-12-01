//
//  RYOperation.h
//  RYOperation
//
//  Created by ray on 16/11/8.
//  Copyright © 2016年 ray. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RYOperationPriority) {
    kRYOperationPriorityVeryLow = -1000,
    kRYOperationPriorityLow = -500,
    kRYOperationPriorityNormal = 0,
    kRYOperationPriorityHigh = 500,
    kRYOperationPriorityVeryHigh = 1000,
};

#define RY_TIME_FOREVER DISPATCH_TIME_FOREVER
#define RY_TIME_NOW DISPATCH_TIME_NOW

@class RYQuene;
@interface RYOperation : NSObject

+ (RYOperation *)create;
+ (RYOperation *(^)(dispatch_block_t))createWithBlock;

- (RYOperation *(^)(RYOperation *))addDependency;
- (RYOperation *(^)(RYOperation *))removeDependency;
- (RYOperation *)removeAllDependencies;
- (RYOperation *(^)(dispatch_block_t))setBlock;
- (RYOperation *(^)(NSString *))setName;
- (RYOperation *(^)(RYOperationPriority))setPriority;
- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForExcute; // default:RY_TIME_FOREVER
- (RYOperation *(^)(dispatch_time_t))setMinusWaitTimeForExucte; // default:RY_TIME_NOW

- (NSSet<RYOperation *> *)allDependencies;
- (void)cancel;

- (NSString *)name;
- (BOOL)isCancelled;
- (BOOL)isReady;
- (BOOL)isExcuting;
- (BOOL)isFinished;

@end


typedef void (^OperationWillStartBlock)(RYOperation *);

@interface RYQuene : NSObject

+ (RYQuene *)create;
+ (RYQuene *(^)(RYOperation *))createWithOperation;
+ (RYQuene *(^)(NSArray<RYOperation *> *))createWithOperations;

- (RYQuene *(^)(RYOperation *))addOperation;
- (RYQuene *(^)(NSArray<RYOperation *> *))addOperations;
- (RYQuene *(^)(NSInteger ))setIdentifier;
- (RYQuene *(^)(BOOL async /* default: YES */))setAsync;
- (RYQuene *(^)(NSUInteger))setMaxConcurrentOperationCount;
- (RYQuene *(^)(dispatch_block_t))setBeforeExcuteBlock;
- (RYQuene *(^)(dispatch_block_t))setExcuteDoneBlock;
- (RYQuene *(^)(OperationWillStartBlock))setOperationWillStartBlock;
- (RYQuene *(^)())excute;

- (NSSet<RYOperation *> *(^)(NSString *))operationsForName;
- (void)cancel;

- (BOOL)isCancelled;

@end

extern dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock);
