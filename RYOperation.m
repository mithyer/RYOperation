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

#define RYO_DEPENDENCY_CYCLE_CHECK_ON

enum {
    kOperationRelationLock = 1000,
    kOperationCancelLock,
    kOperationSuspendLock,
    kOperationOperateLock,
    kOperationMinWaitTimeLock,
    kOperationMaxWaitTimeLock,
    kQueueAddOperationLock,
    kQueueExcuteLock,
    kQueueSuspendLock,
    kCancelAllOperationsLock,
    kSetMaxConcurrentOperationCountLock,
};

enum {
    kOperationRelationLockSuspendedQueue,
    kOperationOperateLockSuspendedQueue,
    
    OperationSuspendedQueueCount
};

dispatch_queue_t ry_lock_get_lock_queue(id holder, NSUInteger lockId, BOOL createIfNotExist) {
    static dispatch_once_t once_t;
    static dispatch_semaphore_t add_holder_semp_semp;
    dispatch_once(&once_t, ^{
        add_holder_semp_semp = dispatch_semaphore_create(1);
    });
    
    dispatch_semaphore_wait(add_holder_semp_semp, DISPATCH_TIME_FOREVER);
    
    static void *holder_semp_key = &holder_semp_key;
    dispatch_semaphore_t holder_semp = objc_getAssociatedObject(holder, holder_semp_key);
    if (nil == holder_semp) {
        holder_semp = dispatch_semaphore_create(1);
        objc_setAssociatedObject(holder_semp, holder_semp_key, holder_semp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    dispatch_semaphore_signal(add_holder_semp_semp);
    
    
    dispatch_semaphore_wait(holder_semp, DISPATCH_TIME_FOREVER);
    
    static void *seriral_queue_map_key = &seriral_queue_map_key;
    NSMapTable<NSNumber *, dispatch_queue_t> *serial_queue_map = objc_getAssociatedObject(holder, seriral_queue_map_key);
    if (nil == serial_queue_map) {
        serial_queue_map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory];
        objc_setAssociatedObject(holder ,seriral_queue_map_key, serial_queue_map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    dispatch_queue_t serial_queue = [serial_queue_map objectForKey:@(lockId)];
    if (nil == serial_queue && createIfNotExist) {
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", holder, @(lockId)];
        serial_queue = CREATE_DISPATCH_SERIAL_QUEUE(identifier);
        [serial_queue_map setObject:serial_queue forKey:@(lockId)];
    }
    
    dispatch_semaphore_signal(holder_semp);
    
    return serial_queue;
}

dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock) {
    if (!holder) {
        holder = NSObject.class;
    }
    dispatch_queue_t queue = ry_lock_get_lock_queue(holder, lockId, YES);
    __weak typeof(holder) wHolder = holder;
    if (nil != lockedBlock) {
        (async ? dispatch_async : dispatch_sync)(queue, ^{
            if (nil != wHolder) {
                @autoreleasepool {
                    lockedBlock();
                }
            }
        });
    }
    
    return queue;
}


@interface RYDependencyRelation : NSObject

@property (nonatomic, weak) RYOperation *demander;
@property (nonatomic, weak) RYOperation *relier;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;

@end

@implementation RYDependencyRelation

- (NSUInteger)hash {
    return ((NSUInteger)self.demander) ^ ((NSUInteger)self.relier);
}

- (BOOL)isEqual:(id)object {
    if ([object class] == [self class]) {
        RYDependencyRelation *relation = object;
        return relation.demander == self.demander && relation.relier == self.relier;
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %p -> demander:%@, relier:%@, semaphore:%@", self.class, self, _demander, _relier, _semaphore];
}

@end


@implementation RYOperation {
    @private
    void (^_operationBlock)();

    NSMutableSet<RYDependencyRelation *> *_relation_set;
    
    NSString* _name;
    RYOperationPriority _priority;
    
    dispatch_time_t _maxWaitTimeForOperate;
    dispatch_time_t _minWaitTimeForOperate;
    dispatch_queue_t _suspended_queue[OperationSuspendedQueueCount];
    
    BOOL _isCancelled;
    BOOL _isReady;
    
    @public
    __weak RYQueue *_queue;
    dispatch_block_t _operateDoneBlock;
    
    BOOL _isOperating;
    BOOL _isFinished;
}

+ (RYOperation *)create {
    return self.new;
}

+ (RYOperation *(^)(dispatch_block_t))createWithBlock {
    return ^RYOperation *(dispatch_block_t optBlock) {
        if (nil != optBlock) {
            RYOperation *opt = RYOperation.create;
            opt.setBlock(optBlock);
            return opt;
        }
        return nil;
    };
}

- (RYOperation *(^)(dispatch_block_t))setBlock {
    return ^RYOperation *(dispatch_block_t optBlock) {
        _operationBlock = optBlock;
        return self;
    };
}

- (instancetype)init {
    if (self = [super init]) {
        _relation_set = [NSMutableSet set];
        _isReady = YES;
        _maxWaitTimeForOperate = DISPATCH_TIME_FOREVER;
        _minWaitTimeForOperate = DISPATCH_TIME_NOW;
    }
    return self;
}

- (void)addRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        [sSelf->_relation_set addObject:relation];
    });
}

