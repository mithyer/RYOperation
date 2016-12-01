//
//  RYOperation.m
//  RYOperation
//
//  Created by ray on 16/11/8.
//  Copyright © 2016年 ray. All rights reserved.
//

#import "RYOperation.h"
#import <objc/runtime.h>

#define DISPATCH_QUENE_LABEL(ID) [NSString stringWithFormat:@"quene_label: %@, line:%d, id:%@",[[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, ID].UTF8String
#define CREATE_DISPATCH_SERIAL_QUEUE(ID) dispatch_queue_create(DISPATCH_QUENE_LABEL(ID), DISPATCH_QUEUE_SERIAL)
#define CREATE_DISPATCH_CONCURRENT_QUEUE(ID) dispatch_queue_create(DISPATCH_QUENE_LABEL(ID), DISPATCH_QUEUE_CONCURRENT)

#define RYO_DEPENDENCY_CYCLE_CHECK_ON

enum {
    kRelationLock = 1000,
    kAddOperationLock,
    kQueneExcuteLock,
    kCancelAllOperationsLock,
    kSetMaxConcurrentOperationCountLock,
};

dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock) {
    if (nil == lockedBlock) {
        return nil;
    }
    static dispatch_once_t once_t;
    static dispatch_semaphore_t add_new_quene_semp;
    dispatch_once(&once_t, ^{
        add_new_quene_semp = dispatch_semaphore_create(1);
    });
    
    dispatch_semaphore_wait(add_new_quene_semp, DISPATCH_TIME_FOREVER);
    
    static void *seriral_quene_map_key = &seriral_quene_map_key;
    NSMapTable<NSNumber *, dispatch_queue_t> * serial_quene_map = objc_getAssociatedObject(holder, seriral_quene_map_key);
    if (nil == serial_quene_map) {
        serial_quene_map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory];
        objc_setAssociatedObject(holder ,seriral_quene_map_key, serial_quene_map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    dispatch_queue_t serial_quene = [serial_quene_map objectForKey:@(lockId)];
    if (nil == serial_quene) {
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", holder, @(lockId)];
        serial_quene = CREATE_DISPATCH_SERIAL_QUEUE(identifier);
    }
    
    dispatch_semaphore_signal(add_new_quene_semp);

    __weak typeof(holder) wHolder = holder;
    (async ? dispatch_async : dispatch_sync)(serial_quene, ^{
        if (nil != wHolder) {
            @autoreleasepool {
                lockedBlock();
            }
        }
    });
    
    return serial_quene;
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
    
    dispatch_time_t _maxWaitTimeForExcute;
    dispatch_time_t _minusWaitTimeForExucte;
    
    BOOL _isCanceled;
    BOOL _isReady;
    BOOL _isExcuting;
    BOOL _isFinished;
    
    @public
    __weak RYQuene *_quene;
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
        _maxWaitTimeForExcute = DISPATCH_TIME_FOREVER;
        _minusWaitTimeForExucte = DISPATCH_TIME_NOW;
    }
    return self;
}

- (void)addRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        [sSelf->_relation_set addObject:relation];
    });
}

