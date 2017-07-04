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

typedef NS_ENUM(NSInteger, RYOperationQos) {
    kRYOperationQosUnspecified = QOS_CLASS_UNSPECIFIED,
    kRYOperationQosBackground = QOS_CLASS_BACKGROUND,
    kRYOperationQosUtility = QOS_CLASS_UTILITY,
    kRYOperationQosDefault = QOS_CLASS_DEFAULT,
    kRYOperationQosUserInitiated = QOS_CLASS_USER_INITIATED,
    kRYOperationQosInteractive = QOS_CLASS_USER_INTERACTIVE
};

extern dispatch_queue_t ry_lock(id holder, const void *lock_key, BOOL async, qos_class_t qos_class, void (^lockedBlock)(id holder));

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
@property (nonatomic, assign) RYOperationQos qos;
@property (nonatomic, assign) RYOperationPriority priority; // in one queue, higher priority opertaion will be started earlier
@property (nonatomic, assign) dispatch_time_t maximumWaitTimeForOperate;
@property (nonatomic, assign) dispatch_time_t minimumWaitTimeForOperate;
@property (nonatomic, strong, readonly) NSSet<RYOperation *> *allDependencies;
@property (nonatomic, assign, readonly) RYOperationState state;
@property (nonatomic, copy) dispatch_block_t operationDoneBlock; // the state should be kRYOperationStateFinished or kRYOperationStateCancelled

@end


typedef NS_ENUM(NSUInteger, RYQueueStatus) {
    kRYQueueStatusNotBegin = 0,
    kRYQueueStatusExcuting = 1,
    kRYQueueStatusDone = 2 // excuted done
};

@interface RYQueue : NSObject

+ (instancetype)queue;
- (void)addOperation:(RYOperation *)opt;
- (void)removeOperation:(RYOperation *)opt;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) RYOperationQos qos;
@property (nonatomic, assign) BOOL async;
@property (nonatomic, assign) NSUInteger maximumConcurrentOperationCount;
@property (nonatomic, copy) void (^excutionDoneBlock)(RYQueue *queue); // called when all operation has done
@property (nonatomic, assign, readonly) RYQueueStatus status;

- (NSSet<RYOperation *> *)allOperations;

- (void)excute;
- (void)suspendAllOperation;
- (void)resumeAllOperation;
- (void)cancelAllOperation;

@end

