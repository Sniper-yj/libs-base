#import "Foundation/Foundation.h"
#include <objc/runtime.h>

#import "ObjectTesting.h"

#ifndef  _WIN32
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#endif

static NSString *
eventString(NSStream *stream, NSStreamEvent event)
{
  switch (event)
    {
      case NSStreamEventNone: return @"None";
      case NSStreamEventOpenCompleted: return @"OpenCompleted";
      case NSStreamEventHasBytesAvailable: return @"HasBytesAvailable";
      case NSStreamEventHasSpaceAvailable: return @"HasSpaceAvailable";
      case NSStreamEventEndEncountered: return @"EndEncountered"; 
      case NSStreamEventErrorOccurred: 
        return [NSString stringWithFormat: @"ErrorOccurred %ld (%@)",
          (long int)[[stream streamError] code], [stream streamError]];
    }
  return [NSString stringWithFormat: @"Unknown event %ld", (long int)event];
}

static NSString *
statusString(NSStreamStatus status)
{
  switch (status)
    {
      case NSStreamStatusNotOpen:       return @"NotOpen";
      case NSStreamStatusOpening:	return @"Opening";
      case NSStreamStatusOpen:	        return @"Open";
      case NSStreamStatusReading:	return @"Reading";
      case NSStreamStatusWriting:	return @"Writing";
      case NSStreamStatusAtEnd:	        return @"AtEnd";
      case NSStreamStatusClosed:	return @"Closed";
      case NSStreamStatusError:	        return @"Error";
    }
  return @"Unknown";
}


/* I read somewhere that a stream's delegate is commonly set to be itself,
 * so this intercept class was written to provide interception of the OSX
 * calls to -stream:handleEvent: to log the events as they are sent.
 * In fact it seems that OSX doesn't send events in that case.
 */
@interface Logger : NSObject <NSStreamDelegate>

/* Sets up an intercept for -stream:event: if the stream implements it.
 */
+ (void) intercept: (NSStream*)stream;

/* Logs a message for the stream.
 */
+ (void) log: (NSStream*)stream msg: (NSString*)fmt, ...;

/* Returns the array of logged messages.
 */
+ (NSMutableArray*) logs;

/* Sets up a pair of streams for logging.
 */
+ (void) setIn: (NSInputStream*)i andOut: (NSOutputStream*)o;

/* Returns the text of the logged messages.
 */
+ (NSString*) text;

/* The intercept to log events
 */
- (void) stream: (NSStream*)stream handleEvent: (NSStreamEvent)event;
@end

@implementation Logger

static NSMapTable       *eventHandlers = nil;
static NSMutableArray   *eventLogs = nil;
static NSInputStream    *sIn = nil;
static NSOutputStream   *sOut = nil;

+ (void) initialize
{
  if (nil == eventHandlers)
    {
      eventHandlers = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
        NSNonOwnedPointerMapValueCallBacks, 4);
      eventLogs = [NSMutableArray new];
    }
}

/* Ensure there's an array to record events handled for the stream and
 * that the streams own event handler (if it exists) logs information to it.
 */
+ (void) intercept: (NSStream*)stream
{
  Class c = object_getClass(stream);
  if (NULL == NSMapGet(eventHandlers, (void*)c))
    {
      SEL s = @selector(stream:handleEvent:);
      Method m = class_getInstanceMethod(c, s);
#if 0
      if (0 == m)
        {
          NSLog(@"[%s -%s] does not exist", class_getName(c), sel_getName(s));
        } 
#endif
      IMP i = method_getImplementation(m);
      const char *t = method_getTypeEncoding(m);
      class_replaceMethod(c, s, class_getMethodImplementation(self, s), t);
      NSMapInsert(eventHandlers, (void*)c, (void*)i);
    }
}