- (void)removeRelation:(RYDependencyRelation *)relation {
    __weak typeof(self) wSelf = self;
    ry_lock(self, kRelationLock, YES, ^{
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

- (BOOL)isExcuting {
    return _isExcuting;
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

- (RYOperation *(^)(dispatch_time_t))setMaxWaitTimeForExcute {
    return ^RYOperation *(dispatch_time_t waitTime) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kRelationLock, YES, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            sSelf->_maxWaitTimeForExcute = waitTime;
        });
        return self;
    };
}

- (RYOperation *(^)(dispatch_time_t))setMinusWaitTimeForExucte {
    return ^RYOperation *(dispatch_time_t waitTime) {
        ry_lock(self, kRelationLock, YES, ^{
            __weak typeof(self) wSelf = self;
            ry_lock(self, kRelationLock, YES, ^{
                __strong typeof(wSelf) sSelf = wSelf;
                sSelf->_minusWaitTimeForExucte = waitTime;
            });
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

- (void)excute:(dispatch_block_t)completedBlock {
    __weak typeof(self) wSelf = self;

    ry_lock(self, kRelationLock, YES, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (sSelf->_isFinished || sSelf->_isExcuting) {
            return;
        }
        
        dispatch_semaphore_t minus_wait_semaphore = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sSelf->_minusWaitTimeForExucte)), CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^{
            dispatch_semaphore_signal(minus_wait_semaphore);
        });
        
        if (!sSelf->_isCanceled) {
            NSArray<RYDependencyRelation *> *isDemanderRelations = sSelf.isDemanderRelations;
            dispatch_apply(isDemanderRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
                RYDependencyRelation *relation = isDemanderRelations[index];
                dispatch_semaphore_wait(isDemanderRelations[index].semaphore, sSelf->_maxWaitTimeForExcute);
                if (relation.relier->_isCanceled) {
                    sSelf->_isCanceled = YES;
                }
            });
            
            dispatch_semaphore_wait(minus_wait_semaphore, DISPATCH_TIME_FOREVER);
            if (nil != sSelf->_operationBlock && !sSelf->_isCanceled) {
                sSelf->_isExcuting = YES;
                sSelf->_operationBlock();
            }
            sSelf->_isExcuting = NO;
            sSelf->_isFinished = YES;
        }
        
        NSArray<RYDependencyRelation *> *isRelierRelations =  sSelf.isRelierRelations;
        dispatch_apply(isRelierRelations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
            dispatch_semaphore_signal(isRelierRelations[index].semaphore);
        });
        
        
        if (nil != completedBlock) {
            completedBlock();
        }
    });
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p %@>", self.class, self, _name];
}

@end


@implementation RYQuene {
    @protected
    
    NSUInteger _maxConcurrentOperationCount;
    __weak dispatch_semaphore_t _handle_concurrent_semaphore;
    NSUInteger _identifier;
    BOOL _sync;
    
    RYQuene *(^_excuteBlock)();
    dispatch_block_t _beforeExcuteBlock;
    dispatch_block_t _excuteDoneBlock;
    OperationWillStartBlock _operationWillStartBlock;
    __weak dispatch_queue_t _excuteQuene;

    NSMutableSet<RYOperation *> *_operationSet;
    
    BOOL _isExcuting;
    BOOL _isFinished;
    BOOL _isCancelled;
    
}

+ (RYQuene *)create {
    return self.new;
}

+ (RYQuene *(^)(RYOperation *))createWithOperation {
    return ^RYQuene* (RYOperation *operation) {
        RYQuene *quene = self.create;
        quene.addOperation(operation);
        return quene;
    };
}

+ (RYQuene *(^)(NSArray<RYOperation *> *))createWithOperations {
    return ^RYQuene* (NSArray<RYOperation *> *operations) {
        RYQuene *quene = self.create;
        quene.addOperations(operations);
        return quene;
    };
}

