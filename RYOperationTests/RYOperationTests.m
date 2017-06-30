//
//  RYOperationTests.m
//  RYOperationTests
//
//  Created by ray on 16/12/7.
//  Copyright © 2016年 ray. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "RYOperation.h"

static const void *const klogKey = &klogKey;
static NSMutableArray *s_logArr = nil;

void RYLog(NSString *log) {
    ry_lock(NSObject.class, klogKey, YES, ^(id holder){
        if (nil == s_logArr) {
            s_logArr = [NSMutableArray array];
        }
        [s_logArr addObject:log];
    });
}

void RYLogClear() {
    ry_lock(NSObject.class, klogKey, YES, ^(id holder){
        if (nil != s_logArr) {
            [s_logArr removeAllObjects];
        }
    });
}

NSArray<NSString *> *RYGetLog() {
    __block NSArray<NSString *> *logs = nil;
    ry_lock(NSObject.class, klogKey, NO, ^(id holder){
        logs = s_logArr;
    });
    return logs;
}


@interface RYOperationTests : XCTestCase

@end

@implementation RYOperationTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)test_rylock {
    size_t max = arc4random()%100000;
    __block size_t t = 0;
    
    
    dispatch_group_t group_t = dispatch_group_create();
    
    dispatch_group_enter(group_t);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < max; ++i) {
            ry_lock(NSObject.class, @selector(test_rylock), YES, ^(id holder){
                ++t;
            });
        }
        dispatch_group_leave(group_t);
    });

    dispatch_group_enter(group_t);
    dispatch_async(dispatch_queue_create(0, 0), ^{
        for (size_t i = 0; i < max; ++i) {
            ry_lock(NSObject.class, @selector(test_rylock), NO, ^(id holder){
                ++t;
            });
        }
        dispatch_group_leave(group_t);
    });
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    dispatch_group_notify(group_t, dispatch_get_main_queue(), ^{
        [expt fulfill];
    });
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        XCTAssert(t == max * 2);
    }];
}

- (void)test_one_to_one_dependency {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYQueue *queue = [[RYQueue alloc] init];
    NSMutableArray *exptArray = [NSMutableArray array];
    RYOperation *preOpt = nil;
    NSInteger count = arc4random()%100 + 2;
    for (size_t i = 0; i < count; ++i) {
        NSString *num = @(i).stringValue;
        [exptArray addObject:num];
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(num);
        }];
        if (nil != preOpt) {
            [opt addDependency:preOpt];
        }
        preOpt = opt;
        [queue addOperation:opt];
    }

    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:10 handler:^(NSError * _Nullable error) {
        XCTAssert([RYGetLog() isEqualToArray:exptArray]);
    }];
}

- (void)test_one_to_many_dependency {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYQueue *queue = [[RYQueue alloc] init];
    NSMutableArray *exptArray = [NSMutableArray array];
    NSInteger count = arc4random()%100 + 2;
    RYOperation *oneOpt = [RYOperation operationWithBlock:^{
        RYLog(@"one");
    }];
    [queue addOperation:oneOpt];
    for (size_t i = 0; i < count; ++i) {
        NSString *num = @(i).stringValue;
        [exptArray addObject:num];
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(num);
        }];
        [oneOpt addDependency:opt];
        [queue addOperation:opt];
    }
    
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:10 handler:^(NSError * _Nullable error) {
        NSArray *logs = RYGetLog();
        XCTAssert(logs.count == count + 1 && [logs.lastObject isEqualToString:@"one"]);
    }];
}

- (void)test_many_to_one_dependency {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYQueue *queue = [RYQueue queue];
    NSMutableArray *exptArray = [NSMutableArray array];
    NSInteger count = arc4random()%100 + 2;
    RYOperation *oneOpt = [RYOperation operationWithBlock:^{
        RYLog(@"one");
    }];
    [queue addOperation:oneOpt];
    for (size_t i = 0; i < count; ++i) {
        NSString *num = @(i).stringValue;
        [exptArray addObject:num];
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(num);
        }];
        [opt addDependency:oneOpt];
        [queue addOperation:opt];
    }
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:10 handler:^(NSError * _Nullable error) {
        NSArray *logs = RYGetLog();
        XCTAssert(logs.count == count + 1 && [logs.firstObject isEqualToString:@"one"]);
    }];
}