- (void)removeRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        [sSelf->_relation_set removeObject:relation];
    });
}

- (RYOperation *(^)(RYOperationPriority ))setPriority {
    return ^RYOperation *(RYOperationPriority priority) {
        _priority = priority;
        return self;
    };
}

- (void)cancel {
    if(_isCancelled) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationCancelLock, YES, ^{
        __strong typeof(wSelf) sSelf = self;
        if (nil == sSelf) {
            return;
        }
        sSelf->_isCancelled = YES;
        [sSelf resume];
    });
}

- (BOOL)isCancelled {
    if (_isCancelled) {
        return YES;
    }
    __block BOOL isCancelled = NO;
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationCancelLock, NO, ^{
        __strong typeof(wSelf) sSelf = self;
        if (nil == sSelf) {
            return;
        }
        isCancelled = sSelf->_isCancelled;
    });
    return isCancelled;
}

- (BOOL)isReady {
    return _isReady;
}

- (BOOL)isOperating {
    return _isOperating;
}

- (BOOL)isFinished {
    return _isFinished;
}

- (NSString *)name { // for NSPredicate
    return _name;
}

- (RYOperationPriority)priority { // for NSPredicate
    return _priority;
}

- (NSSet<RYOperation *> *)allDependencies {
    return [_relation_set valueForKey:NSStringFromSelector(@selector(relier))];
}


#ifdef RYO_DEPENDENCY_CYCLE_CHECK_ON

- (NSArray<RYOperation *> *)findDemander:(RYOperation *)opt from:(RYOperation *)firstOpt {
    NSParameterAssert(opt && firstOpt);
    NSArray<RYDependencyRelation *> *rRlts = firstOpt.isRelierRelations;
    for (RYDependencyRelation *rlt in rRlts) {
        if (nil == rlt.demander) {
            continue;
        }
        if (rlt.demander == opt) {
            return @[opt, firstOpt];
        }
        return [self findDemander:opt from:rlt.demander];
    }
    return nil;
}

- (NSArray<RYOperation *> *)findRelier:(RYOperation *)opt from:(RYOperation *)firstOpt {
    NSParameterAssert(opt && firstOpt);
    NSArray<RYDependencyRelation *> *dRlts = firstOpt.isDemanderRelations;
    for (RYDependencyRelation *rlt in dRlts) {
        if (nil == rlt.relier) {
            continue;
        }
        if (rlt.relier == opt) {
            return @[opt, firstOpt];
        }
        return [self findRelier:opt from:rlt.relier];
    }
    return nil;
}

#endif


- (RYOperation *(^)(RYOperation *))addDependency {

    return ^RYOperation *(RYOperation *opt) {
        if (nil != opt) {
            _isReady = NO;
            RYDependencyRelation *dpy = [[RYDependencyRelation alloc] init];
            dpy.demander = self;
            dpy.relier = opt;
            dpy.semaphore = dispatch_semaphore_create(0);
            [self addRelation:dpy];
            [opt addRelation:dpy];
            _isReady = YES;
            
#ifdef RYO_DEPENDENCY_CYCLE_CHECK_ON
            @autoreleasepool {
                NSParameterAssert(![self findDemander:opt from:self]);
            }
            @autoreleasepool {
                NSParameterAssert(![self findRelier:self from:opt]);
            }
#endif
        }
        return self;
    };
}

- (RYOperation *(^)(RYOperation *))removeDependency {
    return ^RYOperation *(RYOperation *operation) {
        NSArray<RYDependencyRelation *> *allRelations = _relation_set.allObjects;
        RYDependencyRelation *relation = [allRelations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@ && %K == %@", NSStringFromSelector(@selector(demander)), self,NSStringFromSelector(@selector(relier)), operation]].firstObject;
        if (nil != relation) {
            [relation.relier removeRelation:relation];
            [relation.demander removeRelation:relation];
        }
        return self;
    };
}

- (RYOperation *)removeAllDependencies {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        [sSelf->_relation_set removeAllObjects];
    });
    return self;
}