- (instancetype)init {
    if (self = [super init]) {
        __weak typeof(self) wSelf = self;
        _excuteBlock = ^RYQuene *{
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

- (RYQuene *(^)(RYOperation *))addOperation {
    return ^RYQuene* (RYOperation *operation) {
        return self.addOperations(@[operation]);
    };
}

- (RYQuene *(^)(NSArray<RYOperation *> *))addOperations {
    NSParameterAssert(!self->_isFinished && !self->_isExcuting);
    return ^RYQuene* (NSArray<RYOperation *> *operations) {
        __weak typeof(self) wSelf = self;
        ry_lock(self, kAddOperationLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (nil == sSelf->_operationSet) {
                sSelf->_operationSet = [NSMutableSet set];
            }
            ry_lock(self, kQueneExcuteLock, NO, ^{
                [sSelf->_operationSet addObjectsFromArray:operations];
                for (RYOperation *opt in operations) {
                    NSCParameterAssert(opt->_quene == nil);
                    opt->_quene = sSelf;
                }
            });
        });
        return self;
    };
}

- (RYQuene* (^)(NSInteger))setIdentifier {
    return ^RYQuene* (NSInteger identifier) {
        _identifier = identifier;
        return self;
    };
}

- (RYQuene *(^)(BOOL async))setAsync {
    return ^RYQuene* (BOOL async) {
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

- (RYQuene *(^)(dispatch_block_t))setBeforeExcuteBlock {
    return ^RYQuene* (dispatch_block_t beforeBlock) {
        _beforeExcuteBlock = beforeBlock;
        return self;
    };
}

- (RYQuene *(^)(dispatch_block_t))setExcuteDoneBlock {
    return ^RYQuene* (dispatch_block_t doneBlock) {
        _excuteDoneBlock = doneBlock;
        return self;
    };
}

- (RYQuene *(^)(OperationWillStartBlock))setOperationWillStartBlock {
    return ^RYQuene* (OperationWillStartBlock willStartBlock) {
        _operationWillStartBlock = willStartBlock;
        return self;
    };
}

- (RYQuene *(^)(NSUInteger))setMaxConcurrentOperationCount {
    return ^RYQuene* (NSUInteger count) {
        NSCParameterAssert(count > 0);
        __weak typeof(self) wSelf = self;
        ry_lock(self, kSetMaxConcurrentOperationCountLock, NO, ^{
            __strong typeof(wSelf) sSelf = wSelf;
            if (count == sSelf.maxConcurrentOperationCount) {
                return;
            }
            if (sSelf->_isExcuting && nil != sSelf->_excuteQuene && nil != sSelf->_handle_concurrent_semaphore) {
                dispatch_suspend(sSelf->_excuteQuene);
                BOOL increase = count > sSelf.maxConcurrentOperationCount;
                for (NSUInteger i = sSelf.maxConcurrentOperationCount; i != count; increase ? ++i : --i) {
                    increase ? dispatch_semaphore_signal(sSelf->_handle_concurrent_semaphore) : dispatch_semaphore_wait(sSelf->_handle_concurrent_semaphore, DISPATCH_TIME_FOREVER);
                }
                dispatch_resume(sSelf->_excuteQuene);
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
    __weak typeof(self) wSelf = self;
    _excuteQuene = ry_lock(self, kQueneExcuteLock, !_sync, ^{
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
            dispatch_queue_t excute_quene = CREATE_DISPATCH_CONCURRENT_QUEUE(wSelf);
            
            dispatch_semaphore_t excute_done_semp = dispatch_semaphore_create(0);
            
            static void (^handleExcute)(RYOperation *);
            if (nil == handleExcute) {
                handleExcute = ^(RYOperation *opt) {
                    if (nil != sSelf->_operationWillStartBlock) {
                        sSelf->_operationWillStartBlock(opt);
                    }
                    [opt excute:^{
                        dispatch_semaphore_signal(excute_done_semp);
                    }];
                    NSArray<RYDependencyRelation *> *relations = opt.isRelierRelations;
                    [relations enumerateObjectsUsingBlock:^(RYDependencyRelation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                        if (nil != obj.demander) {
                            handleExcute(obj.demander);
                        }
                    }];
                };
            }
            
            dispatch_apply(notDemanderSet.count, excute_quene, ^(size_t index) {
                dispatch_semaphore_wait(excute_max_operation_count_semp, DISPATCH_TIME_FOREVER);
                handleExcute(sortedNotDemanderArray[index]);
                dispatch_semaphore_signal(excute_max_operation_count_semp);
            });
            
            for (NSUInteger i = 0; i < sSelf->_operationSet.count; ++i) {
                dispatch_semaphore_wait(excute_done_semp, DISPATCH_TIME_FOREVER);
            }
            
            sSelf->_isExcuting = NO;
            sSelf->_isFinished = YES;
            if (nil != _excuteDoneBlock) {
                _excuteDoneBlock();
            }
        }
    });
}

- (RYQuene *(^)())excute {
    return _excuteBlock;
}

- (void)cancel {
    if (_isCancelled) {
        return;
    }
    __weak typeof(self) wSelf = self;
    ry_lock(self, kCancelAllOperationsLock, NO, ^{
        __strong typeof(wSelf) sSelf = wSelf;
        if (sSelf->_isExcuting && nil != sSelf->_excuteQuene) {
            dispatch_suspend(sSelf->_excuteQuene);
        }
        NSArray<RYOperation *> *operations = sSelf->_operationSet.allObjects;
        dispatch_apply(operations.count, CREATE_DISPATCH_CONCURRENT_QUEUE(sSelf), ^(size_t index) {
            RYOperation *opt = operations[index];
            [opt cancel];
        });
        sSelf->_isCancelled = YES;
        if (sSelf->_isExcuting && nil != sSelf->_excuteQuene) {
            dispatch_resume(sSelf->_excuteQuene);
        }
    });
}

- (BOOL)isCancelled {
    return _isCancelled;
}

@end



