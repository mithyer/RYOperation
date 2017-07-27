//
//  RYOperation.m
//  RYOperation
//
//  Created by ray on 16/11/8.
//  Copyright © 2016年 ray. All rights reserved.
//

#import "RYOperation.h"
#import <objc/runtime.h>

#define DISPATCH_QUENE_LABEL(ID) [NSString stringWithFormat:@"queue_label: %@, line:%d, id:%@",[[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, ID].UTF8String
#define CREATE_DISPATCH_SERIAL_QUEUE(ID) dispatch_queue_create(DISPATCH_QUENE_LABEL(ID), DISPATCH_QUEUE_SERIAL)
#define CREATE_DISPATCH_CONCURRENT_QUEUE(ID) dispatch_queue_create(DISPATCH_QUENE_LABEL(ID), DISPATCH_QUEUE_CONCURRENT)


#pragma mark - C function

NS_INLINE dispatch_queue_t ry_lock_get_lock_queue(id holder, const void *key, BOOL createIfNotExist) {
    static dispatch_once_t once_t;
    static dispatch_semaphore_t lock;
    dispatch_once(&once_t, ^{
        lock = dispatch_semaphore_create(1);
    });
    
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    
    static void *holder_lock_key = &holder_lock_key;
    dispatch_semaphore_t holder_lock = objc_getAssociatedObject(holder, holder_lock_key);
    if (nil == holder_lock) {
        holder_lock = dispatch_semaphore_create(1);
        objc_setAssociatedObject(holder, holder_lock_key, holder_lock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    dispatch_semaphore_signal(lock);
    
    
    dispatch_semaphore_wait(holder_lock, DISPATCH_TIME_FOREVER);
    
    static void *seriral_queue_map_key = &seriral_queue_map_key;
    NSMapTable<NSValue *, dispatch_queue_t> *serial_queue_map = objc_getAssociatedObject(holder, seriral_queue_map_key);
    if (nil == serial_queue_map) {
        serial_queue_map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory];
        objc_setAssociatedObject(holder ,seriral_queue_map_key, serial_queue_map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    NSValue *valueKey = [NSValue valueWithPointer:key];
    dispatch_queue_t serial_queue = [serial_queue_map objectForKey:valueKey];
    if (nil == serial_queue && createIfNotExist) {
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", holder, valueKey];
        serial_queue = CREATE_DISPATCH_SERIAL_QUEUE(identifier);
        [serial_queue_map setObject:serial_queue forKey:valueKey];
    }
    
    dispatch_semaphore_signal(holder_lock);
    
    return serial_queue;
}


dispatch_queue_t ry_lock(id holder, const void *lock_key, BOOL async, qos_class_t qos_class, void (^lockedBlock)(id holder)) {
    if (NULL == lock_key || nil == holder || nil == lockedBlock) {
        return nil;
    }
    dispatch_queue_t queue = ry_lock_get_lock_queue(holder, lock_key, YES);
    __weak typeof(holder) wHolder = holder;
    if (nil != lockedBlock) {
        dispatch_block_t block = dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS, qos_class, 0, ^{
            __strong typeof(wHolder) sHoloder = wHolder;
            if (nil != sHoloder) {
                lockedBlock(sHoloder);
            }
        });
        (async ? dispatch_async : dispatch_sync)(queue, block);
    }
    return queue;
}

dispatch_queue_t ry_operation_lock(RYOperation *operation, const void *lock_key, BOOL async, void (^lockedBlock)(RYOperation *operation)) {
    if (nil == lockedBlock) {
        return nil;
    }
    return ry_lock(operation, lock_key, async, (qos_class_t)operation.qos, lockedBlock);
}

dispatch_queue_t ry_queue_lock(RYQueue *queue, const void *lock_key, BOOL async, void (^lockedBlock)(RYQueue *queue)) {
    if (nil == lockedBlock) {
        return nil;
    }
    return ry_lock(queue, lock_key, async, (qos_class_t)queue.qos, lockedBlock);
}

#pragma mark - RYOperationRelation

@class RYOperationRelation;
@interface RYOperation (Relation)

@property (nonatomic, strong) NSMutableSet<RYOperationRelation *> *relationSet;

@end

@interface RYOperationRelation : NSObject

@property (nonatomic, weak) RYOperation *opt;
@property (nonatomic, weak) RYOperation *subOpt;

@end

@implementation RYOperationRelation

- (NSUInteger)hash {
    return _opt.hash ^ _subOpt.hash;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:RYOperationRelation.class]) {
        return NO;
    }
    RYOperationRelation *relation = (RYOperationRelation *)object;
    return relation.opt == self.opt && relation.subOpt == self.subOpt;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%p, %p>", self.opt, self.subOpt];
}