- (RYOperation *(^)(NSString *))setName {
    return ^RYOperation *(NSString *name) {
        _name = name ? name.copy : nil;
        return self;
    };
}

- (dispatch_time_t)maxWaitTimeForOperate {
    __weak typeof(self) wSelf = self;
    __block dispatch_time_t waitTime;
    ry_lock(self, kOperationMaxWaitTimeLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        waitTime = sSelf->_maxWaitTimeForOperate;
    });
    return waitTime;
}

- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kOperationMaxWaitTimeLock, YES, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf) {
                return;
            }
            sSelf->_maxWaitTimeForOperate = waitTime;
        });
        return self;
    };
}

- (dispatch_time_t)minWaitTimeForOperate {
    __weak typeof(self) wSelf = self;
    __block dispatch_time_t waitTime;
    ry_lock(self, kOperationMinWaitTimeLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        waitTime = sSelf->_minWaitTimeForOperate;
    });
    return waitTime;
}

- (RYOperation *(^)(dispatch_time_t))setMinWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kOperationMinWaitTimeLock, YES, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf) {
                return;
            }
            sSelf->_minWaitTimeForOperate = waitTime;
        });
        return self;
    };
}

- (NSArray<RYDependencyRelation *> *)isDemanderRelations {
    NSArray<RYDependencyRelation *> *allRelations = _relation_set.allObjects;
    if (nil == allRelations || allRelations.count < 1) {
        return nil;
    }
    return [allRelations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(demander)), self]];
}

- (NSArray<RYDependencyRelation *> *)isRelierRelations {
    NSArray<RYDependencyRelation *> *allRelations = _relation_set.allObjects;
    if (nil == allRelations || allRelations.count < 1) {
        return nil;
    }
    return [allRelations filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(relier)), self]];
}

- (void)operate {
    if (_isFinished || _isOperating) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationOperateLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf || sSelf->_isFinished || sSelf->_isOperating) {
            return;
        }
        sSelf->_isOperating = YES;

        dispatch_semaphore_t min_wait_semaphore = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sSelf.minWaitTimeForOperate)), CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^{
            dispatch_semaphore_signal(min_wait_semaphore);
        });
        
        ry_lock(sSelf, kOperationRelationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (!sSelf.isCancelled) {
                NSArray<RYDependencyRelation *> *isDemanderRelations = sSelf.isDemanderRelations;
                dispatch_apply(isDemanderRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                    RYDependencyRelation *relation = isDemanderRelations[index];
                    dispatch_semaphore_wait(isDemanderRelations[index].semaphore, sSelf.maxWaitTimeForOperate);
                    if (nil != relation.relier && relation.relier.isCancelled) {
                        [sSelf cancel];
                    }
                });
                
                dispatch_semaphore_wait(min_wait_semaphore, DISPATCH_TIME_FOREVER);
                if (nil != sSelf->_operationBlock && !sSelf.isCancelled) {
                    sSelf->_operationBlock();
                }
                sSelf->_isOperating = NO;
            }
            
            NSArray<RYDependencyRelation *> *isRelierRelations =  sSelf.isRelierRelations;
            dispatch_apply(isRelierRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                dispatch_semaphore_signal(isRelierRelations[index].semaphore);
            });
        });
        
        sSelf->_isFinished = YES;
        if (nil !=  sSelf->_operateDoneBlock) {
             sSelf->_operateDoneBlock();
        }
    });
}

- (void)suspend {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationSuspendLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        for (NSUInteger i = 0; i < OperationSuspendedQueueCount; ++i) {
            if (sSelf->_suspended_queue[i]) {
                continue;
            }
            dispatch_queue_t queue = ry_lock_get_lock_queue(sSelf, kOperationRelationLock, NO);
            if (nil != queue) {
                dispatch_suspend(queue);
                sSelf->_suspended_queue[i] = queue;
            }
        }
    });

}

- (void)resume {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kOperationSuspendLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        for (NSUInteger i = 0; i < OperationSuspendedQueueCount; ++i) {
            dispatch_queue_t queue = sSelf->_suspended_queue[i];
            if (nil != queue) {
                dispatch_resume(queue);
                sSelf->_suspended_queue[i] = nil;
            }
        }
    });
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p %@>", self.class, self, _name];
}

