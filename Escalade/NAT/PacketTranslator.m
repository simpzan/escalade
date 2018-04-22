//
//  PacketTranslator.m
//  Escalade
//
//  Created by simpzan on 22/04/2018.
//

#import "PacketTranslator.h"
#import "TCPPacket.h"
#import "HostEndpoint.h"

static PacketTranslator *gInstance = nil;

@implementation PacketTranslator {
    uint16_t _proxyServerPort;
    NSString *_proxyServerIp;
    NSString *_fakeSourceIp;
    NSString *_interfaceIp;
    
    NSMutableDictionary *_map;
}

- (HostEndpoint *)getOriginalEndpoint:(uint16_t)port {
    return _map[@(port)];
}

- (instancetype)initWithInterfaceIp:(NSString *)interfaceIp fakeSourceIp:(NSString *)fakeSourceIp proxyServerIp:(NSString *)proxyServerIp port:(uint16_t)port {
    self = [super init];
    _proxyServerPort = port;
    _proxyServerIp = proxyServerIp;
    _fakeSourceIp = fakeSourceIp;
    _interfaceIp = interfaceIp;
    _map = [NSMutableDictionary dictionary];
    return self;
}

- (NSData *)translatedPacket:(NSData *)data {
    TCPPacket *packet = [[TCPPacket alloc]initWithData:data];
    NSString *originalPacket = packet.description;
    
    if (![packet.sourceAddress isEqualToString:_interfaceIp]) {
        NSLog(@"Does not know how to handle packet: %@", originalPacket);
        return nil;
    }
    if (packet.protocol == 17) {
        NSString *str = [[NSString alloc]initWithData:packet.udpData encoding:NSUTF8StringEncoding];
        NSLog(@"udp data %@", str);
        return nil;
    }
    if (packet.protocol != 6) {
        NSLog(@"unknown protocol %d, %@", (int)packet.protocol, originalPacket);
        return nil;
    }
    
    NSString *direction = nil;
    if (packet.sourcePort == _proxyServerPort) {
        // load
        NSNumber *destinationPort = @(packet.destinationPort);
        HostEndpoint *endpoint = _map[destinationPort];
        packet.sourcePort = endpoint.port;
        packet.sourceAddress = endpoint.hostname;
        packet.destinationAddress = _interfaceIp;
        direction = @"response";
    } else {
        // save
        NSNumber *sourcePort = @(packet.sourcePort);
        _map[sourcePort] = [HostEndpoint endpointWithHostname:packet.destinationAddress port:packet.destinationPort];
        packet.sourceAddress = _fakeSourceIp;
        packet.destinationAddress = _proxyServerIp;
        packet.destinationPort = _proxyServerPort;
        direction = @"request";
    }
    NSLog(@"%@ %@ translated to %@", direction, originalPacket, packet.description);
    return packet.raw;
}

- (BOOL)inputWithPacket:(NSData * _Nonnull)packet version:(NSNumber * _Nullable)version {
    NSData *translated = [self translatedPacket:packet];
    if (!translated) return NO;
    
    outputFunc(@[translated], @[version]);
    return YES;
}

- (void)start {
    
}

- (void)stop {
    
}

+ (void)setInstance:(PacketTranslator *)instance {
    NSLog(@"translator %p -> %p", gInstance, instance);
    gInstance = instance;
}
+ (PacketTranslator *)getInstance {
    NSLog(@"return instance %p", gInstance);
    return gInstance;
}

@synthesize outputFunc;

@end

