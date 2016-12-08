//
//  RYOperation.h
//  RYOperation
//
//  Created by ray on 16/11/8.
//  Copyright © 2016年 ray. All rights reserved.
//

#import <Foundation/Foundation.h>

#define RYLog NSLog

typedef NS_ENUM(NSInteger, RYOperationPriority) {
    kRYOperationPriorityVeryLow = -1000,
    kRYOperationPriorityLow = -500,
    kRYOperationPriorityNormal = 0,
    kRYOperationPriorityHigh = 500,
    kRYOperationPriorityVeryHigh = 1000,
};


@class RYQueue;
@interface RYOperation : NSObject

+ (RYOperation *)create;
+ (RYOperation *(^)(dispatch_block_t))createWithBlock;

- (RYOperation *(^)(RYOperation *))addDependency;
- (RYOperation *(^)(RYOperation *))removeDependency;
- (RYOperation *)removeAllDependencies;
- (RYOperation *(^)(dispatch_block_t))setBlock;
- (RYOperation *(^)(NSString *))setName;
- (RYOperation *(^)(RYOperationPriority))setPriority;
- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForOperate; // DISPATCH_TIME_FOREVER
- (RYOperation *(^)(dispatch_time_t))setMinusWaitTimeForOperate; // DISPATCH_TIME_NOW

- (NSSet<RYOperation *> *)allDependencies;

- (void)suspend;
- (void)resume;
- (void)cancel;


- (NSString *)name;
- (BOOL)isCancelled;
- (BOOL)isReady;
- (BOOL)isOperating;
- (BOOL)isFinished;

@end


typedef void (^OperationWillStartBlock)(RYOperation *);

@interface RYQueue : NSObject

+ (RYQueue *)create;
+ (RYQueue *(^)(RYOperation *))createWithOperation;
+ (RYQueue *(^)(NSArray<RYOperation *> *))createWithOperations;

- (RYQueue *(^)(RYOperation *))addOperation;
- (RYQueue *(^)(NSArray<RYOperation *> *))addOperations;
- (RYQueue *(^)(NSInteger ))setIdentifier;
- (RYQueue *(^)(BOOL async /* default: YES */))setAsync;
- (RYQueue *(^)(NSUInteger))setMaxConcurrentOperationCount;
- (RYQueue *(^)(dispatch_block_t))setBeforeExcuteBlock;
- (RYQueue *(^)(dispatch_block_t))setExcuteDoneBlock;
- (RYQueue *(^)(OperationWillStartBlock))setOperationWillStartBlock;
- (RYQueue *(^)())excute;

- (NSSet<RYOperation *> *(^)(NSString *))operationsForName;

- (void)suspend;
- (void)resume;

- (void)cancel;
- (BOOL)isCancelled;

@end

extern dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock);
