//
//  RYOperationTests.m
//  RYOperationTests
//
//  Created by ray on 16/12/7.
//  Copyright © 2016年 ray. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "RYOperation.h"

#ifdef RYLog
#undef RYLog
#endif

static const void *const klogHolderKey = &klogHolderKey;
static NSMutableArray *s_logArr = nil;

void RYLog(NSString *log) {
    ry_lock(nil, klogHolderKey, YES, ^(id holder){
        if (nil == s_logArr) {
            s_logArr = [NSMutableArray array];
        }
        [s_logArr addObject:log];
    });
}

void RYLogClear() {
    ry_lock(nil, klogHolderKey, YES, ^(id holder){
        if (nil != s_logArr) {
            [s_logArr removeAllObjects];
        }
    });
}

NSArray<NSString *> *RYGetLog() {
    __block NSArray<NSString *> *logs = nil;
    ry_lock(nil, klogHolderKey, NO, ^(id holder){
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
    static const void *const kLockId = &kLockId;
    static const size_t max = 100000;
    __block size_t t = 0;
    
    
    dispatch_group_t group_t = dispatch_group_create();
    
    dispatch_group_enter(group_t);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < max; ++i) {
            ry_lock(nil, kLockId, YES, ^(id holder){
                ++t;
            });
        }
        ry_lock(nil, kLockId, YES, ^(id holder){
            dispatch_group_leave(group_t);
        });
    });

    dispatch_group_enter(group_t);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < max; ++i) {
            ry_lock(nil, kLockId, NO, ^(id holder){
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

- (void)test_dependency {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYOperation *opt1, *opt2, *opt3, *opt4 ,*opt5;
    RYQueue.createWithOperation(opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
    })).addOperation(opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    })).addOperation(opt3 = RYOperation.createWithBlock(^{
        RYLog(@"3");
    })).addOperation(opt4 = RYOperation.createWithBlock(^{
        RYLog(@"4");
    })).addOperation(opt5 = RYOperation.createWithBlock(^{
        RYLog(@"5");
    })).setBeforeExcuteBlock(^(RYQueue *queue){
        RYLog(@"before");
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
        opt2.addDependency(opt4);
        opt3.addDependency(opt4);
        opt4.addDependency(opt5);
    }).setExcuteDoneBlock(^(RYQueue *queue){
        RYLog(@"done");
        [expt fulfill];
    }).excute();
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"before", @"5", @"4", @"3", @"2", @"1", @"done"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

- (void)test_dependency_between_two_queue {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    
    dispatch_group_t group_t = dispatch_group_create();
    
    dispatch_group_enter(group_t);
    dispatch_group_enter(group_t);
    
    dispatch_group_notify(group_t, dispatch_get_main_queue(), ^{
        [expt fulfill];
    });

    
    RYOperation *opt1, *opt2, *opt3, *opt4 ,*opt5;
    RYQueue *queue1 = RYQueue.create.addOperation(opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
    })).addOperation(opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    })).addOperation(opt3 = RYOperation.createWithBlock(^{
        RYLog(@"3");
    })).setExcuteDoneBlock(^(RYQueue *queue){
        dispatch_group_leave(group_t);
    });
    
    RYQueue *queue2 = RYQueue.create.addOperation(opt4 = RYOperation.createWithBlock(^{
        RYLog(@"4");
    })).addOperation(opt5 = RYOperation.createWithBlock(^{
        RYLog(@"5");
    })).setExcuteDoneBlock(^(RYQueue *queue){
        dispatch_group_leave(group_t);
    });
    
    opt1.addDependency(opt2);
    opt2.addDependency(opt3);
    opt2.addDependency(opt4);
    opt3.addDependency(opt4);
    opt4.addDependency(opt5);
    
    RYLog(@"before");

    queue1.excute();
    queue2.excute();
    
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"before", @"5", @"4", @"3", @"2", @"1"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

- (void)test_operation_cancel {
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYOperation *opt1, *opt2, *opt3;
    RYQueue.create.addOperation(opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
    })).addOperation(opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    })).addOperation(opt3 = RYOperation.createWithBlock(^{
        RYLog(@"3");
    })).setBeforeExcuteBlock(^(RYQueue *queue){
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
    }).setOperationWillStartBlock(^(RYQueue *queue, RYOperation *opt){
        if (opt == opt1) {
            [opt cancel];
        }
    }).setExcuteDoneBlock(^(RYQueue *queue){
        if (opt1.isCancelled) {
            RYLog(@"done");
        }
        [expt fulfill];
    }).excute();
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"3", @"2", @"done"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

- (void)test_queue_cancel {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYOperation *opt1, *opt2, *opt3;
    RYQueue.create.addOperation(opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
    })).addOperation(opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    })).addOperation(opt3 = RYOperation.createWithBlock(^{
        RYLog(@"3");
    })).setBeforeExcuteBlock(^(RYQueue *queue){
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
    }).setOperationWillStartBlock(^(RYQueue *queue, RYOperation *opt){
        if (opt == opt1) {
            [queue cancel];
        }
    }).setExcuteDoneBlock(^(RYQueue *queue){
        if (queue.isCancelled) {
            RYLog(@"done");
        }
        [expt fulfill];
    }).excute();
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"3", @"2", @"done"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

- (void)test_suspend {
    
    XCTestExpectation *expt = [self expectationWithDescription:NSStringFromSelector(_cmd)];
    RYLogClear();
    
    RYOperation *opt1, *opt2;
    
    opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
        sleep(1);
    });
    
    opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    });
    
    RYQueue *queue = RYQueue.create.addOperations(@[opt1, opt2]).setExcuteDoneBlock(^(RYQueue *queue){
        RYLog(@"done");
        [expt fulfill];
    }).setBeforeExcuteBlock(^(RYQueue *queue){
        opt2.addDependency(opt1);
    }).excute();
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"bs");
        [queue suspend];

    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"br");
        [queue resume];
    });
    
    [self waitForExpectationsWithTimeout:5 handler:^(NSError * _Nullable error) {
        NSArray *expectRes = @[@"1", @"bs", @"br", @"2", @"done"];
        XCTAssert([RYGetLog() isEqualToArray:expectRes]);
    }];
}

/*
- (void)testPerformanceExample {
    // This is an example of a performance test case.
    [self measureBlock:^{
        // Put the code you want to measure the time of here.
    }];
}
*/

@end
