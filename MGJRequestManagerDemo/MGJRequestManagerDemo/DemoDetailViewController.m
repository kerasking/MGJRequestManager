//
//  DemoDetailViewController.m
//  MGJRequestManagerDemo
//
//  Created by limboy on 3/20/15.
//  Copyright (c) 2015 juangua. All rights reserved.
//

#import "DemoDetailViewController.h"
#import "DemoListViewController.h"
#import "MGJRequestManager.h"

@interface DemoDetailViewController ()
@property (nonatomic) UITextView *resultTextView;
@end

@implementation DemoDetailViewController

+ (void)load
{
    DemoDetailViewController *detailViewController = [[DemoDetailViewController alloc] init];
    [DemoListViewController registerWithTitle:@"发送一个 GET 请求" handler:^UIViewController *{
        [detailViewController makeGETRequest];
        return detailViewController;
    }];
    
    [DemoListViewController registerWithTitle:@"发送一个可以缓存 GET 的请求" handler:^UIViewController *{
        [detailViewController makeCacheGETRequest];
        return detailViewController;
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:239.f/255 green:239.f/255 blue:244.f/255 alpha:1];
    [self.view addSubview:self.resultTextView];
    // Do any additional setup after loading the view.
}

- (void)appendLog:(NSString *)log
{
    NSString *currentLog = self.resultTextView.text;
    currentLog = [currentLog stringByAppendingString:[NSString stringWithFormat:@"\n----------\n%@", log]];
    self.resultTextView.text = currentLog;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    self.resultTextView.text = @"";
}

- (UITextView *)resultTextView
{
    if (!_resultTextView) {
        NSInteger padding = 20;
        NSInteger viewWith = self.view.frame.size.width;
        NSInteger viewHeight = self.view.frame.size.height - 64;
        _resultTextView = [[UITextView alloc] initWithFrame:CGRectMake(padding, padding + 64, viewWith - padding * 2, viewHeight - padding * 2)];
        _resultTextView.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1].CGColor;
        _resultTextView.layer.borderWidth = 1;
        _resultTextView.editable = NO;
        _resultTextView.contentInset = UIEdgeInsetsMake(-64, 0, 0, 0);
        _resultTextView.font = [UIFont systemFontOfSize:14];
        _resultTextView.textColor = [UIColor colorWithWhite:0.2 alpha:1];
        _resultTextView.contentOffset = CGPointZero;
    }
    return _resultTextView;
}

- (void)makeGETRequest
{
    [[MGJRequestManager sharedInstance] GET:@"http://httpbin.org/get" parameters:@{@"foo": @"bar"} startImmediately:YES
 configurationHandler:nil completionHandler:^(NSError *error, id<NSObject> result, BOOL isFromCache, AFHTTPRequestOperation *operation) {
     self.resultTextView.text = result.description;
 }];
}

- (void)makeCacheGETRequest
{
    AFHTTPRequestOperation *operation1 = [[MGJRequestManager sharedInstance]
                                          GET:@"http://httpbin.org/get"
                                          parameters:@{@"foo": @"bar"}
                                          startImmediately:NO
                                          configurationHandler:^(MGJRequestManagerConfiguration *configuration) {
                                              configuration.resultCacheDuration = 30;
                                          }
                                          completionHandler:^(NSError *error, id<NSObject> result, BOOL isFromCache, AFHTTPRequestOperation *operation) {
                                              [self appendLog:[NSString stringWithFormat:@"来自缓存:%@", isFromCache ? @"是" : @"否"]];
                                              [self appendLog:result.description];
                                          }];
    
    AFHTTPRequestOperation *operation2 = [[MGJRequestManager sharedInstance]
                                          GET:@"http://httpbin.org/get"
                                          parameters:@{@"foo": @"bar"}
                                          startImmediately:NO
                                          configurationHandler:^(MGJRequestManagerConfiguration *configuration) {
                                              configuration.resultCacheDuration = 30;
                                          }
                                          completionHandler:^(NSError *error, id<NSObject> result, BOOL isFromCache, AFHTTPRequestOperation *operation) {
                                              [self appendLog:[NSString stringWithFormat:@"来自缓存:%@", isFromCache ? @"是" : @"否"]];
                                              [self appendLog:result.description];
                                          }];
    
    
    [[MGJRequestManager sharedInstance] batchOfRequestOperations:@[operation1, operation2] progressBlock:^(NSUInteger numberOfFinishedOperations, NSUInteger totalNumberOfOperations) {
        [self appendLog:[NSString stringWithFormat:@"发送完成的请求：%ld/%ld", numberOfFinishedOperations, totalNumberOfOperations]];
    } completionBlock:^() {
        [self appendLog:@"请求发送完成"];
    }];
}

@end