- (void)test_many_to_many_dependency {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    NSInteger count1 = arc4random()%50 + 1;
    NSInteger count2 = arc4random()%50 + 1;
    
    RYQueue *queue = [RYQueue queue];
    NSMutableArray<RYOperation *> *opts1 = [NSMutableArray array];
    NSMutableArray<RYOperation *> *opts2 = [NSMutableArray array];
    NSMutableArray *expt1Ary = [NSMutableArray array];
    NSMutableArray *expt2Ary = [NSMutableArray array];
    
    for (size_t i = 0; i < count1; ++i) {
        NSString *log = @(i).stringValue;
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(log);
        }];
        [opts1 addObject:opt];
        [queue addOperation:opt];
        [expt1Ary addObject:log];
    }
    for (size_t i = 0; i < count2; ++i) {
        NSString *log = @(i + 100).stringValue;
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(log);
        }];
        [opts2 addObject:opt];
        [queue addOperation:opt];
        [expt2Ary addObject:log];
    }

    for (size_t i = 0; i < 100; ++ i) {
        size_t idx = arc4random()%opts1.count;
        RYOperation *opt1 = [opts1 objectAtIndex:idx];
        idx = arc4random()%opts2.count;
        RYOperation *opt2 = [opts2 objectAtIndex:idx];
        [opt1 addDependency:opt2];
    }
    for (RYOperation *opt in opts1) {
        size_t idx = arc4random()%opts2.count;
        RYOperation *opt2 = [opts2 objectAtIndex:idx];
        [opt addDependency:opt2];
        if (opt != opts1.firstObject) {
            [opt addDependency:opts1.firstObject];
        }
    }

    
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:10 handler:^(NSError * _Nullable error) {
        NSArray *logArray = RYGetLog();
        logArray = [[logArray subarrayWithRange:NSMakeRange(logArray.count - expt1Ary.count, expt1Ary.count)] sortedArrayUsingComparator:^NSComparisonResult(NSString *  _Nonnull obj1, NSString *  _Nonnull obj2) {
            return [obj1 compare:obj2 options:NSNumericSearch];
        }];
        XCTAssert([logArray isEqualToArray:expt1Ary]);
    }];
}


- (void)test_dependency_with_several_queue {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    dispatch_group_t group_t = dispatch_group_create();

    NSMutableArray *exptArray = [NSMutableArray array];
    RYQueue *preQueue = nil;
    NSMutableSet *queues = [NSMutableSet set];
    RYOperation *preOpt = nil;
    NSInteger count = arc4random()%100;
    for (size_t i = 0; i < count; ++i) {
        NSString *num = @(i).stringValue;
        [exptArray addObject:num];
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(num);
        }];
        if (nil != preOpt) {
            [opt addDependency:preOpt];
        }
        preOpt = opt;
        if (nil == preQueue || arc4random() % 10 < 5) {
            preQueue = [RYQueue queue];
            dispatch_group_enter(group_t);
            preQueue.excuteDoneBlock = ^(RYQueue *queue) {
                dispatch_group_leave(group_t);
            };
            [queues addObject:preQueue];
        }
        [preQueue addOperation:opt];
    }
    [queues enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
        RYQueue *queue = obj;
        [queue excute];
    }];
    
    dispatch_group_notify(group_t, dispatch_get_main_queue(), ^{
        [expt fulfill];
    });
    
    [self waitForExpectationsWithTimeout:20 handler:^(NSError * _Nullable error) {
        XCTAssert([RYGetLog() isEqualToArray:exptArray]);
    }];
}

