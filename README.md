# RYOperation

###example0

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


###example1
    
    
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