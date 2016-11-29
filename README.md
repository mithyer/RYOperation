# RYOperation

    RYOperation *opt1, *opt2, *opt3, *opt4;
    RYQuene.create.addOperation(opt1 = RYOperation.create(^{
        sleep(1);
        NSLog(@"1");
    }).setName(@"opt1")).addOperation(opt2 = RYOperation.create(^{
        sleep(2);
        NSLog(@"2");
    }).setName(@"opt2")).addOperation(opt3 = RYOperation.create(^{
        sleep(3);
        NSLog(@"3");
    }).setName(@"opt3")).addOperation(opt4 = RYOperation.create(^{
        sleep(4);
        NSLog(@"4");
    }).setName(@"opt4")).setBeforeExcuteBlock(^{
        NSLog(@"before");
        opt1.addDependency(opt2);
        opt2.addDependency(opt3);
        opt2.addDependency(opt4);
        opt3.addDependency(opt4);
    }).setExcuteDoneBlock(^{
        NSLog(@"done");
    }).excute();
    
    NSLog(@"5");