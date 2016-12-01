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
    kRelationLock = 1000,
    kOperationOperateLock,
    kAddOperationLock,
    kQueueExcuteLock,
    kCancelAllOperationsLock,
    kSetMaxConcurrentOperationCountLock,
};

dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock) {
    if (nil == holder || nil == lockedBlock) {
        return nil;
    }
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
    if (nil == serial_queue) {
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", holder, @(lockId)];
        serial_queue = CREATE_DISPATCH_SERIAL_QUEUE(identifier);
    }
    
    dispatch_semaphore_signal(holder_semp);

    __weak typeof(holder) wHolder = holder;
    (async ? dispatch_async : dispatch_sync)(serial_queue, ^{
        if (nil != wHolder) {
            @autoreleasepool {
                lockedBlock();
            }
        }
    });
    
    return serial_queue;
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
    dispatch_time_t _minusWaitTimeForOperate;
    
    BOOL _isCanceled;
    BOOL _isReady;
    BOOL _isOperating;
    BOOL _isFinished;
    
    @public
    __weak RYQueue *_queue;
    dispatch_block_t _operateDoneBlock;
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
        _minusWaitTimeForOperate = DISPATCH_TIME_NOW;
    }
    return self;
}

- (void)addRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kRelationLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        [sSelf->_relation_set addObject:relation];
    });
}

- (void)removeRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kRelationLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
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
    _isCanceled = YES;
}

- (BOOL)isCancelled {
    return _isCanceled;
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
    ry_lock(self, kRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
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

- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kRelationLock, YES, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            sSelf->_maxWaitTimeForOperate = waitTime;
        });
        return self;
    };
}