@end

dispatch_semaphore_t semaphoreForTwoOpetaions(RYOperation *opt, RYOperation *subOpt) {
    static dispatch_once_t onceToken;
    static NSMapTable<RYOperationRelation *, dispatch_semaphore_t> *table = nil;
    dispatch_once(&onceToken, ^{
        table = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPersonality valueOptions:NSPointerFunctionsStrongMemory];
    });
    static const void *kLockKey = &kLockKey;
    __block dispatch_semaphore_t semph = nil;
    ry_lock(RYOperationRelation.class, kLockKey, NO, (qos_class_t)opt.qos, ^(id holder) {
        RYOperationRelation *relation = [[RYOperationRelation alloc] init];
        relation.opt = opt;
        relation.subOpt = subOpt;
        semph = [table objectForKey:relation];
        if (nil == semph) {
            semph = dispatch_semaphore_create(0);
            [table setObject:semph forKey:relation];
            [opt.relationSet addObject:relation];
            [subOpt.relationSet addObject:relation];
        }
    });
    return semph;
}


#pragma mark - RYOperation

@interface RYOperation ()

@property (nonatomic, strong) NSHashTable<RYOperation *> *superOperations;
@property (nonatomic, strong) NSMutableSet<RYOperation *> *subOperations;

@end


@implementation RYOperation {
    @private

    RYOperationPriority _priority;
    
    dispatch_queue_t _suspended_queue;
    __weak dispatch_semaphore_t _min_wait_semaphore;
    RYOperationState _state;
    
    @package
    __weak RYQueue *_queue;
    dispatch_block_t _operationBlock;
    dispatch_block_t _operationOverBlock;
    NSMutableSet *_relationSet;
}

- (instancetype)init {
    if (self = [super init]) {
        _maximumWaitTimeForOperate = DISPATCH_TIME_FOREVER;
        _minimumWaitTimeForOperate = DISPATCH_TIME_NOW;
        _superOperations = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _subOperations = NSMutableSet.set;
        _relationSet = NSMutableSet.set;
    }
    return self;
}

- (NSMutableSet<RYOperationRelation *> *)relationSet {
    return _relationSet;
}

+ (instancetype)operationWithBlock:(dispatch_block_t)block {
    RYOperation *opt = [[self alloc] init];
    opt->_operationBlock = block;
    return opt;
}

- (void)setState:(RYOperationState)state {
    _state = state;
}

#ifdef RYO_DEPENDENCY_CYCLE_CHECK_ON

NS_INLINE bool seekCycle(RYOperation *operation, RYOperation *subOperation) {
    if (operation == subOperation) {
        return true;
    }
    for (RYOperation *superOpt in operation.superOperations) {
        if (superOpt == subOperation) {
            return true;
        } else {
            seekCycle(superOpt, subOperation);
        }
    }
    return false;
}

#endif

- (void)addDependency:(RYOperation *)opt {
    if (![opt isKindOfClass:RYOperation.class]) {
        return;
    }
    ry_operation_lock(self, @selector(addDependency:), NO, ^(id holder) {
        RYOperation *sSelf = holder;
#ifdef RYO_DEPENDENCY_CYCLE_CHECK_ON
        NSCParameterAssert(!seekCycle(sSelf, opt));
#endif
        [sSelf.subOperations addObject:opt];
        [opt.superOperations addObject:sSelf];
    });
}

