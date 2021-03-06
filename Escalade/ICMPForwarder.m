//
//  ICMPForwarder.m
//  Escalade
//
//  Created by simpzan on 2018/7/22.
//

#import "ICMPForwarder.h"
#import "TCPPacket.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#import "Log.h"

typedef struct {
    uint8_t     type;
    uint8_t     code;
    uint16_t    checksum;
    uint16_t    identifier;
    uint16_t    sequenceNumber;
    // data...
} ICMPHeader;

NSString *getAddressFull(struct sockaddr_storage *addr) {
    char address[INET6_ADDRSTRLEN] = { 0 };
    struct sockaddr_in *sin = (struct sockaddr_in *)addr;
    inet_ntop(sin->sin_family, &(sin->sin_addr), address, INET6_ADDRSTRLEN);
    return [[NSString alloc] initWithUTF8String:address];
}

NSData *receiveICMP(int fd) {
    const int maxSize = 65535;
    static char buffer[maxSize];
    struct sockaddr_storage addr;
    socklen_t addrLen = sizeof(addr);
    ssize_t bytesRead = recvfrom(fd, buffer, maxSize, 0, (struct sockaddr *)&addr, &addrLen);
    if (bytesRead == -1 && errno == EBADF) {
        DDLogDebug(@"fd is closed, exiting this thread.");
        return NULL;
    }
    if (bytesRead == -1) {
        DDLogError(@"recvfrom failed, %d %s.", errno, strerror(errno));
        return NULL;
    }
    DDLogDebug(@"ICMPForwarder received %zd bytes from %@", bytesRead, getAddressFull(&addr));
    return [NSData dataWithBytes:buffer length:bytesRead];
}
BOOL sendICMP(NSData *packet, int fd, NSString *ip, int ttl) {
    in_addr_t inaddr = inet_addr(ip.UTF8String);
    if (inaddr == INADDR_NONE) {
        DDLogError(@"invalid destination %@, %s", ip, strerror(errno));
        return NO;
    }
    int result = setsockopt(fd, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));
    if (result != 0) DDLogError(@"failed to set ttl to %d, %s.", ttl, strerror(errno));
    
    struct sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = inaddr;
    struct sockaddr *addr = (struct sockaddr *)&address;
    ssize_t sent = sendto(fd, packet.bytes, packet.length, 0, addr, sizeof(address));
    if (sent == -1) DDLogError(@"sendto fd:%d, ip:%@ ttl:%d, packet:%@ failed, %s", fd, ip, ttl, packet, strerror(errno));
    DDLogDebug(@"ICMPForwarder sent %zd bytes to %@", sent, ip);
    return sent == packet.length;
}

NSString *getRealIpAddress(NSString *fakeIp) {
    DNSServer *server = [DNSServer currentServer];
    NSString *originalIp = [server lookupOriginalIP:fakeIp];
    return originalIp ? originalIp : fakeIp;
}

@implementation ICMPForwarder {
    int _fd;
    NSThread *_readThread;
    NSLock *_lock;
}

@synthesize outputFunc;

- (BOOL)inputWithPacket:(NSData * _Nonnull)data version:(NSNumber * _Nullable)version {
    TCPPacket *packet = [[TCPPacket alloc]initWithData:data];
    if (packet.protocol != 1) return NO;

    NSRange range = NSMakeRange(packet.ipHeaderSize, data.length - packet.ipHeaderSize);
    NSData *icmpData = [data subdataWithRange:range];
    ICMPHeader *header = (ICMPHeader *)[icmpData bytes];
    int destinationUnreachable = 3, portUnreachable = 3;
    if (header->type == destinationUnreachable && header->code == portUnreachable) {
        DDLogWarn(@"ignoring port unreachable icmp message, %@.", icmpData);
        return YES;
    }
    
    NSString *originalIp = getRealIpAddress(packet.destinationAddress);
    BOOL result = sendICMP(icmpData, _fd, originalIp, packet.timeToLive);
    if (!result) DDLogError(@"ICMPForwarder, failed to send %@", packet);
    return result;
}

- (void)readLoop {
    [_lock lock];
    while (!_readThread.cancelled) {
        NSData *reply = receiveICMP(_fd);
        if (reply) outputFunc(@[reply], @[@AF_INET]);
    }
    [_lock unlock];
}

- (void)start {
    _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    _lock = [[NSLock alloc] init];
    _readThread = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:NULL];
    [_readThread start];
}

- (void)stop {
    [_readThread cancel];
    close(_fd);
    [_lock lock];
    [_lock unlock];
    _lock = NULL;
    _readThread = NULL;
}

@end