+ (void) log: (NSStream*)stream msg: (NSString*)fmt, ...;
{
  CREATE_AUTORELEASE_POOL(arp);
  va_list       ap;
  NSString      *msg;
  NSString      *name;

  va_start(ap, fmt);
  msg = [NSString stringWithFormat: fmt arguments: ap];
  va_end(ap);

  if (sIn == stream) name = @"In";
  else if (sOut == stream) name = @"Out";
  else name = [NSString stringWithFormat: @"%p", stream];

  msg = [NSString stringWithFormat: @"%@ (%@): %@",
    name, statusString([stream streamStatus]), msg];
  [eventLogs addObject: msg];
  RELEASE(arp);
}

+ (NSMutableArray*) logs
{
  return eventLogs;
}

+ (void) setIn: (NSInputStream*)i andOut: (NSOutputStream*)o
{
  [self intercept: i];
  sIn = i;
  [self intercept: o];
  sOut = o;
}

+ (NSString*) text
{
  NSMutableString	*s = [NSMutableString stringWithCapacity: 1024];
  NSUInteger		count = [eventLogs count];
  NSUInteger		index;

  [s appendString: @"("];
  for (index = 0; index < count; index++)
    {
      if (index > 0) [s appendString: @","];
      [s appendString: @"\n    "];
      [s appendString: [[eventLogs objectAtIndex: index] description]];
    }
  [s appendString: @"\n)"];
  return s;
}

- (void) stream: (NSStream*)stream handleEvent: (NSStreamEvent)event
{
  void                  (*efunc)(id, SEL, NSStream*, NSStreamEvent);
  Class                 c = object_getClass(stream);

  efunc = (void (*)(id, SEL, NSStream*, NSStreamEvent))
    NSMapGet(eventHandlers, (void*)c);

  [Logger log: stream msg: @"before event %@", eventString(stream, event)];
  (*efunc)(self, _cmd, stream, event);
  [Logger log: stream msg: @"after event"];
}

@end


@interface      Server : NSObject
{
#ifndef _WIN32
  int                   servSock;
  int                   accepted;
#endif
#if     GNUSTEP
  NSStream              *servStrm;
  NSInputStream         *acceptedIn;
  NSOutputStream        *acceptedOut;
#endif
  BOOL                  gnustep;
  NSThread              *thread;
  NSConditionLock       *endThread;
  enum {
    WaitAndExit = 0,
  } action;
}
- (void) end;
- (id) init: (BOOL)gnustepServer;
- (void) run;
- (void) start;
@end

@implementation Server

/* Called in server thread to accept an incoming connection.
 */
- (BOOL) accept
{
  BOOL  result = NO;

  NSLog(@"Accepting connection");
  if (gnustep)
    {
#if     GNUSTEP
      [servStrm acceptWithInputStream: &acceptedIn
                         outputStream: &acceptedOut];
      if (acceptedIn && acceptedOut)
        {
          result = YES;
        }
#endif
    }
  else
    {
#ifndef _WIN32
      struct sockaddr       addr;
      socklen_t             len = sizeof(addr);

      accepted = accept(servSock, &addr, &len);
      if (accepted >= 0)
        {
          result = YES;
        }
#endif
    }
  NSLog(@"Accept %@", result ? @"success" : @"failure");
  return result;
}

/* Called in server thread to close a previously accepted connection
 */
- (void) close
{
  BOOL  closed = NO;

#if     GNUSTEP
  if (acceptedIn != nil)
    {
      closed = YES;
      [acceptedIn close];
      [acceptedIn release];
      acceptedIn = nil;
      [acceptedOut close];
      [acceptedOut release];
      acceptedOut = nil;
    }
#endif
#ifndef _WIN32
  if (accepted >= 0)
    {
      closed = YES;
      close(accepted);
      accepted = -1;
    }
#endif
  if (closed)
    {
      NSLog(@"Closing connection");
    }
}

- (void) dealloc
{
  [self close];
#if     GNUSTEP
  [servStrm close];
  [servStrm release];
#endif
#ifndef _WIN32
  if (servSock >= 0)
    {
      close(servSock);
      servSock = -1;
    }
#endif
  [endThread release];
  [super dealloc];
}