- (void)removeDependency:(RYOperation *)opt {
    if (![opt isKindOfClass:RYOperation.class]) {
        return;
    }
    ry_operation_lock(self, @selector(addDependency:), NO, ^(id holder) {
        RYOperation *sSelf = holder;
        [sSelf.subOperations removeObject:opt];
        [opt.superOperations removeObject:sSelf];
    });
}

- (void)removeAllDependencies {
    ry_operation_lock(self, @selector(addDependency:), NO, ^(id holder) {
        RYOperation *sSelf = holder;
        [sSelf.subOperations enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
            [opt.superOperations removeObject:sSelf];
        }];
        [sSelf.subOperations removeAllObjects];
    });
}

- (void)operate {
    static const void *kMainOperateKey = &kMainOperateKey;
    ry_operation_lock(self, kMainOperateKey, YES, ^(id holder) {
        RYOperation *sSelf = holder;
        __block RYOperationState state;
        ry_operation_lock(sSelf, @selector(state), NO, ^(id holder) {
            RYOperation *sSelf = holder;
            state = sSelf->_state;
            if (state == kRYOperationStateNotBegin) {
                sSelf.state = kRYOperationStateOperating;
            }
        });
        if (state == kRYOperationStateOperating) {
            return;
        }
        if (state == kRYOperationStateCancelled) {
            sSelf->_operationOverBlock();
            if (nil != sSelf->_operationDoneBlock) {
                sSelf->_operationDoneBlock();
            }
            [sSelf.superOperations.allObjects enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, NSUInteger idx, BOOL * _Nonnull stop) {
                dispatch_semaphore_signal(semaphoreForTwoOpetaions(opt, sSelf));
            }];
            return;
        }
        __block BOOL shouldReturn = NO;
        ry_operation_lock(sSelf, @selector(operate), NO, ^(id holder){
            __block BOOL cancelld = NO;
            ry_operation_lock(sSelf, @selector(state), NO, ^(id holder) {
                RYOperation *sSelf = holder;
                cancelld = sSelf->_state == kRYOperationStateCancelled;
            });
            if (cancelld) {
                sSelf->_operationOverBlock();
                if (nil != sSelf->_operationDoneBlock) {
                    sSelf->_operationDoneBlock();
                }
                [sSelf.superOperations.allObjects enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, NSUInteger idx, BOOL * _Nonnull stop) {
                    dispatch_semaphore_signal(semaphoreForTwoOpetaions(opt, sSelf));
                }];
                shouldReturn = YES;
                return;
            }
            RYOperation *sSelf = holder;
            dispatch_semaphore_t min_wait_semaphore = dispatch_semaphore_create(0);
            sSelf->_min_wait_semaphore = min_wait_semaphore;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sSelf.minimumWaitTimeForOperate)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                dispatch_semaphore_signal(min_wait_semaphore);
            });
            __block NSSet<RYOperation *> *subOperations = nil;
            ry_operation_lock(sSelf, @selector(addDependency:), NO, ^(id holder) {
                RYOperation *sSelf = holder;
                subOperations = [sSelf->_subOperations copy];
            });
            [subOperations enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                dispatch_semaphore_wait(semaphoreForTwoOpetaions(sSelf, opt), sSelf.maximumWaitTimeForOperate);
            }];
            dispatch_semaphore_wait(min_wait_semaphore, DISPATCH_TIME_FOREVER);
        });
        ry_operation_lock(sSelf, @selector(operate), NO, ^(id holder){
            if (shouldReturn) {
                return;
            }
            RYOperation *sSelf = holder;
            __block BOOL cancelld = NO;
            ry_operation_lock(sSelf, @selector(state), NO, ^(id holder) {
                RYOperation *sSelf = holder;
                cancelld = sSelf->_state == kRYOperationStateCancelled;
            });
            if (!cancelld) {
                if (nil != sSelf->_operationBlock) {
                    sSelf->_operationBlock();
                }
                ry_operation_lock(sSelf, @selector(state), NO, ^(id holder) {
                    ry_operation_lock(sSelf, @selector(suspend), YES, ^(id holder) {
                        RYOperation *sSelf = holder;
                        if (nil != sSelf->_suspended_queue) {
                            dispatch_resume(sSelf->_suspended_queue);
                            sSelf->_suspended_queue = nil;
                        }
                    });
                    RYOperation *sSelf = holder;
                    sSelf.state = kRYOperationStateFinished;
                });
            }
            sSelf->_operationOverBlock();
            if (nil != sSelf->_operationDoneBlock) {
                sSelf->_operationDoneBlock();
            }
            [sSelf.superOperations.allObjects enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, NSUInteger idx, BOOL * _Nonnull stop) {
                dispatch_semaphore_signal(semaphoreForTwoOpetaions(opt, sSelf));
            }];
        });
    });
}

