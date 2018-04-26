//
//  Log.m
//  CocoaLumberjack
//
//  Created by simpzan on 25/04/2018.
//

#import "Log.h"

static char getLevel(DDLogFlag flag) {
    switch (flag) {
        case DDLogFlagError    : return 'E';
        case DDLogFlagWarning  : return 'W';
        case DDLogFlagInfo     : return 'I';
        case DDLogFlagDebug    : return 'D';
        default                : return 'V';
    }
}

@interface ESLogFormatter : NSObject <DDLogFormatter>
@end

@implementation ESLogFormatter {
    NSDateFormatter *_formatter;
}

- (id)init {
    if (self = [super init]) {
        _formatter = [[NSDateFormatter alloc] init];
        [_formatter setDateFormat:@"MM-dd HH:mm:ss:SSS"];
    }
    return self;
}

- (NSString *)formatLogMessage:(DDLogMessage *)message {
    NSString *dateAndTime = [_formatter stringFromDate:message.timestamp];
    
    int pid = getpid();
    NSString *tid = message.threadID;
    
    char level = getLevel(message.flag);
    
    NSString *filename = message.fileName;
    int line = (int)message.line;
    
    NSString *msg = message.message;
    
    return [NSString stringWithFormat:@"%@ %d:%@ %c %@:%u | %@", dateAndTime, pid, tid, level, filename, line, msg];
}

@end

DDLogLevel ddLogLevel;

int _setupLog(DDLogLevel level) {
    ddLogLevel = level;
    DDTTYLogger *tty = [DDTTYLogger sharedInstance];
    tty.logFormatter = [[ESLogFormatter alloc] init];
    [DDLog addLogger:tty];
    
    DDASLLogger *asl = [DDASLLogger sharedInstance];
//    asl.logFormatter = [[ESLogFormatter alloc]init];
    [DDLog addLogger:asl];

    DDFileLogger *fileLogger = [[DDFileLogger alloc] init];
    fileLogger.logFormatter = [[ESLogFormatter alloc] init];
    fileLogger.rollingFrequency = 60 * 60 * 24; // 24 hour rolling
    fileLogger.logFileManager.maximumNumberOfLogFiles = 7;
    [DDLog addLogger:fileLogger];
    
    NSString *logFile = fileLogger.logFileManager.sortedLogFilePaths.firstObject;
    NSLog(@"logFile %@", logFile);
    return 0;
}

int setupLog(DDLogLevel level) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _setupLog(level);
    });
    return 0;
}