- (void) end
{
  [endThread lockWhenCondition: 0];     // Get lock
  [endThread unlockWithCondition: 1];   // Tell thread it can end
  [endThread lockWhenCondition: 0];     // Wait for thread to end
  [endThread unlockWithCondition: 0];
}

- (id) init: (BOOL)gnustepServer
{
  if (nil != (self = [super init]))
    {
      uint16_t                  port = 1234;

      gnustep = (gnustepServer ? YES : NO);
      if (gnustep)
        {
#if     GNUSTEP
          NSHost    *host = [NSHost hostWithName: @"localhost"];

          servStrm = [GSServerStream serverStreamToAddr: [host address]
                                                   port: port];
          [servStrm open];
#else
          fprintf(stderr, "gnustep server methods not available\n");
          [self dealloc];
          return nil;
#endif
        }
      else
        {
#ifndef _WIN32
          struct sockaddr_in        my_addr;
          struct hostent            *host;     
          struct in_addr            addr;     

          servSock = -1;
          accepted = -1;
          if ((host = gethostbyname("localhost")) == NULL)     
            { 
              fprintf(stderr, "Host error: %d\n", errno);
              [self dealloc];
              return nil;
            }   
          addr = *((struct in_addr *)host->h_addr);

          my_addr.sin_family = AF_INET;
          my_addr.sin_port = htons(port);
          my_addr.sin_addr = addr;

          if ((servSock = socket(AF_INET, SOCK_STREAM, 0)) < 0)
            {
              fprintf(stderr, "Socket error: %d\n", errno);
              [self dealloc];
              return nil;
            }

          if (bind(servSock, (struct sockaddr *)&my_addr,
            sizeof(struct sockaddr)) < 0)
            {
              fprintf(stderr, "Bind error: %d\n", errno);
              [self dealloc];
              return nil;
            }

          if (listen(servSock, 5) < 0)
            {
              fprintf(stderr, "Listen error: %d\n", errno);
              [self dealloc];
              return nil;
            }
#else
          fprintf(stderr, "Simple socket server not avalable on windows\n");
          [self dealloc];
          return nil;
#endif
        }

      endThread = [[NSConditionLock alloc] initWithCondition: 0];
    }
  return self;
}

- (void) run
{
  CREATE_AUTORELEASE_POOL(arp);
  NSThread      *t;

  if ([self accept])
    {
    }
  [endThread lockWhenCondition: 1];     // Wait until thread is told to end
  [self close];
  t = thread;
  thread = nil;
  [endThread unlockWithCondition: 0];   // Record that thread has ended
  [t release];
  RELEASE(arp);
}

- (void) start
{
  NSAssert(nil == thread, NSInternalInconsistencyException);
  thread = [[NSThread alloc] initWithTarget: self
                                   selector: @selector(run)
                                     object: nil];
  [thread start];
}
@end