- (RYOperation *(^)(dispatch_time_t))setMinusWaitTimeForOperate {
    return ^RYOperation *(dispatch_time_t waitTime) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kRelationLock, YES, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            sSelf->_minusWaitTimeForOperate = waitTime;
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
        if (sSelf->_isFinished || sSelf->_isOperating) {
            return;
        }
        sSelf->_isOperating = YES;

        dispatch_semaphore_t minus_wait_semaphore = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sSelf->_minusWaitTimeForOperate)), CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^{
            dispatch_semaphore_signal(minus_wait_semaphore);
        });
        
        ry_lock(sSelf, kRelationLock, NO, ^{
            if (!sSelf->_isCanceled) {
                NSArray<RYDependencyRelation *> *isDemanderRelations = sSelf.isDemanderRelations;
                dispatch_apply(isDemanderRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                    RYDependencyRelation *relation = isDemanderRelations[index];
                    dispatch_semaphore_wait(isDemanderRelations[index].semaphore, sSelf->_maxWaitTimeForOperate);
                    if (relation.relier->_isCanceled) {
                        sSelf->_isCanceled = YES;
                    }
                });
                
                dispatch_semaphore_wait(minus_wait_semaphore, DISPATCH_TIME_FOREVER);
                if (nil != sSelf->_operationBlock && !sSelf->_isCanceled) {
                    sSelf->_operationBlock();
                }
                sSelf->_isOperating = NO;
                sSelf->_isFinished = YES;
            }
            
            NSArray<RYDependencyRelation *> *isRelierRelations =  sSelf.isRelierRelations;
            dispatch_apply(isRelierRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                dispatch_semaphore_signal(isRelierRelations[index].semaphore);
            });
        });
        
        if (nil !=  sSelf->_operateDoneBlock) {
             sSelf->_operateDoneBlock();
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
    __weak dispatch_semaphore_t _handle_concurrent_semaphore;
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
        ry_lock(self, kAddOperationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf->_operationSet) {
                sSelf->_operationSet = [NSMutableSet set];
            }
            ry_lock(sSelf, kQueueExcuteLock, YES, ^{
                [sSelf->_operationSet addObjectsFromArray:operations];
                for (RYOperation *opt in operations) {
                    NSCParameterAssert(opt->_queue == nil);
                    opt->_queue = sSelf;
                }
            });
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
        ry_lock(self, kAddOperationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
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
            if (count == sSelf.maxConcurrentOperationCount) {
                return;
            }
            if (sSelf->_isExcuting && nil != sSelf->_excuteQueue && nil != sSelf->_handle_concurrent_semaphore) {
                dispatch_suspend(sSelf->_excuteQueue);
                BOOL increase = count > sSelf.maxConcurrentOperationCount;
                for (NSUInteger i = sSelf.maxConcurrentOperationCount; i != count; increase ? ++i : --i) {
                    increase ? dispatch_semaphore_signal(sSelf->_handle_concurrent_semaphore) : dispatch_semaphore_wait(sSelf->_handle_concurrent_semaphore, DISPATCH_TIME_FOREVER);
                }
                dispatch_resume(sSelf->_excuteQueue);
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
        if (sSelf->_isFinished || sSelf->_isExcuting || sSelf->_isCancelled) {
            return;
        }

        NSString *isDemandersKey = NSStringFromSelector(@selector(isDemanderRelations));
        NSSet<RYOperation *> *notDemanderSet = sSelf->_operationSet ? [sSelf->_operationSet filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"%K == nil || %K[SIZE] == 0", isDemandersKey, isDemandersKey]] : nil;
        if (nil != notDemanderSet) {
            sSelf->_isExcuting = YES;
            NSArray<RYOperation *> *sortedNotDemanderArray = [notDemanderSet sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(priority)) ascending:NO]]];
            
            dispatch_semaphore_t excute_max_operation_count_semp = dispatch_semaphore_create(sSelf.maxConcurrentOperationCount);
            sSelf->_handle_concurrent_semaphore = excute_max_operation_count_semp;
            dispatch_queue_t operate_queue = CREATE_DISPATCH_CONCURRENT_QUEUE(wSelf);
            
            
            static void (^handleExcute)(RYOperation *);
            if (nil == handleExcute) {
                handleExcute = ^(RYOperation *opt) {
                    if (nil != sSelf->_operationWillStartBlock) {
                        sSelf->_operationWillStartBlock(opt);
                    }
                    [opt operate];
                    NSArray<RYDependencyRelation *> *relations = opt.isRelierRelations;
                    [relations enumerateObjectsUsingBlock:^(RYDependencyRelation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                        if (nil != obj.demander) {
                            handleExcute(obj.demander);
                        }
                    }];
                };
            }
            
            dispatch_apply(notDemanderSet.count, operate_queue, ^(size_t index) {
                dispatch_semaphore_wait(excute_max_operation_count_semp, DISPATCH_TIME_FOREVER);
                handleExcute(sortedNotDemanderArray[index]);
                dispatch_semaphore_signal(excute_max_operation_count_semp);
            });
            
            dispatch_semaphore_t operate_done_semp = dispatch_semaphore_create(0);
            for (RYOperation *opt in sSelf->_operationSet) {
                opt->_operateDoneBlock = ^{
                    dispatch_semaphore_signal(operate_done_semp);
                };
                dispatch_semaphore_wait(operate_done_semp, DISPATCH_TIME_FOREVER);
            }
            
            sSelf->_isExcuting = NO;
            sSelf->_isFinished = YES;
            if (nil != _excuteDoneBlock) {
                _excuteDoneBlock();
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
    ry_lock(self, kCancelAllOperationsLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (sSelf->_isCancelled) {
            return;
        }
        if (sSelf->_isExcuting && nil != sSelf->_excuteQueue) {
            dispatch_suspend(sSelf->_excuteQueue);
        }
        NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
        dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
            RYOperation *opt = operations[index];
            [opt cancel];
        });
        sSelf->_isCancelled = YES;
        if (sSelf->_isExcuting && nil != sSelf->_excuteQueue) {
            dispatch_resume(sSelf->_excuteQueue);
        }
    });
}

- (BOOL)isCancelled {
    return _isCancelled;
}

@end



