# RYOperation
The RYOperation class is an abstract class which is similar to NSOperation, withing more powerful features and convenient usage.

It is based on GCD.

How to use -> see [test codes](https://github.com/mithyer/RYOperation/blob/master/RYOperationTests/RYOperationTests.m)


基于GCD的仿NSOperation的多线程类，精简的同时增加了一些方法，使用起来更方便，功能上更强大。

通过单元测试了解如何使用^_^ -> [test codes](https://github.com/mithyer/RYOperation/blob/master/RYOperationTests/RYOperationTests.m)

### 1.0.2
1.增加qos支持

2.operation完成回调改为无论finish或cancel在结束后都会回调

### 1.0.1
1.增加设置queue最大并发处理数方法

2.增加operation调用结束的回调

### 1.0.0
1.摒弃链式语法

2.重构代码逻辑，修改方法名，修复bug

3.强化单元测试
