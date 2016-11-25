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

@class RYQuene;
@interface RYOperation : NSObject

+ (RYOperation *(^)(dispatch_block_t))create;
- (RYOperation *(^)(RYOperation *))addDependency;
- (RYOperation *(^)(NSString *))setName;
- (RYOperation *(^)(RYOperationPriority))setPriority;

- (void)cancel;

- (BOOL)isCancelled;
- (BOOL)isReady;
- (BOOL)isExcuting;
- (BOOL)isFinished;

@end

@interface RYQuene : NSObject

+ (RYQuene *)create;

- (RYQuene *(^)(RYOperation *))addOperation;
- (RYQuene *(^)(NSArray<RYOperation *> *))addOperations;
- (RYQuene *(^)(NSInteger ))setIdentifier;
- (RYQuene *(^)(BOOL async /* default: YES */))setAsync;
- (RYQuene *(^)(NSUInteger))setMaxConcurrentOperationCount;
- (RYQuene *(^)(dispatch_block_t))setBeforeExcuteBlock;
- (RYQuene *(^)(dispatch_block_t))setExcuteDoneBlock;
- (RYQuene *(^)())excute;

- (NSSet<RYOperation *> *(^)(NSString *))operationsForName;
- (void)cancelAllOperations;

- (BOOL)isCancelled;

@end


dispatch_queue_t ry_lock(id holder, NSUInteger lockId, BOOL async, dispatch_block_t lockedBlock);
