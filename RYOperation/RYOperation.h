//
//  RYOperation.h
//  RYOperation
//
//  Created by ray on 16/11/8.
//  Copyright © 2016年 ray. All rights reserved.
//

#import <Foundation/Foundation.h>

#define RYO_DEPENDENCY_CYCLE_CHECK_ON

typedef NS_ENUM(NSInteger, RYOperationPriority) {
    kRYOperationPriorityVeryLow = -1000,
    kRYOperationPriorityLow = -500,
    kRYOperationPriorityNormal = 0,
    kRYOperationPriorityHigh = 500,
    kRYOperationPriorityVeryHigh = 1000,
};

typedef void (^RYLockedBlock)(id holder);
extern dispatch_queue_t ry_lock(id holder, const void *lock_key, BOOL async, RYLockedBlock lockedBlock);

@class RYQueue;

typedef NS_OPTIONS(NSUInteger, RYOperationState) {
    kRYOperationStateNotBegin = 0,
    kRYOperationStateOperating = 1,
    kRYOperationStateSuspended = 1 << 1,
    kRYOperationStateCancelled = 1 << 2,
    kRYOperationStateFinished = 1 << 3,
    
    kRYOperationStateSuspendedWhenNotBegin= kRYOperationStateSuspended,
    kRYOperationStateSuspendedWhenOperating = kRYOperationStateOperating | kRYOperationStateSuspended
};


@interface RYOperation : NSObject

+ (instancetype)operationWithBlock:(dispatch_block_t)block;

- (void)addDependency:(RYOperation *)opt;
- (void)removeDependency:(RYOperation *)opt;
- (void)removeAllDependencies;

- (void)suspend;
- (void)resume;
- (void)cancel;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) RYOperationPriority priority;
@property (nonatomic, assign) dispatch_time_t maximumWaitTimeForOperate;
@property (nonatomic, assign) dispatch_time_t minimumWaitTimeForOperate;
@property (nonatomic, strong, readonly) NSSet<RYOperation *> *allDependencies;
@property (nonatomic, assign, readonly) RYOperationState state;
@property (nonatomic, copy) dispatch_block_t operationFinishedBlock;

@end


typedef NS_OPTIONS(NSUInteger, RYQueueStatus) {
    kRYQueueStatusNotBegin = 0,
    kRYQueueStatusExcuting = 1,
    kRYQueueStatusDone = 2 // all operation has finished all cancelled
};

typedef void (^QueueBlock)(RYQueue *queue);

@interface RYQueue : NSObject

+ (instancetype)queue;
- (void)addOperation:(RYOperation *)opt;
- (void)removeOperation:(RYOperation *)opt;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL async;
@property (nonatomic, assign) NSUInteger maximumConcurrentOperationCount;
@property (nonatomic, copy) QueueBlock excuteDoneBlock;
@property (nonatomic, assign, readonly) RYQueueStatus status;

- (NSSet<RYOperation *> *)allOperations;

- (void)excute;
- (void)suspendAllOperation;
- (void)resumeAllOperation;
- (void)cancelAllOperation;

@end

