# RYOperation

###e.g.0 operation dependency and cancel

    RYOperation *opt1, *opt2, *opt3, *opt4;
    RYQueue.createWithOperation(opt1 = RYOperation.createWithBlock(^{
        sleep(1);
        NSLog(@"1");
    }).setName(@"opt1")).addOperation(opt2 = RYOperation.createWithBlock(^{
        sleep(1);
        NSLog(@"2");
    }).setName(@"opt2")).addOperation(opt3 = RYOperation.createWithBlock(^{
        sleep(1);
        NSLog(@"3");
    }).setName(@"opt3")).addOperation(opt4 = RYOperation.createWithBlock(^{
        sleep(1);
        NSLog(@"4");
    }).setName(@"opt4")).setBeforeExcuteBlock(^{
        NSLog(@"before");
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
        opt2.addDependency(opt4);
        opt3.addDependency(opt4);
    }).setOperationWillStartBlock(^(RYOperation *opt) {
        if ([opt.name isEqualToString:@"opt2"]) {
            [opt cancel];
        }
    }).setExcuteDoneBlock(^{
        NSLog(@"done");
    }).excute();
    
    NSLog(@"5");


###e.g.1 operation dependency between two queue
    
    
    RYOperation *opt1, *opt2;
    RYQueue *queue1 = RYQueue.createWithOperation(opt1 = RYOperation.createWithBlock(^{
        sleep(1);
        NSLog(@"1");
    })).setExcuteDoneBlock(^{
        NSLog(@"done1");
    });
    
    opt2 = RYOperation.createWithBlock(^{
        NSLog(@"2");
    }).setMinusWaitTimeForOperate(3 * NSEC_PER_SEC);
    
    RYQueue *queue2 = RYQueue.create.addOperation(opt2).setExcuteDoneBlock(^{
        NSLog(@"done2");
    });
    
    opt1.addDependency(opt2);
    
    queue1.excute();
    queue2.excute();
    
    NSLog(@"3");
    
 
###e.g.2 priority
    RYOperation *opt1, *opt2, *opt3;
    
    opt1 = RYOperation.createWithBlock(^{
        NSLog(@".1");
        sleep(1);
        NSLog(@"1");
    }).setName(@"opt1").setPriority(kRYOperationPriorityLow);
    
    opt2 = RYOperation.createWithBlock(^{
        NSLog(@".2");
        sleep(1);
        NSLog(@"2");
    }).setName(@"opt2").setPriority(kRYOperationPriorityHigh);
    
    opt3 = RYOperation.createWithBlock(^{
        NSLog(@".3");
        sleep(1);
        NSLog(@"3");
    }).setName(@"opt3").setPriority(kRYOperationPriorityNormal);
    
    RYQueue *queue = RYQueue.create.addOperations(@[opt1, opt2, opt3]);
    
    queue.excute();
    
    
###e.g.3 queue cancel
    RYOperation *opt1, *opt2, *opt3;
    
    opt1 = RYOperation.createWithBlock(^{
        NSLog(@".1");
        sleep(1);
        NSLog(@"1");
    }).setName(@"opt1");
    
    opt2 = RYOperation.createWithBlock(^{
        NSLog(@".2");
        sleep(1);
        NSLog(@"2");
    }).setName(@"opt2");
    
    opt3 = RYOperation.createWithBlock(^{
        NSLog(@".3");
        sleep(1);
        NSLog(@"3");
    }).setName(@"opt3");
    
    opt1.addDependency(opt2.addDependency(opt3));
    
    RYQueue *queue = RYQueue.create.addOperations(@[opt1, opt2, opt3]).setExcuteDoneBlock(^{
        NSLog(@"done");
    });
    
    queue.excute();
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [queue cancel];
    });
    
   
###e.g.4 ry_lock
    static const NSInteger kLockId = 1;
    static size_t t = 0;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < 100000; ++i) {
            ry_lock(self, kLockId, YES, ^{
                ++t;
            });
        }
        ry_lock(self, kLockId, YES, ^{
            NSLog(@"%zd", t);
        });

    });
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (size_t i = 0; i < 100000; ++i) {
            ry_lock(self, kLockId, NO, ^{
                ++t;
            });
        }
        NSLog(@"%zd", t);
    });


    // one of these two will log 200000