@end


@implementation RYQueue {
    @protected
    
    NSUInteger _maxConcurrentOperationCount;
    NSUInteger _identifier;
    BOOL _sync;
    
    RYQueue *(^_excuteBlock)();
    dispatch_block_t _beforeExcuteBlock;
    dispatch_block_t _excuteDoneBlock;
    OperationWillStartBlock _operationWillStartBlock;
    __weak dispatch_queue_t _excuteQueue;

    NSMutableSet<RYOperation *> *_operationSet;
    
    BOOL _isExcuting;
    BOOL _isFinished;
    BOOL _isCancelled;
    
}

+ (RYQueue *)create {
    return self.new;
}

+ (RYQueue *(^)(RYOperation *))createWithOperation {
    return ^RYQueue* (RYOperation *operation) {
        RYQueue *queue = self.create;
        queue.addOperation(operation);
        return queue;
    };
}

+ (RYQueue *(^)(NSArray<RYOperation *> *))createWithOperations {
    return ^RYQueue* (NSArray<RYOperation *> *operations) {
        RYQueue *queue = self.create;
        queue.addOperations(operations);
        return queue;
    };
}

- (instancetype)init {
    if (self = [super init]) {
        __weak typeof(self) wSelf = self;
        _excuteBlock = ^RYQueue *{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf) {
                return nil;
            }
            if (nil != sSelf->_beforeExcuteBlock) {
                sSelf->_beforeExcuteBlock();
            }
            [sSelf excuteStart];
            return sSelf;
        };
    }
    return self;
}

- (RYQueue *(^)(RYOperation *))addOperation {
    return ^RYQueue* (RYOperation *operation) {
        return self.addOperations(@[operation]);
    };
}

- (RYQueue *(^)(NSArray<RYOperation *> *))addOperations {
    NSParameterAssert(!self->_isFinished && !self->_isExcuting);
    return ^RYQueue* (NSArray<RYOperation *> *operations) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kQueueAddOperationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf) {
                return;
            }
            if (nil == sSelf->_operationSet) {
                sSelf->_operationSet = [NSMutableSet set];
            }
            [sSelf->_operationSet addObjectsFromArray:operations];
            for (RYOperation *opt in operations) {
                NSCParameterAssert(opt->_queue == nil);
                opt->_queue = sSelf;
            }
        });
        return self;
    };
}

- (RYQueue* (^)(NSInteger))setIdentifier {
    return ^RYQueue* (NSInteger identifier) {
        _identifier = identifier;
        return self;
    };
}

- (RYQueue *(^)(BOOL async))setAsync {
    return ^RYQueue* (BOOL async) {
        _sync = !async;
        return self;
    };
}

- (NSSet<RYOperation *> *(^)(NSString *))operationsForName {
    return ^NSSet<RYOperation *> *(NSString *name) {
        __block NSSet<RYOperation *> *operations = nil;
        __weak typeof(self) wSelf = self;
        ry_lock(self, kQueueAddOperationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf) {
                return;
            }
            operations = [sSelf->_operationSet filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(name)), name]];
        });
        return operations;
    };
}

- (RYQueue *(^)(dispatch_block_t))setBeforeExcuteBlock {
    return ^RYQueue* (dispatch_block_t beforeBlock) {
        _beforeExcuteBlock = beforeBlock;
        return self;
    };
}

- (RYQueue *(^)(dispatch_block_t))setExcuteDoneBlock {
    return ^RYQueue* (dispatch_block_t doneBlock) {
        _excuteDoneBlock = doneBlock;
        return self;
    };
}

- (RYQueue *(^)(OperationWillStartBlock))setOperationWillStartBlock {
    return ^RYQueue* (OperationWillStartBlock willStartBlock) {
        _operationWillStartBlock = willStartBlock;
        return self;
    };
}

- (RYQueue *(^)(NSUInteger))setMaxConcurrentOperationCount {
    return ^RYQueue* (NSUInteger count) {
        NSCParameterAssert(count > 0);
        __weak typeof(self) wSelf = self;
        ry_lock(self, kSetMaxConcurrentOperationCountLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf || count == sSelf.maxConcurrentOperationCount) {
                return;
            }
            sSelf->_maxConcurrentOperationCount = count;
        });
        return self;
    };
}

- (NSUInteger)maxConcurrentOperationCount {
    if (_maxConcurrentOperationCount < 1) {
        _maxConcurrentOperationCount = 12;
    }
    return _maxConcurrentOperationCount;
}

