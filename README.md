# RYOperation

    RYOperation *opt1, *opt2, *opt3, *opt4;
    RYQuene.createWithOperation(opt1 = RYOperation.createWithBlock(^{
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