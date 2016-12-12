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


static const void *const kOperationRelationLock = &kOperationRelationLock;
static const void *const kOperationCancelLock = &kOperationCancelLock;
static const void *const kOperationSuspendLock = &kOperationSuspendLock;
static const void *const kOperationOperateLock = &kOperationOperateLock;
static const void *const kOperationMinWaitTimeLock = &kOperationMinWaitTimeLock;
static const void *const kOperationMaxWaitTimeLock = &kOperationMaxWaitTimeLock;
static const void *const kQueueAddOperationLock = &kQueueAddOperationLock;
static const void *const kQueueExcuteLock = &kQueueExcuteLock;
static const void *const kQueueSuspendLock = &kQueueSuspendLock;
static const void *const kQueueCancelAllOperationsLock = &kQueueCancelAllOperationsLock;
static const void *const kQueueSetMaxConcurrentOperationCountLock= &kQueueSetMaxConcurrentOperationCountLock;

enum {
    kOperationRelationLockSuspendedQueue,
    kOperationOperateLockSuspendedQueue,
    
    OperationSuspendedQueueCount
};

dispatch_queue_t ry_lock_get_lock_queue(id holder, const void *key, BOOL createIfNotExist) {
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
    
    NSNumber *numKey = @((size_t)key);
    dispatch_queue_t serial_queue = [serial_queue_map objectForKey:numKey];
    if (nil == serial_queue && createIfNotExist) {
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", holder, numKey];
        serial_queue = CREATE_DISPATCH_SERIAL_QUEUE(identifier);
        [serial_queue_map setObject:serial_queue forKey:numKey];
    }
    
    dispatch_semaphore_signal(holder_semp);
    
    return serial_queue;
}

dispatch_queue_t ry_lock(id holder, const void *key, BOOL async, RYLockedBlock lockedBlock) {
    if (!holder) {
        holder = NSObject.class;
    }
    dispatch_queue_t queue = ry_lock_get_lock_queue(holder, key, YES);
    __weak typeof(holder) wHolder = holder;
    if (nil != lockedBlock) {
        (async ? dispatch_async : dispatch_sync)(queue, ^{
            __strong typeof(wHolder) sHoloder = wHolder;
            if (nil != sHoloder) {
                @autoreleasepool {
                    lockedBlock(sHoloder);
                }
            }
        });
    }
    
    return queue;
}

NS_INLINE void ry_valueChange(NSObject *target, NSString *key, dispatch_block_t block) {
    [target willChangeValueForKey:key];
    block();
    [target didChangeValueForKey:key];
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

    NSMutableSet<RYDependencyRelation *> *_isDemanderRelations;
    NSMutableSet<RYDependencyRelation *> *_isRelierRelations;

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
        _maxWaitTimeForOperate = DISPATCH_TIME_FOREVER;
        _minWaitTimeForOperate = DISPATCH_TIME_NOW;
        ry_valueChange(self, NSStringFromSelector(@selector(isReady)), ^{
            _isReady = YES;
        });
    }
    return self;
}

- (void)addRelation:(RYDependencyRelation *)relation {
    ry_lock(self, kOperationRelationLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        
        NSString *isReadyKey = NSStringFromSelector(@selector(isReady));
        if (sSelf->_isReady) {
            ry_valueChange(sSelf, isReadyKey, ^{
                sSelf->_isReady = NO;
            });
        }
        
        if (relation.relier == sSelf) {
            if (nil == sSelf->_isRelierRelations) {
                sSelf->_isRelierRelations = [NSMutableSet set];
            }
            [sSelf->_isRelierRelations addObject:relation];
        } else if (relation.demander == sSelf) {
            if (nil == sSelf->_isDemanderRelations) {
                sSelf->_isDemanderRelations = [NSMutableSet set];
            }
            [sSelf->_isDemanderRelations addObject:relation];
        }
        
        ry_valueChange(sSelf, isReadyKey, ^{
            sSelf->_isReady = YES;
        });
    });
}