- (void)cancel {
    ry_operation_lock(self, @selector(state), NO, ^(id holder) {
        RYOperation *sSelf = holder;
        if (sSelf->_state == kRYOperationStateCancelled || sSelf->_state == kRYOperationStateFinished) {
            return;
        }
        ry_operation_lock(self, @selector(suspend), NO, ^(id holder){
            if (nil != sSelf->_suspended_queue) {
                dispatch_resume(sSelf->_suspended_queue);
                sSelf->_suspended_queue = nil;
            }
            sSelf.state = kRYOperationStateCancelled;
        });
    });
}

- (void)suspend {
    ry_operation_lock(self, @selector(state), NO, ^(id holder) {
        RYOperation *sSelf = holder;
        if ((sSelf->_state | kRYOperationStateOperating) != kRYOperationStateOperating) {
            return;
        }
        ry_operation_lock(self, @selector(suspend), NO, ^(id holder){
            if (nil != sSelf->_suspended_queue) {
                return;
            }
            RYOperation *sSelf = holder;
            dispatch_queue_t queue = ry_lock_get_lock_queue(sSelf, @selector(operate), YES);
            dispatch_suspend(queue);
            sSelf->_suspended_queue = queue;
            sSelf.state |= kRYOperationStateSuspended;
        });
    });
}

- (void)resume {
    ry_operation_lock(self, @selector(state), NO, ^(id holder) {
        RYOperation *sSelf = holder;
        if ((sSelf->_state & kRYOperationStateSuspended) != kRYOperationStateSuspended) {
            return;
        }
        ry_operation_lock(self, @selector(suspend), NO, ^(id holder){
            RYOperation *sSelf = holder;
            if (nil == sSelf->_suspended_queue) {
                return;
            }
            dispatch_resume(sSelf->_suspended_queue);
            sSelf->_suspended_queue = nil;
            sSelf.state &= ~kRYOperationStateSuspended;
        });
    });
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p %@>", self.class, self, _name];
}

@end


#pragma mark - RYQueue

@implementation RYQueue {
    @protected
    BOOL _sync;
    NSMutableSet<RYOperation *> *_operationSet;
}

+ (instancetype)queue {
    return [[self alloc] init];
}

- (instancetype)init {
    if (self = [super init]) {
        _operationSet = [NSMutableSet set];
    }
    return self;
}

- (void)setAsync:(BOOL)async {
    _sync = !async;
}

- (void)setStatus:(RYQueueStatus)status {
    _status = status;
}

- (void)addOperation:(RYOperation *)opt {
    if (![opt isKindOfClass:RYOperation.class]) {
        return;
    }
    ry_queue_lock(self, @selector(addOperation:), NO, ^(id holder) {
        RYQueue *sSelf = holder;
        opt->_queue = sSelf;
        [sSelf->_operationSet addObject:opt];
    });
}

- (void)removeOperation:(RYOperation *)opt {
    ry_queue_lock(self, @selector(addOperation:), NO, ^(id holder) {
        RYQueue *sSelf = holder;
        opt->_queue = nil;
        [sSelf->_operationSet removeObject:opt];
    });
}

- (NSSet<RYOperation *> *)allOperations {
    __block NSSet<RYOperation *> *operations = nil;
    ry_queue_lock(self, @selector(addOperation:), NO, ^(id holder){
        RYQueue *sSelf = holder;
        operations = [sSelf->_operationSet copy];
    });
    return operations;
}

- (NSUInteger)maximumConcurrentOperationCount {
    if (_maximumConcurrentOperationCount < 1) {
        _maximumConcurrentOperationCount = 12;
    }
    return _maximumConcurrentOperationCount;
}