@interface      Logger1 : Logger
{
  int   stage;
}
@end
@implementation Logger1
- (void) stream: (NSStream*)stream handleEvent: (NSStreamEvent)event
{
  NSInputStream         *i = nil;
  NSOutputStream        *o = nil;

  [Logger log: stream msg: @"before event %@", eventString(stream, event)];
  if ([stream isKindOfClass: [NSInputStream class]])
    {
      i = (NSInputStream*)stream;
    }
  else
    {
      o = (NSOutputStream*)stream;
    }

  switch (event)
    {
      case NSStreamEventHasSpaceAvailable:
        if (0 == stage)
          {
            int total = 0;
            int len = [o write: (uint8_t*)"hello" maxLength: 5]; 
            PASS(5 == len, "can write 'hello' to stream")
            PASS([o hasSpaceAvailable],
              "after write, stream still has space available")
            if (testPassed)
              {
                total += len;
                len = [o write: (uint8_t*)" world\n" maxLength: 7];
                PASS(7 == len, "can write more to stream")
                PASS([o hasSpaceAvailable],
                  "after second write, client output still has space available")
              }
            if (testPassed)
              {
                uint8_t       buf[BUFSIZ];
                total += len;
                len = [o write: buf maxLength: 1024];
                PASS(1024 == len, "can write 1024 bytes to stream")
                PASS([o hasSpaceAvailable],
                  "after 1KB write, client output still has space available")
                if (testPassed)
                  {
                    total += len;
                    while ([o hasSpaceAvailable])
                      {
                        len = [o write: buf maxLength: 1024];
                        if (len > 0)
                          {
                            total += len;
                          }
                      }
                    NSLog(@"Total write %d, last %d", total, len);
                  }
              }
          }
        break;

      case NSStreamEventOpenCompleted:
        if (i)
          {
            [Logger log: i msg: @"Bytes available: %@",
              [i hasBytesAvailable] ? @"yes" : @"no"];
          }
        else
          {
            [Logger log: o msg: @"Space available: %@",
              [o hasSpaceAvailable] ? @"yes" : @"no"];
          }
        break;
    }
  [Logger log: stream msg: @"after event"];
}

@end