- (void)removeRelation:(RYDependencyRelation *)relation {
    ry_lock(self, kOperationRelationLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        
        NSString *isReadyKey = NSStringFromSelector(@selector(isReady));
        if (sSelf->_isReady) {
            ry_valueChange(sSelf, isReadyKey, ^{
                sSelf->_isReady = NO;
            });
        }
        
        if (relation.relier == sSelf) {
            if (nil == sSelf->_isRelierRelations) {
                return;
            }
            [sSelf->_isRelierRelations addObject:relation];
        } else if (relation.demander == sSelf) {
            if (nil == sSelf->_isDemanderRelations) {
                return;
            }
            [sSelf->_isDemanderRelations addObject:relation];
        }
        
        ry_valueChange(sSelf, isReadyKey, ^{
            sSelf->_isReady = YES;
        });
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
    ry_lock(self, kOperationCancelLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        if(sSelf->_isCancelled) {
            return;
        }
        ry_valueChange(sSelf, NSStringFromSelector(@selector(isCancelled)), ^{
            sSelf->_isCancelled = YES;
        });
        [sSelf resume];
    });
}

- (BOOL)isCancelled {
    if (_isCancelled) {
        return YES;
    }
    __block BOOL isCancelled = NO;
    ry_lock(self, kOperationCancelLock, NO, ^(id holder){
        RYOperation *sSelf = holder;
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

- (NSString *)name {
    return _name;
}

- (RYOperationPriority)priority {
    return _priority;
}

- (NSSet<RYOperation *> *)allDependencies {
    return [_isDemanderRelations valueForKey:NSStringFromSelector(@selector(relier))];
}


#ifdef RYO_DEPENDENCY_CYCLE_CHECK_ON

- (NSArray<RYOperation *> *)findDemander:(RYOperation *)opt from:(RYOperation *)firstOpt {
    NSParameterAssert(opt && firstOpt);
    NSSet<RYDependencyRelation *> *rRlts = firstOpt.isRelierRelations;
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
    NSSet<RYDependencyRelation *> *dRlts = firstOpt.isDemanderRelations;
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
            RYDependencyRelation *dpy = [[RYDependencyRelation alloc] init];
            dpy.demander = self;
            dpy.relier = opt;
            dpy.semaphore = dispatch_semaphore_create(0);
            [self addRelation:dpy];
            [opt addRelation:dpy];
            
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
        ry_lock(self, kOperationRelationLock, YES, ^(id holder){
            RYOperation *sSelf = holder;
            if (nil == sSelf->_isDemanderRelations || sSelf->_isDemanderRelations.count < 1) {
                return;
            }
            RYDependencyRelation *relation = [sSelf->_isDemanderRelations filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(relier)), operation]].anyObject;
            if (nil != relation) {
                [relation.relier removeRelation:relation];
                [relation.demander removeRelation:relation];
            }
        });
        return self;
    };
}

- (RYOperation *)removeAllDependencies {
    ry_lock(self, kOperationRelationLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        if (nil == sSelf->_isDemanderRelations || sSelf->_isDemanderRelations.count < 1) {
            return;
        }
        [sSelf->_isDemanderRelations enumerateObjectsUsingBlock:^(RYDependencyRelation * _Nonnull relation, BOOL * _Nonnull stop) {
            [relation.relier removeRelation:relation];
            [relation.demander removeRelation:relation];
        }];
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
    __block dispatch_time_t waitTime;
    ry_lock(self, kOperationMaxWaitTimeLock, NO, ^(id holder){
        RYOperation *sSelf = holder;
        waitTime = sSelf->_maxWaitTimeForOperate;
    });
    return waitTime;
}

- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        ry_lock(self, kOperationMaxWaitTimeLock, YES, ^(id holder){
            RYOperation *sSelf = holder;
            sSelf->_maxWaitTimeForOperate = waitTime;
        });
        return self;
    };
}

- (dispatch_time_t)minWaitTimeForOperate {
    __block dispatch_time_t waitTime;
    ry_lock(self, kOperationMinWaitTimeLock, NO, ^(id holder){
        RYOperation *sSelf = holder;
        waitTime = sSelf->_minWaitTimeForOperate;
    });
    return waitTime;
}