- (void)excuteStart {
    if (_isFinished || _isExcuting || _isCancelled) {
        return;
    }
    __weak typeof(self) wSelf = self;
    _excuteQueue = ry_lock(self, kQueueExcuteLock, !_sync, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf || sSelf->_isFinished || sSelf->_isExcuting || sSelf->_isCancelled) {
            return;
        }

        NSString *isDemandersKey = NSStringFromSelector(@selector(isDemanderRelations));
        NSSet<RYOperation *> *notDemanderSet = sSelf->_operationSet ? [sSelf->_operationSet filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == nil || %K[SIZE] == 0", isDemandersKey, isDemandersKey]] : nil;
        if (nil != notDemanderSet) {
            sSelf->_isExcuting = YES;
            NSArray<RYOperation *> *sortedNotDemanderArray = [notDemanderSet sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(priority)) ascending:NO]]];
            
            void (^runOperation)(RYOperation *) = ^(RYOperation *opt) {
                ry_lock(opt, kOperationOperateLock, YES, ^{
                    __strong typeof(wSelf) sSelf = wSelf;
                    if (nil != sSelf && nil != sSelf->_operationWillStartBlock && nil != opt && !opt->_isOperating && !opt->_isFinished) {
                        sSelf->_operationWillStartBlock(opt);
                    }
                });
                [opt operate];
            };
            
            dispatch_semaphore_t operate_done_semp = dispatch_semaphore_create(0);
            [sSelf->_operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                __weak typeof(opt) wOpt = opt;
                opt->_operateDoneBlock = ^{
                    dispatch_semaphore_signal(operate_done_semp);
                    NSArray<RYDependencyRelation *> *relations = wOpt.isRelierRelations;
                    [relations enumerateObjectsUsingBlock:^(RYDependencyRelation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                        if (nil != obj.demander) {
                            runOperation(obj.demander);
                        }
                    }];
                };
            }];
            
            __block NSUInteger maxOperationCount;
            ry_lock(self, kSetMaxConcurrentOperationCountLock, NO, ^{
                maxOperationCount = sSelf.maxConcurrentOperationCount;
            });
            dispatch_semaphore_t excute_max_operation_count_semp = dispatch_semaphore_create(maxOperationCount);
            [sortedNotDemanderArray enumerateObjectsUsingBlock:^(RYOperation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                dispatch_semaphore_wait(excute_max_operation_count_semp, DISPATCH_TIME_FOREVER);
                runOperation(obj);
                dispatch_semaphore_signal(excute_max_operation_count_semp);
            }];
            
            [sSelf->_operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull obj, BOOL * _Nonnull stop) {
                dispatch_semaphore_wait(operate_done_semp, DISPATCH_TIME_FOREVER);
            }];
            
            sSelf->_isExcuting = NO;
            sSelf->_isFinished = YES;
            if (nil != sSelf->_excuteDoneBlock) {
                sSelf->_excuteDoneBlock();
            }
        }
    });
}

- (RYQueue *(^)())excute {
    return _excuteBlock;
}

- (void)cancel {
    if (_isCancelled) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kCancelAllOperationsLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf || sSelf->_isCancelled) {
            return;
        }
        sSelf->_isCancelled = YES;

        NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
        dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
            RYOperation *opt = operations[index];
            [opt cancel];
        });
    });
}

- (void)suspend {
    if (nil == self || nil == _operationSet || _operationSet.count < 1) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kQueueSuspendLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf || nil == sSelf->_operationSet || sSelf->_operationSet.count < 1) {
            return;
        }
        ry_lock(sSelf, kQueueAddOperationLock, NO, ^{
            NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
            dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                [operations[index] suspend];
            });
        });


    });
}

- (void)resume {
    if (nil == self || nil == _operationSet || _operationSet.count < 1) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kQueueSuspendLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf || nil == sSelf->_operationSet || sSelf->_operationSet.count < 1) {
            return;
        }
        ry_lock(sSelf, kQueueAddOperationLock, NO, ^{
            NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
            dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                [operations[index] resume];
            });
        });

    });
}

- (BOOL)isCancelled {
    if (_isCancelled) {
        return YES;
    }
    __block BOOL isCancelled = NO;
    __weak typeof(self) wSelf = self;
    ry_lock(self, kCancelAllOperationsLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (nil == sSelf) {
            return;
        }
        isCancelled = sSelf->_isCancelled;
    });
    return isCancelled;
}

@end



