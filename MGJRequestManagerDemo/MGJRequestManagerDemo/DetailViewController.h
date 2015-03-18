//
//  DetailViewController.h
//  MGJRequestManagerDemo
//
//  Created by limboy on 3/18/15.
//  Copyright (c) 2015 juangua. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DetailViewController : UIViewController

@property (strong, nonatomic) id detailItem;
@property (weak, nonatomic) IBOutlet UILabel *detailDescriptionLabel;

@end