- (RYOperation *(^)(dispatch_time_t))setMinWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        ry_lock(self, kOperationMinWaitTimeLock, YES, ^(id holder){
            RYOperation *sSelf = holder;
            sSelf->_minWaitTimeForOperate = waitTime;
        });
        return self;
    };
}

- (NSSet<RYDependencyRelation *> *)isDemanderRelations {
    return _isDemanderRelations;
}

- (NSSet<RYDependencyRelation *> *)isRelierRelations {
    return _isRelierRelations;
}

- (void)operate {
    if (_isFinished || _isOperating) {
        return;
    }
    ry_lock(self, kOperationOperateLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        if (sSelf->_isFinished || sSelf->_isOperating) {
            return;
        }

        dispatch_semaphore_t min_wait_semaphore = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sSelf.minWaitTimeForOperate)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_signal(min_wait_semaphore);
        });
        
        dispatch_queue_t apply_queue = CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf);
        if (!sSelf.isCancelled) {
            NSString *isOperatingKey = NSStringFromSelector(@selector(isOperating));
            ry_valueChange(sSelf, isOperatingKey, ^{
                sSelf->_isOperating = YES;
            });
            
            __block NSArray<RYDependencyRelation *> *isDemanderRelations = sSelf.isDemanderRelations.allObjects;
            ry_lock(sSelf, kOperationRelationLock, NO, ^(id holder){
                isDemanderRelations = sSelf.isDemanderRelations.allObjects;
            });
            dispatch_apply(isDemanderRelations.count, apply_queue, ^(size_t index) {
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
            ry_valueChange(sSelf, isOperatingKey, ^{
                sSelf->_isOperating = NO;
            });
        }
        __block NSArray<RYDependencyRelation *> *isRelierRelations = nil;
        ry_lock(sSelf, kOperationRelationLock, NO, ^(id holder){
            isRelierRelations =  sSelf.isRelierRelations.allObjects;
        });
        dispatch_apply(isRelierRelations.count, apply_queue, ^(size_t index) {
            dispatch_semaphore_signal(isRelierRelations[index].semaphore);
        });
        
        ry_valueChange(sSelf, NSStringFromSelector(@selector(isFinished)), ^{
            sSelf->_isFinished = YES;
        });
        if (nil !=  sSelf->_operateDoneBlock) {
             sSelf->_operateDoneBlock();
        }
    });
}

- (void)suspend {
    ry_lock(self, kOperationSuspendLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
        for (NSUInteger i = 0; i < OperationSuspendedQueueCount; ++i) {
            if (sSelf->_suspended_queue[i]) {
                continue;
            }
            dispatch_queue_t queue = ry_lock_get_lock_queue(sSelf, kOperationRelationLock, YES);
            dispatch_suspend(queue);
            sSelf->_suspended_queue[i] = queue;
        }
    });

}