int main()
{
  CREATE_AUTORELEASE_POOL(arp);
  Server                *server;
  NSHost                *host = [NSHost hostWithName: @"localhost"];
  uint16_t              port = 1234;
  NSInputStream         *clientInput;
  NSOutputStream        *clientOutput;
  BOOL                  gnustepServer = NO;

  PASS((server = [[Server alloc] init: gnustepServer]) != nil,
    "can bind to address")

  /* At this point the server socket is bound and listening, so things
   * can initiate connections to it, but we haven't started a thread to
   * accept a connection.
   */

  START_SET("NSStream connect to server which does no I/O")

  /* Getting the streams to the server should initiate a non-blocking
   * connection to the server port.
   */
  [NSStream getStreamsToHost: host
                        port: port
                 inputStream: &clientInput
                outputStream: &clientOutput];
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after connect, client input is initially not open")
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after connect, client output is initially not open")

  /* NB. The OSX streams documentation states that a stream is
   * its own delegate by default, and that setting a nil delegate
   * must restore that state.
   * The actual implementation is different!
   */
  PASS_EQUAL([clientInput delegate], nil,
    "input stream delegate before setting is nil, not self")
  PASS_EQUAL([clientOutput delegate], nil,
    "output stream delegate before setting is nil, not self")
  [clientInput setDelegate: nil];
  [clientOutput setDelegate: nil];
  PASS_EQUAL([clientInput delegate], nil,
    "input stream delegate after setting is nil, not self")
  PASS_EQUAL([clientOutput delegate], nil,
    "output stream delegate after setting is nil, not self")

  [Logger setIn: clientInput andOut: clientOutput];

  PASS(NO == [clientInput hasBytesAvailable],
    "before open, client input does not have bytes available")
  PASS(NO == [clientOutput hasSpaceAvailable],
    "before open, client output does not have space available")

  /* Start the serve thread which will accept connection.
   */
  [server start];

  /* Opening a connection to the server should result in the stream status
   * switching from not open to opening and then shortly to open.
   * NB. It seems that the open completes even though the runloop in this
   * thread has not run.  So either the -streamStatus method must implicitly
   * check for completion of the connection attempt or another thread must
   * be handling it and updating the status.
   */
  NSTimeInterval        t = [NSDate timeIntervalSinceReferenceDate];
  [clientInput open];
  while ([clientInput streamStatus] == NSStreamStatusOpening
    && [NSDate timeIntervalSinceReferenceDate] < (t + 0.1))
    ;
  NSLog(@"Open took %g seconds", [NSDate timeIntervalSinceReferenceDate] - t);
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after input open, client status becomes open")
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after input open, client output is still not open")

  [clientInput open];
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after input re-open, client input is still open")
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after input re-open, client output is still not open")

  PASS(NO == [clientInput hasBytesAvailable],
    "after open, client input does not have bytes available")

  [clientOutput open];
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after output open, client output is now open")
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after output open, client input is still open")
  PASS([clientOutput hasSpaceAvailable],
    "after open, client output has space available")

  NSInteger	len;
  len = [clientOutput write: (uint8_t*)"hello" maxLength: 5];
  PASS(5 == len, "can write 'hello' to stream")
  PASS([clientOutput hasSpaceAvailable],
    "after write, client output still has space available")

  len = [clientOutput write: (uint8_t*)" world\n" maxLength: 7];
  PASS(7 == len, "can write more to stream")
  PASS([clientOutput hasSpaceAvailable],
    "after second write, client output still has space available")

  uint8_t       buf[BUFSIZ];
  len = [clientOutput write: buf maxLength: 1024];
  PASS(1024 == len, "can write 1024 bytes to stream")
  PASS([clientOutput hasSpaceAvailable],
    "after 1KB write, client output still has space available")

  PASS(NO == [clientInput hasBytesAvailable],
    "before server close, client input has NO bytes available")
/*
  len = [clientInput read: buf maxLength: sizeof(buf)];
  NSLog(@"Read %u bytes", len);
*/

  /* Close the connection from the server end and wait a short while
   * for the network close to propagate to the client end.
   */
  [server end];
  [NSThread sleepForTimeInterval: 0.1];

  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after server close, client output is still open")

  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusOpen),
    "after server close, client input is still open")

  PASS([clientOutput hasSpaceAvailable],
    "after server close, client output still has space available")
  PASS([clientInput hasBytesAvailable],
    "after server close, client input has bytes available")

  len = [clientOutput write: (uint8_t*)"hello" maxLength: 5];
  PASS(-1 == len, "can not write 'hello' to stream after server close")

  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusError),
    "after server close and write, client output is in error state")
  NSLog(@"Out error %@", [clientOutput streamError]);

  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusError),
    "after output error for server close, client input is in error state")

  PASS(NO == [clientOutput hasSpaceAvailable],
    "after output error, client output has NO space available")
  PASS(NO == [clientInput hasBytesAvailable],
    "after output error, client input has NO bytes available")

  [clientInput close];
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusError),
    "after input close, client input is still in error state")
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusError),
    "after input close, client output is still in error state")
  [clientOutput close];
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusError),
    "after output close, client output is still in error state")

  NSLog(@"logs: %@", [Logger text]);
  END_SET("NSStream connect to server which does no I/O")

  START_SET("NSStream connect to server which does no I/O - async")

  /* Getting the streams to the server should initiate a non-blocking
   * connection to the server port.
   */
  [NSStream getStreamsToHost: host
                        port: port
                 inputStream: &clientInput
                outputStream: &clientOutput];
  PASS_EQUAL(statusString([clientInput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after connect, client input is initially not open")
  PASS_EQUAL(statusString([clientOutput streamStatus]),
    statusString(NSStreamStatusNotOpen),
    "after connect, client output is initially not open")

  [Logger setIn: clientInput andOut: clientOutput];
  Logger        *logger = AUTORELEASE([Logger1 new]);
  NSRunLoop     *rl = [NSRunLoop currentRunLoop];

  [clientInput setDelegate: logger];
  [clientOutput setDelegate: logger];
    
  PASS([clientInput delegate] == logger && [clientOutput delegate] == logger
    && logger != nil, "delegates are set up")
 
  [clientInput scheduleInRunLoop: rl forMode: NSDefaultRunLoopMode];
  [clientOutput scheduleInRunLoop: rl forMode: NSDefaultRunLoopMode];
  NSLog(@"Opening");
  [clientInput open];
  [clientOutput open];
  [rl runMode: NSDefaultRunLoopMode
   beforeDate: [NSDate dateWithTimeIntervalSinceNow: 5.5]];
  NSLog(@"%@", [Logger text]);


  END_SET("NSStream connect to server which does no I/O - async")

  RELEASE(arp);
  return 0;
}
