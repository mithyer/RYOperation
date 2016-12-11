# RYOperation

###e.g. ry_lock
    static const void *const kLockId = &kLockId;
    static const size_t max = 100000;
    __block size_t t = 0, a = 0, b = 0;
    
    
    dispatch_group_t group_t = dispatch_group_create();
    
    dispatch_group_enter(group_t);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < max; ++i) {
            ry_lock(nil, kLockId, YES, ^{
                ++t;
            });
        }
        ry_lock(nil, kLockId, YES, ^{
            dispatch_group_leave(group_t);
        });
    });

    dispatch_group_enter(group_t);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < 100000; ++i) {
            ry_lock(nil, kLockId, NO, ^{
                ++t;
            });
        }
        dispatch_group_leave(group_t);
    });
    
    dispatch_group_notify(group_t, dispatch_get_main_queue(), ^{
        // t == max * 2
    });

###e.g. operation dependency and cancel

    RYOperation *opt1, *opt2, *opt3, *opt4;
    RYQueue.createWithOperation(opt1 = RYOperation.createWithBlock(^{
        sleep(1);
        RYLog(@"1");
    }).setName(@"opt1")).addOperation(opt2 = RYOperation.createWithBlock(^{
        sleep(1);
        RYLog(@"2");
    }).setName(@"opt2")).addOperation(opt3 = RYOperation.createWithBlock(^{
        sleep(1);
        RYLog(@"3");
    }).setName(@"opt3")).addOperation(opt4 = RYOperation.createWithBlock(^{
        sleep(1);
        RYLog(@"4");
    }).setName(@"opt4")).setBeforeExcuteBlock(^{
        RYLog(@"before");
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
        opt2.addDependency(opt4);
        opt3.addDependency(opt4);
    }).setOperationWillStartBlock(^(RYOperation *opt) {
        if ([opt.name isEqualToString:@"opt2"]) {
            [opt cancel];
        }
    }).setExcuteDoneBlock(^{
        RYLog(@"done");
        // before, 5, 4, 3, done
    }).excute();
    
    RYLog(@"5");
    
    


###e.g. operation dependency between two queue
    
    
    RYOperation *opt1, *opt2;
    RYQueue *queue1 = RYQueue.createWithOperation(opt1 = RYOperation.createWithBlock(^{
        sleep(1);
        RYLog(@"1");
    })).setExcuteDoneBlock(^{
        RYLog(@"done1");
        // 3, 2, done2, 1, done1
    });
    
    opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    }).setMinWaitTimeForOperate(3 * NSEC_PER_SEC);
    
    RYQueue *queue2 = RYQueue.create.addOperation(opt2).setExcuteDoneBlock(^{
        RYLog(@"done2");
    });
    
    opt1.addDependency(opt2);
    
    RYLog(@"3");

    queue1.excute();
    queue2.excute();
    
    
###e.g. queue cancel
    RYOperation *opt1, *opt2, *opt3;
    
    opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
        sleep(1);
    }).setName(@"opt1");
    
    opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
        sleep(1);
    }).setName(@"opt2");
    
    opt3 = RYOperation.createWithBlock(^{
        RYLog(@"3");
        sleep(1);
    }).setName(@"opt3");
    
    opt1.addDependency(opt2.addDependency(opt3));
    
    RYQueue *queue = RYQueue.create.addOperations(@[opt1, opt2, opt3]).setExcuteDoneBlock(^{
        RYLog(@"done");
        // 3, 2, done
    });
    
    queue.excute();
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [queue cancel];
    });
    
    
###e.g. suspend
    RYOperation *opt1, *opt2;
    
    opt1 = RYOperation.createWithBlock(^{
        RYLog(@"1");
        sleep(1);
    });
    
    opt2 = RYOperation.createWithBlock(^{
        RYLog(@"2");
    });
    
    RYQueue *queue = RYQueue.create.addOperations(@[opt1, opt2]).setExcuteDoneBlock(^{
        RYLog(@"done");
        // 1, bs, br, 2, done
    }).setBeforeExcuteBlock(^{
        opt2.addDependency(opt1);
    }).excute();
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"bs");
        [queue suspend];

    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RYLog(@"br");
        [queue resume];
    });