- (void)resume {
    ry_lock(self, kOperationSuspendLock, YES, ^(id holder){
        RYOperation *sSelf = holder;
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
        ry_lock(self, kQueueAddOperationLock, NO, ^(id holder){
            RYQueue *sSelf = holder;
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
        ry_lock(self, kQueueAddOperationLock, NO, ^(id holder){
            RYQueue *sSelf = holder;
            if (nil == sSelf->_operationSet || sSelf->_operationSet.count < 1) {
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
        ry_lock(self, kQueueSetMaxConcurrentOperationCountLock, NO, ^(id holder){
            RYQueue *sSelf = holder;
            if (count == sSelf.maxConcurrentOperationCount) {
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
    _excuteQueue = ry_lock(self, kQueueExcuteLock, !_sync, ^(id holder){
        RYQueue *sSelf = holder;
        if (sSelf->_isFinished || sSelf->_isExcuting || sSelf->_isCancelled) {
            return;
        }

        NSString *isDemandersKey = NSStringFromSelector(@selector(isDemanderRelations));
        NSSet<RYOperation *> *notDemanderSet = sSelf->_operationSet ? [sSelf->_operationSet filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == nil || %K[SIZE] == 0", isDemandersKey, isDemandersKey]] : nil;
        if (nil != notDemanderSet) {
            ry_valueChange(sSelf, NSStringFromSelector(@selector(isExecuting)), ^{
                sSelf->_isExcuting = YES;
            });
            NSArray<RYOperation *> *sortedNotDemanderArray = [notDemanderSet sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(priority)) ascending:NO]]];
            
            void (^runOperation)(RYOperation *) = ^(RYOperation *opt) {
                if (opt->_isOperating || opt->_isFinished) {
                    return;
                }
                ry_lock(opt, kOperationOperateLock, YES, ^(id holder){
                    RYOperation *sOpt = holder;
                    if (nil != sSelf && nil != sSelf->_operationWillStartBlock && !sOpt->_isOperating && !sOpt->_isFinished ) {
                        sSelf->_operationWillStartBlock(sOpt);
                    }
                });
                [opt operate];
            };
            
            __block NSUInteger maxOperationCount;
            ry_lock(sSelf, kQueueSetMaxConcurrentOperationCountLock, NO, ^(id holder){
                RYQueue *sSelf = holder;
                maxOperationCount = sSelf.maxConcurrentOperationCount;
            });
            dispatch_semaphore_t excute_max_operation_count_semp = dispatch_semaphore_create(maxOperationCount);
            dispatch_semaphore_t operate_done_semp = dispatch_semaphore_create(0);
            [sSelf->_operationSet enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, BOOL * _Nonnull stop) {
                __weak typeof(opt) wOpt = opt;
                opt->_operateDoneBlock = ^{
                    dispatch_semaphore_signal(excute_max_operation_count_semp);
                    dispatch_semaphore_signal(operate_done_semp);
                    NSSet<RYDependencyRelation *> *relations = wOpt.isRelierRelations;
                    [relations enumerateObjectsUsingBlock:^(RYDependencyRelation * _Nonnull obj, BOOL * _Nonnull stop) {
                        if (nil != obj.demander) {
                            runOperation(obj.demander);
                        }
                    }];
                };
            }];
            
            for (RYOperation *opt in sortedNotDemanderArray) {
                dispatch_semaphore_wait(excute_max_operation_count_semp, DISPATCH_TIME_FOREVER);
                runOperation(opt);
            }
            
            NSEnumerator *enumerator = sSelf->_operationSet.objectEnumerator;
            while (nil != enumerator.nextObject) {
                dispatch_semaphore_wait(operate_done_semp, DISPATCH_TIME_FOREVER);
            }
            
            ry_valueChange(sSelf, NSStringFromSelector(@selector(isExecuting)), ^{
                sSelf->_isExcuting = NO;
            });
            ry_valueChange(sSelf, NSStringFromSelector(@selector(isFinished)), ^{
                sSelf->_isFinished = YES;
            });
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
    ry_lock(self, kQueueCancelAllOperationsLock, YES, ^(id holder){
        RYQueue *sSelf = holder;
        if (sSelf->_isCancelled) {
            return;
        }
        ry_valueChange(sSelf, NSStringFromSelector(@selector(isCancelled)), ^{
            sSelf->_isCancelled = YES;
        });
        NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
        dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
            RYOperation *opt = operations[index];
            [opt cancel];
        });
    });
}

- (void)suspend {
    ry_lock(self, kQueueSuspendLock, YES, ^(id holder){
        RYQueue *sSelf = holder;
        if (nil == sSelf->_operationSet || sSelf->_operationSet.count < 1) {
            return;
        }
        ry_lock(sSelf, kQueueAddOperationLock, NO, ^(id holder){
            NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
            dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                [operations[index] suspend];
            });
        });


    });
}

- (void)resume {
    ry_lock(self, kQueueSuspendLock, YES, ^(id holder){
        RYQueue *sSelf = holder;
        if (nil == sSelf->_operationSet || sSelf->_operationSet.count < 1) {
            return;
        }
        ry_lock(sSelf, kQueueAddOperationLock, NO, ^(id holder){
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
    ry_lock(self, kQueueCancelAllOperationsLock, NO, ^(id holder){
        RYQueue *sSelf = holder;
        isCancelled = sSelf->_isCancelled;
    });
    return isCancelled;
}

- (BOOL)isFinished {
    return _isFinished;
}

- (BOOL)isExcuting {
    return _isExcuting;
}

@end



