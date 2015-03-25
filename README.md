## MGJRequestManager 是什么
MGJRequestManager 是一款基于 AFNetwokring 2.0+ 的 iOS 网络库。

一般在做项目时，我们都会在 AFNetworking 的基础上再封装一层，加入一些业务逻辑，然后作为统一的 API 层。细分下来的话，功能点其实不多，且相对固定和通用，就索性把这些常用的功能统一处理，并提供灵活的使用方式，于是就有了 MGJRequestManager。

## MGJRequestManager 的优势
### [Eat your own dog food](http://en.wikipedia.org/wiki/Eating_your_own_dog_food)
MGJRequestManager 目前被用在「[蘑菇街](http://www.mogujie.com)」，「[小店](http://www.xiaodian.com/pc/download)」等 App 中，已稳定运行了一段时间。

### 强大
以「蘑菇街」为例，统计这块会计算请求消耗的时间、每次请求都要发送的参数、据请求参数的值计算 token、缓存请求以便快速呈现等等，MGJRequestManager 都可以比较方便地搞定。

#### 主要功能
* 缓存GET请求（可以方便地开启/关闭）
* 设置 Builtin 参数（每次请求都会带上的参数，如设备型号等）
* 符合某种（自定义）条件时，可以不发送请求（比如用户多次点击「喜欢」按钮）
* 对请求结果做预处理（比如将服务端返回的数据包装成统一的格式）
* 串行发送多个请求（比如 token 过期后，可以将请求新 token 和当前请求串起来）
* 并行发送多个请求，可以告知请求完成数，以及全部请求完成后调用某个 callback
* 发送请求时显示 loading，发送完成后隐藏 loading
* 上传图片
* 取消正在发送的请求


### 灵活
因为需求经常会变，所以架构需要非常灵活才能方便应对新功能，比如「发送请求时显示 loading，发送完成后隐藏 loading」这个只是利用了现成的接口实现的一个特性。一些常见的需求都可以通过对 MGJRequestManager 进行配置来实现。

## 思想
本着「everything should be as simple as possible, but not simpler」的原则，设计这个类库时，希望使用起来和理解起来尽量方便，同时又足够灵活，可以应付大多数的场景。

主要分为两部分 `MGJRequestManagerConfiguration` 和 `MGJRequestManager`，前者做一些自定义配置，比如请求发送前/后的预处理，baseURL，userInfo等。后者记录下这些信息，在适当的时候消费它们，同时支持针对某些特殊请求做自定义配置。

That's It!

## 演示
![](http://ww3.sinaimg.cn/large/afe37136gw1eqi6vj4g6bg207g0dctl6.gif)

## 使用

以「发送请求时显示 loading，发送完成后隐藏 loadin」为例

```objc
// 1
MGJRequestManagerConfiguration *configuration = [[MGJRequestManagerConfiguration alloc] init];

UIActivityIndicatorView *indicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
indicatorView.frame = CGRectMake(self.view.frame.size.width / 2 - 8, self.view.frame.size.height / 2 - 8, 16, 16);
[self.view addSubview:indicatorView];

// 2
configuration.requestHandler = ^(AFHTTPRequestOperation *operation, id userInfo, BOOL *shouldStopProcessing) {
	if (userInfo[@"showLoading"]) {
		[indicatorView startAnimating];
	}
};

// 3
configuration.responseHandler = ^(AFHTTPRequestOperation *operation, id userInfo, MGJResponse *response, BOOL *shouldStopProcessing) {
	if (userInfo[@"showLoading"]) {
		[indicatorView stopAnimating];
	}
};

[MGJRequestManager sharedInstance].configuration = configuration;

// 4
[[MGJRequestManager sharedInstance] GET:@"http://httpbin.org/delay/2"
							 parameters:nil
					   startImmediately:YES // 5
				   configurationHandler:^(MGJRequestManagerConfiguration *configuration){
					   configuration.userInfo = @{@"showLoading": @YES}; // 6
				   } completionHandler:^(NSError *error, id<NSObject> result, BOOL isFromCache, AFHTTPRequestOperation *operation) {
					   [self appendLog:result.description]; // 7
				   }];

```

1. `MGJRequestManager` 要配合 `MGJRequestManagerConfiguration` 才能发挥出威力。这个 configuration 可以配置 `baseURL`, `requestHandler`, `responseHandler` 等信息，可变部分一般是通过对 `MGJRequestManagerConfiguration` 进行配置来实现的。可以全局设置一个 configuration，然后单独发送请求时还可以覆盖默认设置。
2. `requestHandler` 这个 block 会在请求发送前被触发，`userInfo` 这个参数时 `configuration` 这个实例的一个属性，方便起见，作为参数传给了 `requestHandler`。还有一个重要的参数时 `*shouldStopProcessing`，如果在这个 block 里，它被设置为了 `YES`，那么这个请求将不会被发送。
3. `responseHandler` 这个 block 会在收到服务端的响应后被触发，`response` 参数有 `error` 和 `result` 两个属性，服务端返回的数据都被放到了 `result` 属性里，在这里可以对它进行解析，然后重新设置 response。如果 `*shouldStopProcessing` 被设置为了 `YES`，那么 `completionHandler` 就不会被触发。
4. POST/PUT/DELETE 只需把 GET 换成对应的 HTTP Method 即可。
5. `startImmediately` 如果设为 `NO`，那么这个请求不会被发送，可以将来通过调用 `-[MGJRequestManager startOperation:]` 来发送，或者也可以放到队列里。
6. 这里会传入默认的 configuration，如果需要在这个请求做一些个性化设置，可以修改 configuration 里相应地配置。
7. 这里的 `result` 就是 `-[MGJResponse result]`, `error` 是 `-[MGJResponse error]`, `isFromCache` 表示这个结果是否来自缓存。

## 协议
MGJRequestManager 被许可在 MIT 协议下使用。查阅 LICENSE 文件来获得更多信息。