- (void)test_operation_cancel {
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    
    RYQueue *queue = [RYQueue queue];
    NSInteger count = arc4random()%50;
    NSMutableArray *exptArray = [NSMutableArray array];
    NSMutableArray<RYOperation *> *allDependencies = [NSMutableArray array];
    for (size_t i = 0; i < count; ++i) {
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(@(i).stringValue);
        }];
        NSString *log = [NSString stringWithFormat:@"d%zd", i];
        RYOperation *dependency = [RYOperation operationWithBlock:^{
            RYLog(log);
            [opt cancel];
        }];
        [exptArray addObject:log];
        [opt addDependency:dependency];
        [allDependencies addObject:dependency];
        [queue addOperation:opt];
        [queue addOperation:dependency];
    }
    [allDependencies enumerateObjectsUsingBlock:^(RYOperation * _Nonnull opt, NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx > 0) {
            [opt addDependency:allDependencies[idx - 1]];
        }
    }];
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        XCTAssert([RYGetLog() isEqualToArray:exptArray]);
    }];
}

- (void)test_queue_cancel {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    dispatch_group_t group_t = dispatch_group_create();
    
    RYQueue *queue1 = [RYQueue queue];
    RYQueue *queue2 = [RYQueue queue];
    NSMutableArray *exptArray = [NSMutableArray array];
    for (size_t i = 0; i < 100; ++i) {
        NSString *log = @(i).stringValue;
        RYOperation *opt = [RYOperation operationWithBlock:^{
            RYLog(log);
        }];
        if (arc4random()%2 == 0) {
            [queue1 addOperation:opt];
        } else {
            [exptArray addObject:log];
            [queue2 addOperation:opt];
        }
    }
    [queue1 cancelAllOperation];
    [queue1 excute];
    [queue2 excute];

    
    dispatch_group_enter(group_t);
    queue1.excuteDoneBlock = ^(RYQueue *queue) {
        dispatch_group_leave(group_t);
    };
    
    dispatch_group_enter(group_t);
    queue2.excuteDoneBlock = ^(RYQueue *queue) {
        dispatch_group_leave(group_t);
    };

    dispatch_group_notify(group_t, dispatch_get_main_queue(), ^{
        [expt fulfill];
    });
    
    [self waitForExpectationsWithTimeout:10 handler:^(NSError * _Nullable error) {
        NSArray *logArray = [RYGetLog() sortedArrayUsingComparator:^NSComparisonResult(NSString *  _Nonnull obj1, NSString *  _Nonnull obj2) {
            return [obj1 compare:obj2 options:NSNumericSearch];
        }];
        XCTAssert([logArray isEqualToArray:exptArray]);
    }];
}



- (void)test_suspend {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYOperation *opt1 = [RYOperation operationWithBlock:^{
        RYLog(@"1");
        sleep(1);
    }];

    RYOperation *opt2 = [RYOperation operationWithBlock:^{
        RYLog(@"2");
    }];
    
    RYQueue *queue = RYQueue.queue;
    [queue addOperation:opt1];
    [queue addOperation:opt2];
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        RYLog(@"done");
        [expt fulfill];
    };
    
    [opt2 addDependency:opt1];
    
    [queue excute];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"bs");
        [queue suspendAllOperation];

    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"br");
        [queue resumeAllOperation];
    });
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"1", @"bs", @"br", @"2", @"done"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

- (void)test_max_concurrent_operation {
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYQueue *queue = [RYQueue queue];
    queue.maximumConcurrentOperationCount = 5;
    size_t count = 50 + 50%arc4random();
    __block size_t max = 0;
    for (size_t i = 0; i < count; ++i) {
        RYOperation *opt = [RYOperation operationWithBlock:^{
            ry_lock(NSObject.class, @selector(test_max_concurrent_operation), NO, ^(id holder) {
                ++max;
            });
            RYLog(@(max).stringValue);
            ry_lock(NSObject.class, @selector(test_max_concurrent_operation), NO, ^(id holder) {
                --max;
            });
        }];
        [queue addOperation:opt];
    }
    queue.excuteDoneBlock = ^(RYQueue *queue) {
        [expt fulfill];
    };
    [queue excute];
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        __block BOOL success = YES;
        [RYGetLog() enumerateObjectsUsingBlock:^(NSString * _Nonnull log, NSUInteger idx, BOOL * _Nonnull stop) {
            if (log.integerValue > queue.maximumConcurrentOperationCount) {
                success = NO;
                *stop = YES;
            }
        }];
        success &= max == 0;
        XCTAssert(success);
    }];
}

@end