- (void)excute {
    
    ry_queue_lock(self, @selector(excute), !_sync, ^(id holder){
        RYQueue *sSelf = holder;
        
        __block BOOL shouldReturn = NO;
        ry_queue_lock(sSelf, @selector(status), NO, ^(id holder) {
            RYQueue *sSelf = holder;
            shouldReturn = sSelf->_status != kRYQueueStatusNotBegin;
            if (sSelf->_status == kRYQueueStatusNotBegin) {
                sSelf.status = kRYQueueStatusExcuting;
            }
        });
        if (shouldReturn) {
            return;
        }
        dispatch_semaphore_t operate_done_semp = dispatch_semaphore_create(0);
        
        __block NSArray<RYOperation *> *operationArray = nil;
        ry_queue_lock(self, @selector(addOperation:), NO, ^(id holder) {
            operationArray = [sSelf->_operationSet.allObjects sortedArrayUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:NSStringFromSelector(@selector(priority)) ascending:NO]]];
        });
        
        dispatch_semaphore_t excute_max_operation_count_semp = dispatch_semaphore_create(sSelf.maximumConcurrentOperationCount);
        dispatch_queue_t operateQueue = CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf.description);
        
        [operationArray enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, NSUInteger idx, BOOL * _Nonnull stop) {
            opt->_operationOverBlock = ^{
                dispatch_semaphore_signal(operate_done_semp);
            };
            dispatch_block_t optBlock = opt->_operationBlock;
            opt->_operationBlock = ^{
                dispatch_semaphore_wait(excute_max_operation_count_semp, DISPATCH_TIME_FOREVER);
                dispatch_sync(operateQueue, optBlock);
                dispatch_semaphore_signal(excute_max_operation_count_semp);
            };
            [opt operate];
        }];

        [operationArray enumerateObjectsUsingBlock:^(RYOperation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_semaphore_wait(operate_done_semp, DISPATCH_TIME_FOREVER);
        }];
        
        ry_queue_lock(sSelf, @selector(status), NO, ^(id holder) {
            RYQueue *sSelf = holder;
            sSelf.status = kRYQueueStatusDone;
        });
        
        if (sSelf->_excutionDoneBlock) {
            sSelf->_excutionDoneBlock(sSelf);
        }
    });
}


- (void)cancelAllOperation {
    ry_queue_lock(self, @selector(status), NO, ^(id holder){
        RYQueue *sSelf = holder;
        if (sSelf->_status == kRYQueueStatusDone) {
            return;
        }
        __block NSSet<RYOperation *> *operationSet = nil;
        ry_queue_lock(sSelf, @selector(addOperation:), NO, ^(id holder) {
            RYQueue *sSelf = holder;
            operationSet = [sSelf->_operationSet copy];
        });
        if (operationSet.count > 0) {
            [operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                [opt cancel];
            }];
        }
    });
}

- (void)suspendAllOperation {
    ry_queue_lock(self, @selector(status), NO, ^(id holder) {
        RYQueue *sSelf = holder;
        if (sSelf->_status == kRYQueueStatusDone) {
            return;
        }
        __block NSSet<RYOperation *> *operationSet = nil;
        ry_queue_lock(sSelf, @selector(addOperation:), NO, ^(id holder) {
            RYQueue *sSelf = holder;
            operationSet = [sSelf->_operationSet copy];
        });
        if (operationSet.count > 0) {
            [operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                [opt suspend];
            }];
        }
    });
}

- (void)resumeAllOperation {
    ry_queue_lock(self, @selector(status), NO, ^(id holder) {
        RYQueue *sSelf = holder;
        if (sSelf->_status == kRYQueueStatusDone) {
            return;
        }
        __block NSSet<RYOperation *> *operationSet = nil;
        ry_queue_lock(sSelf, @selector(addOperation:), NO, ^(id holder) {
            RYQueue *sSelf = holder;
            operationSet = [sSelf->_operationSet copy];
        });
        if (operationSet.count > 0) {
            [operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                [opt resume];
            }];
        }
    });
}


@end



